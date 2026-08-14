## 0.1.0-dev.1

Prerelease of 0.1.0, cut to exercise publication itself rather than to ship
anything new. It proves the archive, the pub.dev listing, and that the Dio
package resolves against a hosted core rather than a workspace sibling.
Identical in content to 0.1.0 below. Prereleases are not served as the latest
stable, so `flutter pub add inoxth_edot_flutter` is unaffected by this version.

## 0.1.0

First release. A Flutter plugin wrapping the pinned EDOT mobile Agents, with the
telemetry pipeline and every integration in place.

**Foundation**

* Plugin registers on Android and iOS against a single method channel.
* Native Agents pinned per ADR-0001: `apm-agent-ios` 1.2.1 (exact),
  `opentelemetry-swift` 1.13.0 (exact), `co.elastic.otel.android:agent-sdk` 1.1.0,
  `io.opentelemetry:opentelemetry-api` 1.51.0.
* Platform floors: iOS 15.6, Android API 24 (compileSdk 35), Flutter 3.44.
* iOS ships via Swift Package Manager only, with no podspec (ADR-0007).
* Android native crash reporting deliberately not bundled (ADR-0009).

**Telemetry pipeline**

* The Agent is initialised from `Edot.start`, and the pipeline is native-authoritative:
  Dart mints Shadow Spans keyed to the Agent's real spans, and owns the timestamps
  (ADR-0002, ADR-0005).
* Spans carry typed attributes, recorded exceptions and error status, under an ambient
  parent context so a span created in synchronous code still nests correctly.
* Log records and metrics are emitted through the Agent; metric attributes are
  String-only, a consequence of the pinned iOS Agent's legacy meter (ADR-0012).
* `Edot.flush()` drains in-memory buffers but does not promise delivery - a property of
  the pinned Agents, not a choice (ADR-0011).

**Instrumentation**

* Network tracing for `package:http` (`EdotHttpClient`) and, in the separate
  `inoxth_edot_flutter_dio` package, for Dio - both driving one shared request trace so
  they cannot drift (ADR-0013).
* App-wide `dart:io` tracing (`traceAllHttpTraffic`), de-duplicated against the wrapped
  transports by the Traced Marker (ADR-0014).
* W3C Trace Context propagation to the services a traced request reaches, narrowable per
  host.
* Navigation Screen Spans from `EdotNavigatorObserver`, with a screen-name extractor for
  routers the Plugin knows nothing about; every span and log record is attributed to the
  Active View (ADR-0004).
* Dart Errors captured as non-fatal log records, plus `EdotErrorBoundary` for a subtree
  that is allowed to fail (ADR-0008).

**Configuration and consent**

* Platform configuration passes through to each Agent, and the Session identifier is
  exposed.
* Telemetry is gated on Tracking Consent in Dart, and what precedes `Edot.start` is held
  in a bounded buffer rather than lost (ADR-0015, ADR-0005).
* Emitted wire names align with this organisation's React Native SDK, so one Kibana
  dashboard serves both fleets (ADR-0003).
