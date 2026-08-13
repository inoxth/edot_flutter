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
| Android | compileSdk 35, minSdk 24 |

`compileSdk` is **35 rather than the Flutter template's 36**, and that is a deliberate consumer-facing
choice: AGP fails any app that compiles against an older API than a library it depends on, so
building this Plugin at 36 would force every consuming app to 36. At 35 it supports apps at 35 and 36
alike, and `agent-sdk` 1.1.0 compiles against it. Note that Flutter's own `integration_test` plugin
is built at 36, so an app using it needs 36 regardless of this Plugin - which is why the examples and
the Seam 2 suites keep the template default.

## Considered options

- **Stay on current releases and raise the floors to iOS 16 / minSdk 26.** Rejected — the floors are a hard requirement.
- **Build directly on OpenTelemetry without EDOT.** Rejected — discards sessions, disk buffering, device resource detection and crash capture, which are the reason to integrate EDOT at all.
- **Reimplement the lost capabilities against the old agents** (e.g. a custom `SpanProcessor` for attribute injection). Rejected for v1 — cost outweighs value, and it would diverge from the React Native SDK.

## Consequences

- **No `setUser`, session attributes, global attributes, or attribute redaction.** `apm-agent-ios` 1.2.1 has no span-attribute interceptor. Note that Android `agent-sdk` **1.1.0 does** expose `addSpanAttributesInterceptor` and `addLogRecordAttributesInterceptor` — we forgo them anyway, for symmetry with iOS and Fleet Alignment. This is a parity choice, not a platform limit.
- **No central configuration / OpAMP.** Absent from both pinned versions at the config surface. `apm-agent-ios` 1.2.1 nonetheless instantiates its central-config poller internally with no toggle to disable it — see ADR-0006.
- **`flush()` is partial on iOS.** Android 1.1.0 exposes `flushSpans()`, `flushLogRecords()` and `flushMetrics()`. On iOS, OpenTelemetry-Swift 1.13.0 offers `TracerProviderSdk.forceFlush(timeout:)` and `StableMeterProviderSdk.forceFlush()`, but `LoggerProviderSdk` exposes **no** `forceFlush` and does not surface its processor — and the Agent builds the provider internally. So log records, which carry Dart Errors, cannot be force-flushed on iOS. Integration tests asserting error events on iOS must tolerate batch-timer latency.
- **Reading the Session identifier returns an empty string on Android.** EDOT Android exposes `SessionManager` only as an internal `$agent_sdk` API. The accessor is `Edot.currentSessionId()` here and `getCurrentSessionId()` in the React Native SDK; both fleets have the same gap for the same reason.
- **Session sampling is honoured on Android and unreliable on iOS.** `apm-agent-ios` 1.2.1's `SessionSampler` initialises to sampling everything and recomputes only when `SessionManager` posts its refresh notification, which it does only for a session that is new or has expired. So the configured rate applies on a cold start and is ignored for the lifetime of an already-live session — a relaunch inside the 30-minute session window reports in full whatever the rate says. Not worked around: the refresh is not public API, and the React Native SDK passes the same rate to the same Agent, so both fleets behave identically and a fix here would be a divergence. `disableAgent` is unaffected and works on both platforms. Verified at Seam 2, where the iOS half of this assertion is therefore deliberately not made.
- **On iOS, a root span carrying `http.url` is exported with a synthetic parent.** `ElasticSpanProcessor.onEnd` treats any span with that attribute as an HTTP span, and when one has no parent it builds a second span — same name, kind, scope and timestamps, carrying only `type` and `session.id` — reparents the real span beneath it, and exports both. Elastic APM's data model requires a span to belong to a transaction, and this manufactures one. It means **one request produces two spans on iOS and one on Android**, so span counts are not comparable across platforms. The Agent does it for the React Native fleet too, so it does not break Fleet Alignment. Giving the request span a parent of our own avoids it, because the synthetic parent is only added to roots.
- **Both agents sit several releases behind upstream.** No upstream fixes or features are available until the floors rise. Revisit this ADR when they do.
- The iOS Agent hardcodes `deployment.environment` to `"default"`; the Plugin must set both `deployment.environment` and `deployment.environment.name` in `OTEL_RESOURCE_ATTRIBUTES` for APM Server 8.16+, and validate that service identity values are non-blank and free of `,` and `=`.
