# inoxth_edot_flutter

OpenTelemetry observability for Flutter. Wraps the native
[EDOT iOS](https://github.com/elastic/apm-agent-ios) and
[EDOT Android](https://github.com/elastic/elastic-otel-android) Agents to provide automatic and
manual instrumentation from Dart.

iOS 15.6+, Android minSdk 24, Flutter 3.44+.

## Get started

```bash
flutter pub add inoxth_edot_flutter
```

```dart
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

Future<void> main() async {
  await Edot.start(EdotConfig(
    serviceName: 'my-app',
    serviceVersion: '1.0.0',
    deploymentEnvironment: 'production',
    serverUrl: 'https://apm.example.com:443',
    auth: const EdotAuth.apiKey('...'),
  ));

  runApp(const MyApp());
}
```

```dart
// Trace navigation by adding the observer.
MaterialApp(
  navigatorObservers: [EdotNavigatorObserver()],
);
```

`Edot.start` installs the error handlers, sets up the export pipeline, and replays anything
produced before it ran. The iOS deployment target, the full configuration reference, the
GoRouter recipe, Tracking Consent and the complete list of deliberate limitations all live in
**[`packages/inoxth_edot_flutter/README.md`](packages/inoxth_edot_flutter/README.md)**.

## Packages

Two installable packages; each has its own README.

| Package | Description |
|---|---|
| [`inoxth_edot_flutter`](packages/inoxth_edot_flutter/README.md) | Core — config, both native implementations, navigation, errors, `package:http` tracing, logs, metrics, consent |
| [`inoxth_edot_flutter_dio`](packages/inoxth_edot_flutter_dio/README.md) | Dio interceptor. Separate because Dart has no optional dependencies |

The repository also holds test infrastructure (`edot_collector_harness`) and the example app —
[`CONTRIBUTING.md`](CONTRIBUTING.md) maps the full layout.

## Compatibility

| `inoxth_edot_flutter` | EDOT iOS (`apm-agent-ios`) | EDOT Android (`agent-sdk`) | Min iOS | Min Android |
|---|---|---|---|---|
| **0.0.x** | 1.2.1 | 1.1.0 | 15.6 | 24 |

All versions require Flutter ≥ 3.44 (Swift Package Manager is default-on from that version) and
Android `compileSdk` 36. The Agent versions are pinned; raising them raises the platform floors.

## Features

**Auto** features need no per-request or per-screen code once the relevant integration is
enabled; **Manual** features are called explicitly. Grouped by the package that provides them.

### Core — [`inoxth_edot_flutter`](packages/inoxth_edot_flutter/README.md)

| Feature | Mode |
|---|---|
| App-wide `dart:io` request tracing (`traceAllHttpTraffic`) | Auto |
| `package:http` client tracing (`EdotHttpClient`) | Manual |
| W3C trace-context propagation to traced hosts | Auto |
| Navigation Screen Spans and Active View enrichment (`EdotNavigatorObserver`) | Auto¹ |
| In-page Active View updates for tabs and `IndexedStack` (`Edot.setActiveView`) | Manual |
| Uncaught Dart errors, framework errors and failed futures | Auto |
| Widget-subtree error capture (`EdotErrorBoundary`) | Manual |
| iOS native crashes, lifecycle events, system and app metrics | Auto (iOS) |
| Tracking Consent gate (`Edot.trackingConsent`, `Edot.setTrackingConsent`) | Manual |
| Session identifier (`Edot.currentSessionId`) | Manual |
| Structured logs (`Edot.log`) | Manual |
| Manual spans (`Edot.tracer`) | Manual |
| Metrics (`Edot.recordMetric`) | Manual |

¹ once the observer is registered on your `MaterialApp` or router.

### Dio — [`inoxth_edot_flutter_dio`](packages/inoxth_edot_flutter_dio/README.md)

| Feature | Mode |
|---|---|
| Dio request tracing (`EdotDioInterceptor`) | Manual |

### Trackable attributes

Attribute value types accepted by each API.

| Scope | API | Value types |
|---|---|---|
| Span | `span.setString / setInt / setDouble / setBool` | `String \| int \| double \| bool` |
| Log | `attributes:` on `Edot.log(severity, message, attributes:)` | `String \| int \| double \| bool` |
| Metric | `attributes:` on `Edot.recordMetric(name, value, attributes:)` | `String` |

## Examples

A working example app lives in
[`packages/inoxth_edot_flutter/example`](packages/inoxth_edot_flutter/example). It exercises
every feature across four tabs — Telemetry, Network, Errors and Consent — covering manual spans,
logs and metrics, all three network paths, error capture and the boundary, navigation and tab
tracking, the consent states, and the Session identifier.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the toolchain, the two test seams and the change
workflow.

## License

MIT — see [LICENSE](LICENSE).
