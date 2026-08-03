# Dart owns span timestamps; the Agent applies its NTP offset

Status: accepted

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
the end from the two — so an NTP jump mid-span cannot distort the duration. Both timestamps cross the
channel explicitly, and the Agent adds its own NTP offset before applying them.

Telemetry emitted before the Agent is ready goes into a bounded Dart queue, dropping oldest, and the
number dropped is attached as an attribute on flush so loss is visible rather than silent.

## Consequences

- The channel protocol carries explicit start and end timestamps on every span. Both pinned Agents accept them (`SpanBuilder.setStartTimestamp`, explicit end time).
- Durations are accurate; absolute times are as accurate as the Agent's NTP offset.
- Dropping oldest means a burst during startup loses the earliest events. Preferred to unbounded memory growth, and the drop count makes it diagnosable.
