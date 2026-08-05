# inoxth_edot_flutter

> **Unofficial.** Not affiliated with or endorsed by Elastic N.V. EDOT does not
> officially support Flutter — EDOT Android's own documentation states that hybrid
> frameworks such as Flutter are not supported.

Flutter plugin that surfaces the Elastic Distribution of OpenTelemetry (EDOT)
mobile Agents to Dart, so a Flutter app reports into Elastic the same way a native
app does.

**Using the plugin in an app?** Read
[`packages/inoxth_edot_flutter/README.md`](packages/inoxth_edot_flutter/README.md) — the setup
guide, the recipes and the complete list of deliberate limitations live there.

**Working *on* the plugin?** [`CONTRIBUTING.md`](CONTRIBUTING.md) covers the toolchain, the two
test seams and the change workflow.

## Requirements

| | Minimum |
|---|---|
| iOS | **15.6** — Swift Package Manager required, no CocoaPods support |
| Android | **API 24** (compileSdk 36) |
| Flutter | **3.44** — SPM is default-on from this version |

## Limitations

Deliberately not duplicated here. The complete list, with the reason for each, is in
[the package README](packages/inoxth_edot_flutter/README.md#limitations) — one copy, so the
two cannot drift apart.

## Packages

Each package has its own README with the detail; this table is the map.

| Package | README | Purpose |
|---|---|---|
| `inoxth_edot_flutter` | [README](packages/inoxth_edot_flutter/README.md) | Core: Dart API, both native implementations, `package:http` tracing |
| `inoxth_edot_flutter_dio` | [README](packages/inoxth_edot_flutter_dio/README.md) | Dio interceptor. Separate because Dart has no optional dependencies |
| `edot_collector_harness` | [README](packages/edot_collector_harness/README.md) | Seam 2 test harness. Never published |

## Contributing

Toolchain, the two test seams and the change workflow are in
[`CONTRIBUTING.md`](CONTRIBUTING.md). In short:

```bash
dart pub global activate melos   # once
flutter pub get
melos run verify                 # format-check, analyze, Seam 1 test tier
```

## Status

Feature-complete for v1. Every headline capability is implemented and verified at both test
seams: Agent initialisation, span enrichment and parenting, logs and metrics, Active View and
screen enrichment, navigation, network tracing through `package:http`, Dio and app-wide
`dart:io`, W3C trace-context propagation, Dart error capture, platform configuration, the
Session identifier, Tracking Consent, and the queue for telemetry produced before the Agent is
ready.

Not published to a package registry. See the issue tracker for what remains.
