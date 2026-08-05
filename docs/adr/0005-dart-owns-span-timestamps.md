# Dart owns span timestamps

Status: accepted (amended — NTP correction removed, see Amendment)

## Context

Under ADR-0002 the Agent creates the real span when a channel message arrives. Channel delivery is
asynchronous and scheduler-dependent, so timestamping at arrival folds channel latency and jitter
into every duration — tolerable for a 400 ms network call, ruinous for the short spans people use to
hunt jank.

Letting Dart supply timestamps fixes durations but forfeits something real: the Agents perform NTP
time synchronisation precisely because device clocks drift, sometimes by minutes, which destroys
correlation with backend spans. `DateTime.now()` bypasses that correction.

Telemetry can also be emitted before Agent initialisation completes.

## Decision

Dart anchors a wall-clock start once and measures elapsed time with a monotonic `Stopwatch`, deriving
the end from the two — so a wall-clock jump mid-span cannot distort the duration. Both timestamps
cross the channel explicitly and the Agent applies them verbatim.

Telemetry emitted before the Agent is ready goes into a bounded Dart queue, dropping oldest, and the
number dropped is attached as an attribute on flush so loss is visible rather than silent.

## Amendment — NTP correction is not applied

This ADR originally required the Agent to add its own NTP offset to incoming Dart timestamps.
**That is not implementable on the versions pinned by ADR-0001**, discovered while implementing the
tracer bullet:

- `co.elastic.otel.android:agent-sdk` 1.1.0 exposes no clock, time or offset accessor in its public API.
- `apm-agent-ios` 1.2.1's `AgentConfigBuilder` exposes none either.

Both Agents perform time synchronisation internally, but neither surfaces the offset, so there is
nothing for the native side to add.

Dart timestamps are therefore applied **verbatim**. The properties that motivated Dart-side
timestamping all hold: durations are exact, immune to channel jitter, and unaffected by a wall-clock
jump mid-span. What is lost is absolute accuracy — timestamps sit on the device's unsynchronised
clock.

The alternative considered was to omit the start timestamp so the Agent's own (NTP-corrected) clock
stamps the start, then end at that start plus Dart's measured elapsed. That recovers absolute
accuracy and keeps duration exact, at the cost of channel latency landing in the start timestamp —
and it rests on an assumption about the Agent's tracer clock that the public API does not confirm.
Rejected for now as unverifiable without empirical measurement; revisit if backend correlation
proves unreliable in practice, or when the floors rise far enough to pin an Agent that exposes its
offset.

## Amendment — Android rewrites the timestamps at export

"Applied verbatim" is true of what the Agent's builders accept and false of what leaves the
device. Found while verifying the pre-initialisation buffer at Seam 2.

`co.elastic.otel.android:agent-sdk` 1.1.0 tags every span and log record with a monotonic
**creation elapsed time** attribute, and its `ClockExporterGateManager` replaces the timestamp
at export with that elapsed time plus the Agent's own NTP offset. Whatever the Plugin sent is
overwritten. The classes are `ClockExporterGateManager$TimeUpdatedSpanData`,
`$TimeUpdatedLogRecordData` and `$ElapsedTimeAttributeInterceptor`.

This is a reasonable thing for the Agent to do — it is how telemetry recorded before the clock
was synced gets a corrected absolute time — but it has two consequences the Plugin has to own:

- **Telemetry held by the pre-initialisation queue is dated when it was replayed**, not when it
  was produced, because "creation" from the Agent's point of view is the replay. The Plugin
  sends the real timestamp and cannot make Android use it. An early-startup error therefore
  appears at start, not before it. Durations are unaffected — a span's start and end are
  rewritten by the same offset — so what is lost is the absolute position of held telemetry.
- **Absolute Android timestamps depend on the Agent's clock-sync state at export.** Measured
  twice on one emulator, the gap between two records produced three seconds apart came out as
  6 nanoseconds and then as nearly nine hours. That is the emulator's NTP being wrong, not the
  Plugin, but it means an absolute timestamp from an unsynchronised Android device is not
  something to build an alert on.

iOS has no equivalent rewrite: `apm-agent-ios` 1.2.1 passes the builder's timestamp through, so
the Plugin's value is what is exported. The Plugin therefore sends the timestamp on every log
record regardless — it is honoured on one platform and harmless on the other, and dropping it
would make iOS date held records at replay too.

Neither behaviour is assertable in the current harness, and the Seam 2 suite prints what it
measured instead of asserting it: Android overrides the value, and iOS cannot run that suite at
all because `flush` does not drain log records there (ADR-0011).

## Consequences

- The channel protocol carries explicit start and end timestamps on every span. Both pinned Agents accept them (`SpanBuilder.setStartTimestamp`, explicit end time).
- Durations are exact. **Absolute times are only as accurate as the device clock** — a device minutes out of sync will produce spans that are internally consistent but misaligned with the backend spans they correlate to. Correlation by `session.id` and trace context is unaffected; correlation by timestamp is.
- Dropping oldest means a burst during startup loses the earliest events. Preferred to unbounded memory growth, and the drop count makes it diagnosable.
