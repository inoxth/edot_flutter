## 0.0.1

Foundation. No telemetry behaviour yet.

* Plugin registers on Android and iOS against a single method channel.
* Native Agents pinned per ADR-0001: `apm-agent-ios` 1.2.1 (exact),
  `opentelemetry-swift` 1.13.0 (exact), `co.elastic.otel.android:agent-sdk` 1.1.0,
  `io.opentelemetry:opentelemetry-api` 1.51.0.
* Platform floors: iOS 15.6, Android API 24 (compileSdk 36), Flutter 3.44.
* iOS ships via Swift Package Manager only, with no podspec (ADR-0007).
* Android native crash reporting deliberately not bundled (ADR-0009).
