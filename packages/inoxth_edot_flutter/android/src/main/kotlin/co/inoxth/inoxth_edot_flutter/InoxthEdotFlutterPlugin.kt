package co.inoxth.inoxth_edot_flutter

import co.elastic.otel.android.ElasticApmAgent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.opentelemetry.api.OpenTelemetry

/**
 * Android side of the Plugin.
 *
 * Under ADR-0002 the Agent is authoritative: it creates the real spans and owns
 * export, while Dart holds only Shadow Span identifiers. That plumbing lands in
 * the tracer-bullet ticket; today this registers the single channel and proves
 * the pinned Agent resolves and links.
 */
class InoxthEdotFlutterPlugin :
    FlutterPlugin,
    MethodCallHandler {
    private lateinit var channel: MethodChannel

    /**
     * Held by the tracer-bullet ticket.
     *
     * Declared now so this target actually references the pinned `agent-sdk`
     * (ADR-0001). Without a reference, a wrong or unresolvable pin would go
     * unnoticed until the first ticket that used it; this makes the build fail
     * immediately instead.
     */
    private var agent: ElasticApmAgent? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        // No methods yet. Returning notImplemented is deliberate: the Dart side
        // has no callers, and a silent success here would hide a missing
        // implementation once it does.
        result.notImplemented()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        agent?.close()
        agent = null
    }

    private companion object {
        /** Must match `edotChannelName` on the Dart side. */
        const val CHANNEL_NAME = "inoxth_edot_flutter"

        /**
         * Compile-time reference to the pinned `opentelemetry-api`, for the same
         * reason [agent] references the Agent.
         */
        @Suppress("unused")
        val PINNED_OTEL_API: Class<OpenTelemetry> = OpenTelemetry::class.java
    }
}
