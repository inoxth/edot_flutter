# edot_collector_harness

Seam 2 test infrastructure for `inoxth_edot_flutter`. **Not published, not a consumer
API** — it exists so integration tests can run a real OpenTelemetry Collector and read
back the telemetry the Plugin actually exported to it.

Seam 1 is hermetic Dart against a mocked platform channel. Seam 2 is the real thing: the
Agent exports OTLP to a collector this harness runs, and the test asserts on what landed.
Every Seam 2 suite is a device half (drives the app) and a host half (`tool/verify_*.dart`,
which owns the assertions and reads through this harness).

## What it gives a test

- **`CollectorProcess`** — brings a collector up and down through docker compose.
  `start()`, `stop()`, `reset()`, `resume()`; `read()` returns what has landed so far;
  `waitFor(...)` polls until a predicate holds or times out. `isAvailable` reports whether
  the environment can run one at all, so a suite can skip rather than fail where it cannot.
  `hostEndpoint` and `androidEmulatorEndpoint` are the two OTLP URLs — the emulator reaches
  the host as `10.0.2.2`.
- **`CollectorOutput`** — the parsed telemetry: `spans`, `logs`, `metrics`, with
  `spanNamed()`, `logWithBody()`, `metricNamed()` and `traceIds` for the assertions a suite
  actually writes.
- **`ExportedSpan` / `ExportedLogRecord` / `ExportedMetric`** — one decoded record each,
  down to attributes, resource, events and status.

## Caveats worth knowing

- The collector's `file` exporter **truncates on container start**, so telemetry from
  before a restart is not in the file afterwards; `CollectorProcess` carries earlier lines
  forward across a `stop()`/`resume()` so a test spanning a restart still sees them.
- `flutter test` uninstalls the app when the run ends, on both platforms, so app data does
  not survive between runs — a suite cannot rely on a previous run having left anything.

## Metadata

`publish_to: none` and version `0.0.0`: never released, so it carries no CHANGELOG and no
LICENSE of its own — the repository-root MIT `LICENSE` covers it.
