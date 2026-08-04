# Native-authoritative telemetry pipeline with Dart shadow spans

Status: accepted

## Context

Everything the Plugin must instrument — `http`, `dio`, navigation, Dart Errors — is invisible to the
Agents' own auto-instrumentation. `dart:io`'s `HttpClient` implements HTTP on POSIX sockets and bundled
BoringSSL inside the Dart VM, so it never touches `URLSession` (whose instrumentation is Objective-C
method swizzling) or OkHttp (instrumented by JVM bytecode weaving). Likewise there is exactly one
`FlutterActivity`/`FlutterViewController` for the whole app, so route changes are natively invisible;
and Dart exceptions never reach a native crash handler unless the process dies.

So the instrumentation must be written in Dart. The question is where the pipeline lives.

## Decision

The Agent is authoritative: it creates every real span, owns span IDs and timestamps-as-exported,
and performs all export. Dart mints a **Shadow Span** identifier locally and the Agent keeps a
thread-safe registry mapping it to the real span. Span start and end are fire-and-forget over the
platform channel; only fetching a `traceparent` for an outbound request awaits a reply.

This inherits disk buffering, Session management, device resource detection, NTP time sync and
Native Crash correlation using only public Agent APIs, and keeps one export path and one Session.

It also matches the organisation's React Native SDK, which holds the real span in a native registry
keyed by a JS-minted string ID — so both SDKs share one mental model.

## Considered options

- **Dart-authoritative:** a pure-Dart OpenTelemetry SDK creating and exporting spans itself, with the Agent alongside for Native Crashes only. Rejected — two export paths and two buffers, Dart-side offline persistence would have to be built from scratch, and Session/resource synchronisation becomes a live correctness risk.
- **Dart creates and batches, native injects into the Agent's exporter.** Rejected — OpenTelemetry offers no public API for injecting foreign spans, so this requires constructing `SpanData` against SDK internals on both platforms and would break on Agent upgrades.
- **No Agent at all; Dart straight to OTLP.** Rejected — forfeits disk buffering, central config, device resource detection, NTP sync and crash capture, i.e. everything that makes EDOT worth integrating.

## Consequences

- Roughly two cheap channel messages per span. Negligible for network and navigation volumes; callers instrumenting hot loops should expect overhead.
- The React Native SDK's `getTraceparent` is a **synchronous** TurboModule call. Flutter platform channels are async-only, so ours returns a `Future`. This is precisely why Dart mints the Shadow Span identifier itself rather than blocking on the Agent for one.
- Spans created by native code — Firebase, Maps, ad SDKs — cannot be parented to Dart spans. Native OpenTelemetry `Context` is thread-local and those requests run on arbitrary threads with no link back to the Dart caller. Correlation is via Session and Screen Name instead.
- Integer and floating-point attributes must cross the channel through distinct typed methods so OpenTelemetry attribute types survive the round trip.
- The awaited call replies with a **map of headers**, not a `traceparent` string as the React Native SDK's does. Each platform's own W3C propagator writes it, so the wire format is the OpenTelemetry version's rather than ours, `tracestate` comes along when a span carries one, and the deprecated `elastic-apm-traceparent` stays out by construction. The cost is that the header format is asserted at Seam 2 only — Dart cannot check what it does not build.
