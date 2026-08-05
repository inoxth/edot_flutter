/// Unofficial Flutter plugin for the Elastic Distribution of OpenTelemetry
/// (EDOT) mobile Agents.
///
/// EDOT does not officially support Flutter — EDOT Android's own documentation
/// states that hybrid frameworks are unsupported. This package is not affiliated
/// with or endorsed by Elastic N.V.
///
/// Requires iOS 15.6+, Android API 24+, Flutter 3.44+, and Swift Package Manager
/// on iOS. See the README for the full list of limitations.
///
/// ```dart
/// await Edot.start(EdotConfig(
///   serviceName: 'my-app',
///   serviceVersion: '1.0.0',
///   deploymentEnvironment: 'prod',
///   serverUrl: 'https://collector.example.com:4318',
///   auth: const EdotAuth.apiKey('...'),
/// ));
///
/// final span = Edot.tracer.startSpan('checkout');
/// // ...
/// span.end();
/// ```
library;

export 'src/edot.dart' show Edot;
export 'src/edot_active_view.dart' show EdotActiveView;
export 'src/edot_channel.dart' show edotChannelName;
export 'src/edot_config.dart'
    show
        EdotAndroidConfig,
        EdotApiKeyAuth,
        EdotAuth,
        EdotConfig,
        EdotIosConfig,
        EdotNoAuth,
        EdotSecretTokenAuth,
        ExportProtocol;
export 'src/edot_error_boundary.dart' show EdotErrorBoundary;
// EdotErrorSource is deliberately *not* exported. Nothing public takes one —
// `Edot.reportError` always reports as the app — so it would be surface with no caller.
// The `error.source` values an integrator queries on belong in the documentation.
export 'src/edot_http_client.dart' show EdotHttpClient;
export 'src/edot_navigator_observer.dart' show EdotNavigatorObserver;
// EdotRequestTrace is deliberately *not* exported here. It is what an integration
// package is built on, not something an app needs, and it lives in
// `instrumentation.dart` so this surface stays the one an app developer reads.
export 'src/edot_signals.dart' show EdotMetricKind, EdotSeverity;
export 'src/edot_tracer.dart' show EdotSpan, EdotSpanKind, EdotTracer;
