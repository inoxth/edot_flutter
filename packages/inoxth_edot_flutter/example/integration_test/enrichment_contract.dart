/// Shared contract between the two halves of the span enrichment test.
///
/// Deliberately free of Flutter imports: the host half runs under plain
/// `dart run`, where `dart:ui` does not exist.
library;

/// The span both halves agree on.
const String enrichedSpanName = 'enriched-span';

/// A second span, marked failed, kept separate so the first can prove that
/// enrichment does not fail a span by accident.
const String failedSpanName = 'failed-span';

const String stringKey = 'probe.string';
const String intKey = 'probe.int';
const String doubleKey = 'probe.double';
const String boolKey = 'probe.bool';

const String stringValue = 'text-value';

/// Chosen so a float would be visible as one. 42 exported under `doubleValue`
/// comes back as 42.0, which is a different Dart type than 42 — that difference
/// is the assertion.
const int intValue = 42;

/// Whole-numbered on purpose: the risk runs both ways, and 3.0 narrowed to 3
/// would be just as wrong as 42 widened to 42.0.
const double doubleValue = 3.0;

const bool boolValue = true;

/// Recorded against [enrichedSpanName] without failing it.
const String exceptionMessageFragment = 'recorded-but-handled';

/// Description carried by [failedSpanName]'s error status.
const String failureDescription = 'operation rejected downstream';
