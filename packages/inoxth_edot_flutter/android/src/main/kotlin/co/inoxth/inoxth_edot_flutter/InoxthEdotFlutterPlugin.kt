package co.inoxth.inoxth_edot_flutter

import android.app.Application
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
import io.opentelemetry.sdk.resources.Resource
import java.util.concurrent.ConcurrentHashMap
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
            "flush" -> flush(result)
            else -> result.notImplemented()
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
        val span =
            agent
                .getOpenTelemetry()
                .getTracer(INSTRUMENTATION_SCOPE)
                .spanBuilder(call.requireString("name"))
                .setStartTimestamp(call.requireLong("startUs"), TimeUnit.MICROSECONDS)
                .startSpan()

        spans[shadowId] = span
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

        // All three signals, unlike iOS where the pinned SDK cannot flush logs.
        agent.flushSpans().join(FLUSH_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        agent.flushMetrics().join(FLUSH_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        agent.flushLogRecords().join(FLUSH_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        result.success(null)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        spans.clear()
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

    private companion object {
        const val CHANNEL_NAME = "inoxth_edot_flutter"
        const val INSTRUMENTATION_SCOPE = "inoxth_edot_flutter"
        const val LOG_TAG = "edot"
        const val FLUSH_TIMEOUT_SECONDS = 10L
    }
}
