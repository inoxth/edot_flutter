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

## Consequences

- The channel protocol carries explicit start and end timestamps on every span. Both pinned Agents accept them (`SpanBuilder.setStartTimestamp`, explicit end time).
- Durations are exact. **Absolute times are only as accurate as the device clock** — a device minutes out of sync will produce spans that are internally consistent but misaligned with the backend spans they correlate to. Correlation by `session.id` and trace context is unaffected; correlation by timestamp is.
- Dropping oldest means a burst during startup loses the earliest events. Preferred to unbounded memory growth, and the drop count makes it diagnosable.
