# inoxth_edot_flutter

> **Unofficial.** Not affiliated with or endorsed by Elastic N.V. EDOT does not
> officially support Flutter — EDOT Android's own documentation states that hybrid
> frameworks such as React Native and Flutter are not supported.

Flutter plugin that surfaces the Elastic Distribution of OpenTelemetry (EDOT)
mobile Agents to Dart, so Flutter apps emit telemetry indistinguishable from this
organisation's React Native apps (`@inoxth/react-native-edot-sdk`).

## Requirements

| | Minimum |
|---|---|
| iOS | **15.6** — Swift Package Manager required, no CocoaPods support |
| Android | **API 24** (compileSdk 36) |
| Flutter | **3.44** — SPM is default-on from this version |

## Packages

| Package | Purpose |
|---|---|
| `packages/inoxth_edot_flutter` | Core: Dart API, both native implementations, `package:http` tracing |
| `packages/inoxth_edot_flutter_dio` | Dio interceptor. Separate because Dart has no optional dependencies (ADR-0010) |
| `packages/edot_collector_harness` | Seam 2 test harness. Never published |

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
dart run tool/verify_network.dart -d <device>
dart run tool/verify_collector_host_exclusion.dart -d <ios-device>  # iOS only, ADR-0006
dart run tool/verify_signals.dart -d <android-device>               # Android only, ADR-0011
```

Each host half exits 2 with an explanation when Docker is absent, rather than
passing. A silently skipped Seam 2 tier reads as coverage it does not have.

## Status

Foundation only. The Agent is not initialised yet and no telemetry is produced —
that begins with the tracer-bullet ticket. See the issue tracker for the ticket
sequence, and `docs/adr/` for the decisions the implementation is bound by.

Full integrator documentation, including the complete list of deliberate
limitations, lands with the documentation ticket.
