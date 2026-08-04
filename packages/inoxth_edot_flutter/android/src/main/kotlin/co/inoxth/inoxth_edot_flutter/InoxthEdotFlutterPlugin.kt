package co.inoxth.inoxth_edot_flutter

import android.app.Application
import android.os.Handler
import android.os.Looper
import co.elastic.otel.android.ElasticApmAgent
import co.elastic.otel.android.connectivity.Authentication
import co.elastic.otel.android.exporters.configuration.ExportProtocol
import co.elastic.otel.android.features.diskbuffering.DiskBufferingConfiguration
import co.elastic.otel.android.interceptor.Interceptor
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.opentelemetry.api.common.AttributeKey
import io.opentelemetry.api.common.Attributes
import io.opentelemetry.api.trace.Span
import io.opentelemetry.api.trace.StatusCode
import io.opentelemetry.context.Context
import io.opentelemetry.sdk.resources.Resource
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Android side of the Plugin.
 *
 * Under ADR-0002 the Agent is authoritative: it holds the real spans and owns
 * export. Dart sends a Shadow Span identifier and this class keeps the mapping,
 * so span start and end need no reply.
 */
class InoxthEdotFlutterPlugin :
    FlutterPlugin,
    MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var application: Application? = null
    private var agent: ElasticApmAgent? = null
    private var debug = false

    /**
     * Shadow Span identifier to the real span.
     *
     * Concurrent because Dart dispatches from the platform thread while the
     * Agent's own instrumentation runs on others.
     */
    private val spans = ConcurrentHashMap<String, Span>()

    /** Runs the blocking part of [flush] off the platform thread. */
    private val flushExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        application = flutterPluginBinding.applicationContext as? Application
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        when (call.method) {
            "initialize" -> initialize(call, result)
            "spanStart" -> spanStart(call, result)
            "spanEnd" -> spanEnd(call, result)

            // Four methods rather than one. Android could tell a Long from a
            // Double, but iOS cannot — Flutter delivers both as NSNumber there —
            // and the channel protocol is shared, so the type travels in the
            // method name on both platforms.
            "spanSetString" ->
                withSpan(call, result) { span ->
                    val key = call.requireString("key")
                    span.setAttribute(AttributeKey.stringKey(key), call.requireString("value"))
                }

            "spanSetInt" ->
                withSpan(call, result) { span ->
                    val key = call.requireString("key")
                    span.setAttribute(AttributeKey.longKey(key), call.requireLong("value"))
                }

            "spanSetDouble" ->
                withSpan(call, result) { span ->
                    val key = call.requireString("key")
                    span.setAttribute(AttributeKey.doubleKey(key), call.requireDouble("value"))
                }

            "spanSetBool" ->
                withSpan(call, result) { span ->
                    val key = call.requireString("key")
                    span.setAttribute(AttributeKey.booleanKey(key), call.requireBoolean("value"))
                }

            "spanRecordException" -> recordException(call, result)
            "spanMarkFailed" -> markFailed(call, result)

            "flush" -> flush(result)
            else -> result.notImplemented()
        }
    }

    /**
     * Resolves the Shadow Span a call refers to and hands it to [action].
     *
     * Never replies with an error for a missing span: none of these calls is
     * awaited in Dart (ADR-0002), so an error would surface as an unhandled
     * channel failure detached from the call site rather than at it.
     *
     * [action] reads whatever further arguments it needs itself, so each method
     * requires exactly the fields it actually has rather than defaulting an
     * absent one to something harmless-looking.
     */
    private fun withSpan(
        call: MethodCall,
        result: Result,
        action: (Span) -> Unit
    ) {
        val shadowId = call.requireString("shadowId")
        val span = spans[shadowId]

        if (span == null) {
            // Ordinarily an ended span, which Dart already guards against.
            // Reaching here means the two sides disagree about its lifetime.
            log("${call.method} for unknown shadow id '$shadowId'; dropped")
            result.success(null)
            return
        }

        action(span)
        result.success(null)
    }

    private fun recordException(
        call: MethodCall,
        result: Result
    ) {
        withSpan(call, result) { span ->
            val attributes =
                Attributes
                    .builder()
                    .put(AttributeKey.stringKey("exception.type"), call.requireString("type"))
                    .put(AttributeKey.stringKey("exception.message"), call.requireString("message"))

            // Omitted rather than sent empty when Dart had no stack trace, so a
            // present-but-blank attribute never has to be interpreted.
            call.argument<String>("stacktrace")?.let {
                attributes.put(AttributeKey.stringKey("exception.stacktrace"), it)
            }

            // Deliberately no exception.escaped: ADR-0003's error vocabulary does
            // not include it, and whether the exception escaped the span is not
            // something the caller told us.
            span.addEvent("exception", attributes.build())
        }
    }

    private fun markFailed(
        call: MethodCall,
        result: Result
    ) {
        withSpan(call, result) { span ->
            // setStatus takes a non-null description, so an absent one becomes
            // empty rather than being omitted.
            span.setStatus(StatusCode.ERROR, call.argument<String>("description") ?: "")
        }
    }

    private fun initialize(
        call: MethodCall,
        result: Result
    ) {
        if (agent != null) {
            // Dart guards against this too, but the guard belongs on both sides:
            // two agents would mean two export pipelines racing.
            result.error("already_initialized", "The Agent is already running.", null)
            return
        }

        val app = application
        if (app == null) {
            result.error(
                "no_application",
                "Plugin is not attached to an Application context.",
                null
            )
            return
        }

        try {
            val serviceName = call.requireString("serviceName")
            val serviceVersion = call.requireString("serviceVersion")
            val environment = call.requireString("deploymentEnvironment")
            debug = call.argument<Boolean>("debug") ?: false

            if (call.argument<Boolean>("disableAgent") == true) {
                log("agent disabled by configuration; not starting")
                result.success(null)
                return
            }

            val builder =
                ElasticApmAgent
                    .builder(app)
                    .setServiceName(serviceName)
                    .setServiceVersion(serviceVersion)
                    .setDeploymentEnvironment(environment)
                    .setExportUrl(call.requireString("serverUrl"))
                    .setExportAuthentication(authenticationFrom(call))
                    .setExportProtocol(
                        if (call.argument<String>("exportProtocol") == "grpc") {
                            ExportProtocol.GRPC
                        } else {
                            ExportProtocol.HTTP
                        }
                    ).setResourceInterceptor(deploymentEnvironmentInterceptor(environment))

            (call.argument<Double>("sessionSamplingRate"))?.let(builder::setSessionSampleRate)

            val android = call.argument<Map<String, Any?>>("android")
            builder.setDiskBufferingConfiguration(
                if (android?.get("diskBufferingEnabled") == false) {
                    DiskBufferingConfiguration.disabled()
                } else {
                    DiskBufferingConfiguration.enabled()
                }
            )

            agent = builder.build()
            log("agent started for service '$serviceName'")
            result.success(null)
        } catch (error: IllegalArgumentException) {
            result.error("invalid_config", error.message, null)
        }
    }

    /**
     * Adds both spellings of the deployment environment attribute.
     *
     * The Agent sets only one, and APM Server 8.16+ reads
     * `deployment.environment.name`, so telemetry would land unattributed
     * against a newer stack. Setting both keeps one Plugin working across
     * versions, and matches what the React Native SDK does on iOS.
     */
    private fun deploymentEnvironmentInterceptor(environment: String): Interceptor<Resource> =
        Interceptor { resource ->
            resource.merge(
                Resource.create(
                    Attributes
                        .builder()
                        .put(AttributeKey.stringKey("deployment.environment"), environment)
                        .put(AttributeKey.stringKey("deployment.environment.name"), environment)
                        .build()
                )
            )
        }

    private fun authenticationFrom(call: MethodCall): Authentication {
        call.argument<String>("apiKey")?.let { return Authentication.ApiKey(it) }
        call.argument<String>("secretToken")?.let { return Authentication.SecretToken(it) }
        return Authentication.None
    }

    private fun spanStart(
        call: MethodCall,
        result: Result
    ) {
        val agent = this.agent
        if (agent == null) {
            // Not an error result: Dart does not await this call, so an error
            // would surface as an unhandled channel failure rather than at the
            // call site. Logging keeps it visible without that noise.
            log("spanStart before initialize; dropped")
            result.success(null)
            return
        }

        val shadowId = call.requireString("shadowId")
        val builder =
            agent
                .getOpenTelemetry()
                .getTracer(INSTRUMENTATION_SCOPE)
                .spanBuilder(call.requireString("name"))
                .setStartTimestamp(call.requireLong("startUs"), TimeUnit.MICROSECONDS)

        // Parenting is always stated, never inherited. OpenTelemetry would
        // otherwise fall back to Context.current() on whichever thread this
        // arrives on, and a Dart span silently adopting some unrelated native
        // span as its parent is precisely the plausible-but-wrong tree this
        // design avoids. ADR-0002: native Context is thread-local and has no link
        // back to the Dart caller.
        val parentShadowId = call.argument<String>("parentShadowId")
        val parent = parentShadowId?.let { spans[it] }

        if (parent != null) {
            builder.setParent(Context.root().with(parent))
        } else {
            if (parentShadowId != null) {
                // Ended before its child started, which is a caller bug. Logged
                // rather than hidden; the span becomes a root.
                log("parent shadow id '$parentShadowId' is not active; starting a root")
            }
            builder.setNoParent()
        }

        spans[shadowId] = builder.startSpan()
        result.success(null)
    }

    private fun spanEnd(
        call: MethodCall,
        result: Result
    ) {
        val shadowId = call.requireString("shadowId")
        val span = spans.remove(shadowId)

        if (span == null) {
            log("spanEnd for unknown shadow id '$shadowId'; dropped")
            result.success(null)
            return
        }

        span.end(call.requireLong("endUs"), TimeUnit.MICROSECONDS)
        result.success(null)
    }

    private fun flush(result: Result) {
        val agent = this.agent
        if (agent == null) {
            result.error("not_initialized", "The Agent is not running.", null)
            return
        }

        // Start all three before joining any. Each call returns its result code
        // immediately, so the flushes overlap and the wait is bounded by the
        // slowest rather than by their sum. All three signals, unlike iOS where
        // the pinned Agent cannot flush logs.
        val pending =
            listOf(
                agent.flushSpans(),
                agent.flushMetrics(),
                agent.flushLogRecords()
            )

        // join blocks, and this handler runs on the platform thread. Waiting here
        // would freeze the UI for as long as the export takes — seconds, which is
        // ANR territory. Dart awaits the reply either way, so moving the wait to a
        // background thread costs the caller nothing.
        flushExecutor.execute {
            pending.forEach { it.join(FLUSH_TIMEOUT_SECONDS, TimeUnit.SECONDS) }
            // Flutter requires the reply on the platform thread.
            mainHandler.post { result.success(null) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        spans.clear()
        flushExecutor.shutdown()
        agent?.close()
        agent = null
        application = null
    }

    /** Never called with a credential — configuration is logged from Dart, redacted. */
    private fun log(message: String) {
        if (debug) {
            android.util.Log.d(LOG_TAG, message)
        }
    }

    private fun MethodCall.requireString(key: String): String =
        argument<String>(key)
            ?: throw IllegalArgumentException("Missing required argument '$key'")

    private fun MethodCall.requireLong(key: String): Long =
        when (val raw = argument<Any>(key)) {
            is Long -> raw
            is Int -> raw.toLong()
            else -> throw IllegalArgumentException("Missing or non-numeric argument '$key'")
        }

    /**
     * Strict about the type, unlike [requireLong] which accepts either integer
     * width. A Double arriving here as an integer would mean something upstream
     * narrowed it, which is exactly the loss the typed methods exist to prevent —
     * so it fails rather than being quietly widened back.
     */
    private fun MethodCall.requireDouble(key: String): Double =
        argument<Any>(key) as? Double
            ?: throw IllegalArgumentException("Missing or non-double argument '$key'")

    private fun MethodCall.requireBoolean(key: String): Boolean =
        argument<Any>(key) as? Boolean
            ?: throw IllegalArgumentException("Missing or non-boolean argument '$key'")

    private companion object {
        const val CHANNEL_NAME = "inoxth_edot_flutter"
        const val INSTRUMENTATION_SCOPE = "inoxth_edot_flutter"
        const val LOG_TAG = "edot"
        const val FLUSH_TIMEOUT_SECONDS = 10L
    }
}
