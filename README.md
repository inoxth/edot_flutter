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

## Platform differences you need to know about

The two pinned Agents are not equivalent, and none of these is something the Plugin
can paper over. Each is recorded in an ADR.

| | iOS | Android |
|---|---|---|
| **Native crash reporting** | On by default. **Opt out** with `EdotIosConfig(crashReportingEnabled: false)` | **Unavailable.** No toggle exists |
| **Session identifier** | Readable via `Edot.currentSessionId()` | Always empty |
| **Session sampling** | Unreliable — see below | Honoured |
| **Disk buffering** | Always on, cannot be disabled | `EdotAndroidConfig(diskBufferingEnabled:)` |
| **`flush()`** | Spans only | Spans, log records and metrics |

- **Android captures no native crashes.** Its Agent installs whatever instrumentation
  is on the classpath, with no filter and no runtime switch, so the only control is
  which artefacts ship — and this Plugin deliberately does not ship the crash one
  (ADR-0009). Dart Errors are captured on both platforms and are a separate signal
  from crashes by design (ADR-0008).
- **If your app already uses Crashlytics or Sentry, opt out of iOS crash reporting.**
  Crash capture installs process-wide signal and Mach exception handlers; for
  signal-based crashes whichever installed last tends to win, so leaving both on can
  silently stop your existing reporter — which nobody notices until an incident. It is
  on by default only to match the React Native SDK (ADR-0009).
- **Telemetry buffered through an outage arrives more than once.** The buffer retries any batch it
  could not confirm, so after an outage the same span can reach your collector twice — verified on
  Android. Count distinct span ids, not spans. Buffered telemetry also expires after 18 hours offline,
  and note that a *brief* outage is survived even with buffering off, because the exporter retries in
  memory for about 8 seconds (ADR-0011).
- **`sessionSamplingRate` is unreliable on iOS.** The pinned Agent's sampler starts out
  sampling everything and consults the rate only when a session is new or has expired,
  so a relaunch inside the 30-minute session window reports in full whatever the rate
  says. Use `disableAgent` to switch telemetry off — that works on both platforms
  (ADR-0001).

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
dart run tool/verify_navigation.dart -d <device>
dart run tool/verify_network.dart -d <device>
dart run tool/verify_trace_context.dart -d <device>
dart run tool/verify_collector_host_exclusion.dart -d <ios-device>  # iOS only, ADR-0006
dart run tool/verify_platform_config.dart -d <device>               # runs the device half 4x
dart run tool/verify_signals.dart -d <android-device>               # Android only, ADR-0011
dart run tool/verify_error.dart -d <android-device>                 # Android only, ADR-0011
dart run tool/verify_disk_buffering.dart -d <android-device>        # Android only, ADR-0011
```

`verify_disk_buffering.dart` is the one suite that stops the collector mid-run — it is the only way to
create the offline period disk buffering exists for. Expect it to take a few minutes: the outage has to
outlast the exporter's in-memory retry to prove anything.

Each host half exits 2 with an explanation when Docker is absent, rather than
passing. A silently skipped Seam 2 tier reads as coverage it does not have.

## Status

Foundation only. The Agent is not initialised yet and no telemetry is produced —
that begins with the tracer-bullet ticket. See the issue tracker for the ticket
sequence, and `docs/adr/` for the decisions the implementation is bound by.

Full integrator documentation, including the complete list of deliberate
limitations, lands with the documentation ticket.
