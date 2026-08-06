/// Shared contract between the two halves of the Dart Error test.
///
/// Deliberately free of Flutter imports: the host half runs under plain
/// `dart run`, where `dart:ui` does not exist.
///
/// **What this suite proves that Seam 1 cannot.** Seam 1 asserts what the Plugin hands
/// to the channel. Only an export can show that a Dart Error survives the native
/// Agent's log pipeline with the ADR-0003 vocabulary intact — at `error` severity, and
/// never as a crash. The severity is the load-bearing part: ADR-0008 keeps Dart Errors
/// out of crash-free rate, and a record that arrived as `fatal` would silently make the
/// one metric mobile teams alert on untrustworthy.
library;

/// Each error carries its own marker in the message, so the host half can tell the four
/// records apart. Matching on `error.source` alone would not: a bug that stamped every
/// record with the same source would still find four records and pass.
const String frameworkMarker = 'seam2-error-framework';
const String uncaughtMarker = 'seam2-error-uncaught';
const String isolateMarker = 'seam2-error-isolate';
const String reportedMarker = 'seam2-error-reported';

/// The exception type each error should arrive with.
///
/// An isolate's error crosses the boundary already formatted, so its Dart type is gone
/// by the time anything can read it — [isolateExceptionType] is what the Plugin puts
/// there instead. Asserted rather than left unspecified: `String`, the type of what
/// actually arrived, would be a plausible-looking lie in Kibana.
const String frameworkExceptionType = 'StateError';
const String uncaughtExceptionType = 'FormatException';
const String isolateExceptionType = 'IsolateError';
const String reportedExceptionType = 'ArgumentError';

/// Wire values of `error.source`, per source. Restated here rather than imported from
/// the enum: a contract that read them from the code it checks could only prove the
/// code equals itself.
const String frameworkSource = 'flutter_framework';
const String uncaughtSource = 'dart_uncaught';
const String isolateSource = 'dart_isolate';
const String reportedSource = 'dart_reported';

/// Wire names, per ADR-0003.
const String eventNameAttribute = 'event.name';
const String exceptionTypeAttribute = 'exception.type';
const String exceptionMessageAttribute = 'exception.message';
const String exceptionStacktraceAttribute = 'exception.stacktrace';
const String errorSourceAttribute = 'error.source';
const String errorContextAttribute = 'error.context';
const String screenNameAttribute = 'screen.name';

/// Every error record carries this, matching this organisation's React Native SDK.
const String exceptionEventName = 'exception';

/// Dart Errors are non-fatal (ADR-0008). Both spellings are asserted: the number is
/// what a Kibana query filters on, the text is what a human reads.
const String errorSeverityText = 'error';
const int errorSeverityNumber = 17;

/// The Active View at the time every error is captured, which each record must carry.
const String activeView = 'Seam2ErrorScreen';

/// The framework error is raised inside a subtree wrapped by an error boundary, so the
/// device half can show that a failing subtree reports itself once and renders this.
const String fallbackText = 'section unavailable';

/// An operation in flight when an error is captured, which must arrive failed and
/// carrying an `exception` event of its own — the failure visible on the operation, not
/// only in a log nobody correlated.
const String failingOperationName = 'seam2-failing-operation';

/// The exception the operation is failed with, which becomes its status description.
const String operationExceptionType = 'UnsupportedError';
const String operationMarker = 'seam2-error-in-operation';

/// The `exception` event the Agent records on a span, per OpenTelemetry.
const String spanExceptionEventName = 'exception';
