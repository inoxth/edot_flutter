/// Shared contract between the two halves of the logs-and-metrics test.
///
/// Deliberately free of Flutter imports: the host half runs under plain
/// `dart run`, where `dart:ui` does not exist.
library;

/// The log record's body, and the handle the host half finds it by.
const String logMessage = 'signals-log-record';

/// Emitted at `EdotSeverity.warn`. Both spellings are asserted: the number is
/// what a Kibana query filters on, the text is what a human reads.
const String logSeverityText = 'warn';
const int logSeverityNumber = 13;

/// Attributes covering every type the log channel carries. The int and the double
/// are the point of the set — a plain number crossing to a native side that has
/// to guess is exactly the trap the type-tagged encoding exists to close, and only
/// an export can prove the tag survived.
const Map<String, Object> logAttributes = <String, Object>{
  'signals.string': 'text',
  'signals.int': 42,
  'signals.double': 3.5,
  'signals.bool': true,
};

/// One metric per kind. A counter and an up-down counter are the same OTLP sum
/// on the wire, so recording both is the only way to prove the kind was honoured
/// rather than defaulted.
const String counterMetricName = 'signals.counter';
const double counterMetricValue = 3;

const String upDownCounterMetricName = 'signals.up_down_counter';

/// Negative deliberately: a monotonic counter would have rejected it.
const double upDownCounterMetricValue = -2;

const String histogramMetricName = 'signals.histogram';
const double histogramMetricValue = 180;

/// Metric dimensions are string-only (ADR-0012).
const String metricDimensionKey = 'signals.channel';
const String metricDimensionValue = 'checkout';
