# flush() drains buffers; it does not promise delivery

Status: accepted (amended — iOS flush covers traces only, see Amendment)

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
- **The buffer does deliver after an outage, and delivery is at-least-once.** Verified at Seam 2 on
  Android: a span produced while the collector was unreachable arrives once it is reachable again, and
  the same span id was seen arriving twice. `FromDiskExporterImpl` returns `TRY_LATER` for a failed
  export, which leaves the batch on disk to be retried — so a batch it delivered but could not confirm
  is delivered again. Anything counting spans will over-count after an outage; dashboards should treat
  span identity, not span volume, as the truth.
- **Disk buffering is not what makes a *brief* outage survivable.** The OTLP exporter retries in memory
  5 times with backoffs of 1s, 1.5s, 2.25s and 3.375s, so roughly 8 seconds of unreachability is
  survived with the buffer switched off. What the buffer adds is durability past that budget. Worth
  knowing before attributing recovered telemetry to buffering, and it is why the Seam 2 outage is 45
  seconds — a shorter one cannot tell the two mechanisms apart.
- **Buffered telemetry expires after 18 hours.** Neither Agent overrides `maxFileAgeForReadMillis`, so
  both take upstream's 18-hour default and discard anything older instead of delivering it. An app
  offline for longer than that loses the oldest telemetry silently. Not verified — no test can wait it
  out — so it is recorded from the pinned sources rather than measured.
- **The offline-delivery tier is Android-only.** On iOS the upload is driven by the persistence worker,
  whose delay grows on every failure to a 20-second ceiling and which nothing reachable can drive, per
  the Context above. Runs there had the same case deliver everything and then nothing, so the suite
  refuses to run outside Android rather than reporting a timer's luck as a result. iOS buffers to disk
  unconditionally and its worker does keep batches whose export failed — `DataExportWorker` only calls
  `markBatchAsRead` when the export did not need a retry — so the mechanism is present; it is the
  *timing* that is unassertable.

## Amendment — on iOS, flush covers traces only, not metrics

This ADR and the original `flush()` implementation both claimed iOS flushed traces *and* metrics. That
was wrong, and the code backing it never ran.

`apm-agent-ios` 1.2.1 registers the **legacy** `MeterProviderBuilder`, so
`OpenTelemetry.instance.meterProvider` is a `MeterProviderSdk` — deprecated, and exposing no
`forceFlush`. The Plugin's flush cast to `StableMeterProviderSdk`, which that value never is, so the
cast silently failed and no metric flush was ever attempted.

There is no public path to force one. `MeterProviderSdk` holds its `PushMetricController` in a
non-public property and pushes on `defaultPushInterval`, which is **60 seconds**; the Agent does not
override it. `getMeters()` is internal too.

So on iOS: traces are drained into the persistence buffer as described above, log records are not
drained at all, and metrics are not drained either — they leave on the Agent's own 60-second timer.
The dead cast is removed rather than left looking like it does something, and `Edot.flush()` documents
traces only.

This is also why the metrics tier asserts exported metrics on Android alone: a Seam 2 metric assertion
on iOS would have to wait out a minute per run.

Anyone bumping the iOS Agent pin should check whether it has moved to `StableMeterProviderBuilder`,
which does expose `forceFlush`. See also ADR-0012, which records the other consequence of the Agent
still being on the legacy meter: metric attributes can only be strings.
