# inoxth_edot_flutter

> **Unofficial.** Not affiliated with or endorsed by Elastic N.V. EDOT does not
> officially support Flutter — EDOT Android's own documentation states that hybrid
> frameworks such as Flutter are not supported.

Flutter plugin that surfaces the Elastic Distribution of OpenTelemetry (EDOT)
mobile Agents to Dart, so a Flutter app reports into Elastic the same way a native
app does.

**Using the plugin in an app?** Read
[`packages/inoxth_edot_flutter/README.md`](packages/inoxth_edot_flutter/README.md) — the setup
guide, the recipes and the complete list of deliberate limitations live there. This file covers
working *on* the repo.

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

## Working in this repo

```bash
dart pub global activate melos          # once
flutter pub get                         # resolves the pub workspace
melos run verify                        # format, analyse, Dart test tier
```

### Tests

Two seams, by design — see `docs/adr/`.

- **Seam 1, the platform channel.** Fast and hermetic, no native code.
  `melos run test --no-select` — the flag is required because the script is
  package-filtered, so without it melos prompts for a package and fails outright
  on a non-interactive shell.
- **Seam 2, exported telemetry at a real collector.** Needs Docker and a device or
  emulator.

Each Seam 2 contract is two halves: a device half that emits, and a host half that
starts the collector, drives the device half and owns the assertions. They are split
because `integration_test` code runs on the device, where the collector's output file
does not exist. Run the host half — it starts and stops the collector itself.

```bash
cd packages/inoxth_edot_flutter/example
dart run tool/verify_tracer_bullet.dart -d <device>
dart run tool/verify_span_enrichment.dart -d <device>
dart run tool/verify_span_parenting.dart -d <device>
dart run tool/verify_screen_attribution.dart -d <device>
dart run tool/verify_navigation.dart -d <device>
dart run tool/verify_network.dart -d <device>
dart run tool/verify_trace_context.dart -d <device>
dart run tool/verify_collector_host_exclusion.dart -d <ios-device>  # iOS only
dart run tool/verify_platform_config.dart -d <device>               # runs the device half 4x
dart run tool/verify_signals.dart -d <android-device>               # Android only
dart run tool/verify_error.dart -d <android-device>                 # Android only
dart run tool/verify_disk_buffering.dart -d <android-device>        # Android only
dart run tool/verify_consent.dart -d <android-device>               # Android only
```

`verify_disk_buffering.dart` is the one suite that stops the collector mid-run — it is the only way to
create the offline period disk buffering exists for. Expect it to take a few minutes: the outage has to
outlast the exporter's in-memory retry to prove anything.

Each host half exits 2 with an explanation when Docker is absent, rather than
passing. A silently skipped Seam 2 tier reads as coverage it does not have.

## Status

Feature-complete for v1. Every headline capability is implemented and verified at both test
seams: Agent initialisation, span enrichment and parenting, logs and metrics, Active View and
screen enrichment, navigation, network tracing through `package:http`, Dio and app-wide
`dart:io`, W3C trace-context propagation, Dart error capture, platform configuration, the
Session identifier, Tracking Consent, and the queue for telemetry produced before the Agent is
ready.

Not published to a package registry. See the issue tracker for what remains.
