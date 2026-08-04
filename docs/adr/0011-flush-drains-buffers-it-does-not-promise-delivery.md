# flush() drains buffers; it does not promise delivery

Status: accepted

## Context

`Edot.flush()` was specified so that a just-created span becomes assertable without waiting out a batch
timer. That is what makes the Seam 2 tier fast instead of slow and flaky, so the promise matters to
testing as much as to shutdown paths.

Both pinned Agents put a **durable buffer** between the batch processor and the network, and in both the
flush call reaches the buffer but not the network.

On iOS, `apm-agent-ios` 1.2.1 always wraps its OTLP exporter in `PersistenceSpanExporterDecorator` —
`createPersistenceFolder()` is unconditional, so there is no configuration that removes it. The chain
from our flush is:

```
TracerProviderSdk.forceFlush()
  → BatchSpanProcessor.forceFlush()
    → BatchWorker.exportBatch()
      → spanExporter.export(spans:)      ← writes to disk, returns .success
```

`BatchWorker` never calls `spanExporter.flush()`. The decorator's own `flush()` *would* upload
synchronously — `DataExportWorker.flush()` does a `queue.sync` over `onRemainingBatches`, which ignores
the file-age filter — but nothing reachable from public API calls it. `ElasticSpanProcessor` holds the
exporter in an `internal` property, so the Plugin cannot reach it either. The upload therefore happens
only on the persistence worker's own schedule: with the default `PersistencePerformancePreset`, a file
stays writable for up to 4.75s, is not readable until 5.25s old, and exports re-schedule on a ~5s delay.

On Android, `co.elastic.otel.android:agent-sdk` 1.1.0 has the same shape, but disk buffering is
configurable. With `DiskBufferingConfiguration.disabled()` the flush goes straight to the OTLP exporter
and the span is on the wire before the call returns. With buffering enabled — the default, and the right
default for a real app — flush reaches the disk buffer and a periodic job uploads afterwards.

Measured on the tracer-bullet spans: Android with buffering disabled delivered inside the flush;
Android with buffering enabled and iOS delivered nothing at all within the app's lifetime, because the
test harness kills the app as soon as the test body returns.

## Decision

Keep `flush()`, and narrow its documented promise to what the Agents can actually honour: **it drains
in-memory buffers so nothing is left waiting on a batch timer.** It does not promise the telemetry has
left the device.

The Seam 2 tier gets its speed from `EdotAndroidConfig.diskBufferingEnabled: false` on Android. On iOS
the tier waits out the persistence worker instead, because there is no equivalent switch.

Rejected: rebuilding the export pipeline ourselves — registering our own tracer provider with a
non-persistent exporter — to make flush synchronous on iOS. It would work, and it would mean the Plugin
owns export rather than the Agent, contradicting ADR-0002 and forfeiting everything the Agent's own
instrumentation contributes. Rejected: shipping a second, non-persistent exporter alongside the
Agent's, which would duplicate every span.

## Consequences

- `flush()` means slightly different things on the two platforms. That is a property of the pinned
  Agents (ADR-0001), not a choice, which is why it is written down rather than smoothed over.
- Shutdown paths must not assume delivery. Neither Agent can offer a flush-then-exit guarantee, so the
  API must not imply one.
- The iOS Seam 2 tier carries a fixed wait of roughly the persistence window. If that grows painful, the
  cheapest lever is exposing `InstrumentationConfigBuilder`'s persistent-storage preset so tests can ask
  for `instantDataDelivery` (~3.5s instead of ~11s). Deliberately not built yet — it is a public API
  addition for a test-speed problem that is not yet a real cost.
- Anyone bumping the iOS Agent pin should re-check whether `BatchWorker` has learned to call
  `spanExporter.flush()`. If it has, the iOS wait can be deleted and this ADR superseded.
