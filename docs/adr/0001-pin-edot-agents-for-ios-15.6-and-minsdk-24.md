# Pin the EDOT native agents to support iOS 15.6 and Android minSdk 24

Status: accepted

## Context

The Plugin must support **iOS 15.6** and **Android minSdk 24**. The current EDOT releases cannot meet either:

- `apm-agent-ios` **2.0.2** declares `.iOS(.v16)`. The iOS-16 floor landed in **1.3.0** — 1.2.1 and earlier declare `.iOS(.v13)`.
- `co.elastic.otel.android:agent-sdk` **1.7.1** targets a newer Kotlin line and a higher minSdk.

The organisation's React Native SDK hit this identically and resolved it by downgrading
(see `inoxth/react-native-edot-sdk`, `docs/adr/0001-downgrade-edot-agents-for-ios-15.6-and-kotlin-2.1.md`).
Fleet Alignment means matching those pins rather than choosing our own.

## Decision

Pin to the newest agent releases that meet the floors, matching the React Native SDK exactly:

| Dependency | Pin |
|---|---|
| `apm-agent-ios` | **1.2.1** exact |
| `opentelemetry-swift` | **1.13.0** exact (unified package, not the 2.x `-core` split) |
| `co.elastic.otel.android:agent-sdk` | **1.1.0** |
| `io.opentelemetry:opentelemetry-api` | **1.51.0** (matches agent 1.1.0's bundled OpenTelemetry-Java) |
| iOS deployment target | **15.6**, Swift 5.9 |
| Android | compileSdk 36, minSdk 24 |

## Considered options

- **Stay on current releases and raise the floors to iOS 16 / minSdk 26.** Rejected — the floors are a hard requirement.
- **Build directly on OpenTelemetry without EDOT.** Rejected — discards sessions, disk buffering, device resource detection and crash capture, which are the reason to integrate EDOT at all.
- **Reimplement the lost capabilities against the old agents** (e.g. a custom `SpanProcessor` for attribute injection). Rejected for v1 — cost outweighs value, and it would diverge from the React Native SDK.

## Consequences

- **No `setUser`, session attributes, global attributes, or attribute redaction.** `apm-agent-ios` 1.2.1 has no span-attribute interceptor. Note that Android `agent-sdk` **1.1.0 does** expose `addSpanAttributesInterceptor` and `addLogRecordAttributesInterceptor` — we forgo them anyway, for symmetry with iOS and Fleet Alignment. This is a parity choice, not a platform limit.
- **No central configuration / OpAMP.** Absent from both pinned versions at the config surface. `apm-agent-ios` 1.2.1 nonetheless instantiates its central-config poller internally with no toggle to disable it — see ADR-0006.
- **`flush()` is partial on iOS.** Android 1.1.0 exposes `flushSpans()`, `flushLogRecords()` and `flushMetrics()`. On iOS, OpenTelemetry-Swift 1.13.0 offers `TracerProviderSdk.forceFlush(timeout:)` and `StableMeterProviderSdk.forceFlush()`, but `LoggerProviderSdk` exposes **no** `forceFlush` and does not surface its processor — and the Agent builds the provider internally. So log records, which carry Dart Errors, cannot be force-flushed on iOS. Integration tests asserting error events on iOS must tolerate batch-timer latency.
- **`getCurrentSessionId()` returns an empty string on Android.** EDOT Android exposes `SessionManager` only as an internal `$agent_sdk` API.
- **Both agents sit several releases behind upstream.** No upstream fixes or features are available until the floors rise. Revisit this ADR when they do.
- The iOS Agent hardcodes `deployment.environment` to `"default"`; the Plugin must set both `deployment.environment` and `deployment.environment.name` in `OTEL_RESOURCE_ATTRIBUTES` for APM Server 8.16+, and validate that service identity values are non-blank and free of `,` and `=`.
