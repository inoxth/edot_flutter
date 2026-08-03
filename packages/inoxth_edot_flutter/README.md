# inoxth_edot_flutter

> **Unofficial.** Not affiliated with or endorsed by Elastic N.V. EDOT does not
> officially support Flutter — EDOT Android's own documentation states that hybrid
> frameworks such as React Native and Flutter are not supported.

Flutter plugin for the Elastic Distribution of OpenTelemetry (EDOT) mobile Agents.

## Requirements

| | Minimum |
|---|---|
| iOS | **15.6** — Swift Package Manager required, **no CocoaPods support** |
| Android | **API 24** (compileSdk 36) |
| Flutter | **3.44** |

These floors are not incidental. The Agents are pinned to the newest releases that
meet them (`apm-agent-ios` 1.2.1, `co.elastic.otel.android:agent-sdk` 1.1.0);
`apm-agent-ios` raised its own floor to iOS 16 in 1.3.0. Raising the pins raises
the floors. See ADR-0001.

An app using this plugin must set its iOS deployment target to 15.6 or higher.

## Status

Foundation only. The Agent is not initialised yet and no telemetry is produced.
Usage documentation lands as the instrumentation tickets do; see the repository
root README and `docs/adr/` for the design this implementation is bound by.

## Known limitations

The full list ships with the documentation ticket. The ones that shape adoption:

- Native crash reporting is **unavailable on Android** and **on by default on iOS**,
  where it will contend with any incumbent crash reporter (ADR-0009).
- Dart errors are recorded as non-fatal events and are **not** counted in
  crash-free rate (ADR-0008).
- Dart stack traces are **not symbolicated**; obfuscated release builds produce
  unreadable frames.
- No request to the collector's host is traced, at any path or port (ADR-0006).
- Emitted attribute names deliberately follow the older Elastic mobile vocabulary
  rather than the stable OpenTelemetry HTTP conventions, to stay aligned with the
  React Native SDK (ADR-0003).
