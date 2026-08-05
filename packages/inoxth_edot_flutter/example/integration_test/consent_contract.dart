/// Shared contract between the two halves of the Tracking Consent test.
///
/// Deliberately free of Flutter imports: the host half runs under plain `dart run`,
/// where `dart:ui` does not exist.
///
/// **What this tier adds over Seam 1.** The gate itself is Dart-side and asserted
/// exhaustively at the channel, so this is not here to re-check it — one run cannot
/// beat twenty mutations. It exists for the two claims Seam 1 structurally cannot make:
///
/// 1. **Nothing reaches the collector while consent withholds it.** Seam 1 proves the
///    Plugin makes no channel call, which is the mechanism. This proves the outcome,
///    and would also catch a native side that emitted telemetry of its own accord.
/// 2. **A record held before start keeps the time it happened.** The timestamp crosses
///    the channel as microseconds and each Agent applies it with its own API — Android
///    in microseconds, iOS as a `Date`. A unit mix-up or an ignored value puts an
///    early-startup error at the wrong moment in Kibana, and only the exported record
///    can show that.
///
/// One app launch covers the whole sequence, because consent changes at runtime and
/// only `Edot.start` is once-per-process.
library;

/// Service name this suite's telemetry arrives under.
const String serviceName = 'edot-flutter-seam2-consent';

/// Emitted **before** `Edot.start`, so its arrival proves the queue replayed it and its
/// timestamp proves the replay did not re-date it.
const String heldRecordBody = 'held before the Agent was ready';

/// Emitted while consent is withdrawn. Must never arrive.
const String withheldRecordBody = 'produced while consent was withdrawn';

/// Emitted after consent is granted again. Must arrive.
///
/// Its purpose is to make the absence above mean something: without it, a run where
/// nothing at all was exported would satisfy the withheld assertion.
const String permittedRecordBody = 'produced after consent was restored';

/// How long consent stays withdrawn before being restored.
///
/// Long enough for the Agent's own instrumentation to export something if it is going to,
/// since that telemetry is outside the gate (ADR-0015) and this suite reports what arrives.
const Duration withdrawnWindow = Duration(seconds: 5);

/// How long the device waits between producing [heldRecordBody] and starting the Agent.
///
/// The whole basis of the timestamp assertion: it is the gap that must still be visible
/// between the two exported records. Long enough to be unmistakable against any
/// scheduling jitter, short enough not to pad the suite.
const Duration heldRecordDelay = Duration(seconds: 3);

/// Slack allowed on that gap.
///
/// The gap is measured between two exported timestamps, so it absorbs only the small
/// difference between when the record was produced and when the start call followed —
/// not clock error, which cancels. Far tighter than the fault being guarded against: a
/// record dated on replay would show a gap of nearly zero.
const Duration timestampTolerance = Duration(milliseconds: 500);
