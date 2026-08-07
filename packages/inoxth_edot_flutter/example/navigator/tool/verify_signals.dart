// Seam 2, host half — asserts that log records and metrics reach the collector.
//
//   dart run tool/verify_signals.dart -d <android-device>
//
// Android only: flush() drains neither signal on iOS (ADR-0011), so an iOS run
// would be asserting on the Agent's own export timers. The device half fails
// loudly rather than quietly passing there.
//
// Exits non-zero with a report listing every failed assertion.
import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';

import '../integration_test/signals_contract.dart';

final _failures = <String>[];

Future<void> main(List<String> args) async {
  final collector = CollectorProcess(
    composeDirectory: Directory('../../../../tool/collector'),
    outputDirectory: Directory.systemTemp.createTempSync('edot-collector-'),
  );

  if (!await CollectorProcess.isAvailable) {
    stderr.writeln(
      'Docker is not available, so there is no collector to assert against.\n'
      'Seam 2 cannot run. Start Docker and try again.',
    );
    exit(2);
  }

  stdout.writeln('==> starting collector');
  await collector.start();

  try {
    stdout.writeln('==> running the device half');
    final device = await _runDeviceHalf(args);
    if (device != 0) {
      stderr.writeln(
        'The device half failed; not asserting on partial output.',
      );
      exit(device);
    }

    stdout.writeln('==> reading exported telemetry');
    final output = await collector.waitFor(
      (o) =>
          o.logsWithBody(logMessage).isNotEmpty &&
          _metricNames.every((name) => o.metricsNamed(name).isNotEmpty),
    );

    _report(output);
    _assertLogRecord(output);
    _assertMetrics(output);
  } finally {
    await collector.stop();
  }

  if (_failures.isEmpty) {
    stdout.writeln('\nLog records and metrics survived export.');
    return;
  }

  stderr.writeln('\nLogs and metrics failed:');
  for (final failure in _failures) {
    stderr.writeln('  - $failure');
  }
  exit(1);
}

const _metricNames = <String>[
  counterMetricName,
  upDownCounterMetricName,
  histogramMetricName,
];

Future<int> _runDeviceHalf(List<String> args) async {
  final process = await Process.start('flutter', [
    'test',
    'integration_test/signals_test.dart',
    ...args,
  ], mode: ProcessStartMode.inheritStdio);

  return process.exitCode;
}

void _report(CollectorOutput output) {
  for (final record in output.logsWithBody(logMessage)) {
    stdout.writeln(
      '    log  ${record.severityText}/${record.severityNumber}  '
      '${record.attributes}',
    );
  }
  for (final name in _metricNames) {
    for (final metric in output.metricsNamed(name)) {
      stdout.writeln('    metric  $metric');
    }
  }
}

void _assertLogRecord(CollectorOutput output) {
  final record = output.logWithBody(logMessage);

  _expect(
    record.severityText,
    logSeverityText,
    'log severity text — the Plugin sends the same name the Dart enum uses, so '
    'the two fleets read alike in Kibana',
  );
  _expect(record.severityNumber, logSeverityNumber, 'log severity number');
  _expect(
    record.resource['service.name'],
    'edot-flutter-seam2',
    'log resource identity',
  );

  // The whole reason log attributes travel type-tagged: an int must not arrive as
  // a double, and vice versa. Types are checked as well as values, because 42 and
  // 42.0 compare equal in Dart and would let the failure through.
  logAttributes.forEach((key, expected) {
    final actual = record.attributes[key];
    _expect(actual, expected, 'log attribute $key');

    if (actual != null && actual.runtimeType != expected.runtimeType) {
      _failures.add(
        'log attribute $key arrived as ${actual.runtimeType}, '
        'expected ${expected.runtimeType}',
      );
    }
  });
}

void _assertMetrics(CollectorOutput output) {
  // A counter and an up-down counter are the same OTLP sum; only isMonotonic
  // separates them, so it is the assertion that proves the kind was honoured
  // rather than defaulted.
  final counter = _firstExportOf(output, counterMetricName);
  _expectKind(counter, MetricKind.sum, isMonotonic: true);
  _expect(counter?.point.value, counterMetricValue, 'counter value');

  final upDown = _firstExportOf(output, upDownCounterMetricName);
  _expectKind(upDown, MetricKind.sum, isMonotonic: false);
  _expect(
    upDown?.point.value,
    upDownCounterMetricValue,
    'up-down counter value',
  );

  // A histogram reports what it aggregated, not the value handed to it.
  final histogram = _firstExportOf(output, histogramMetricName);
  _expectKind(histogram, MetricKind.histogram);
  _expect(histogram?.point.count, 1, 'histogram count');
  _expect(histogram?.point.sum, histogramMetricValue, 'histogram sum');

  for (final metric in [counter, upDown, histogram].nonNulls) {
    _expect(
      metric.point.attributes[metricDimensionKey],
      metricDimensionValue,
      '${metric.name} dimension',
    );
    _expect(
      metric.resource['service.name'],
      'edot-flutter-seam2',
      '${metric.name} resource identity',
    );
  }
}

/// The metric's first export.
///
/// First rather than last: under delta temporality only the export that follows
/// the record carries the value, while under cumulative temporality every export
/// carries it. First is the one that holds either way.
ExportedMetric? _firstExportOf(CollectorOutput output, String name) {
  final exports = output.metricsNamed(name);
  if (exports.isEmpty) {
    _failures.add('metric $name never arrived');
    return null;
  }
  return exports.first;
}

void _expectKind(ExportedMetric? metric, MetricKind kind, {bool? isMonotonic}) {
  if (metric == null) return;

  _expect(metric.kind, kind, '${metric.name} aggregation');
  _expect(metric.isMonotonic, isMonotonic, '${metric.name} monotonicity');
}

void _expect(Object? actual, Object? expected, String what) {
  if (actual != expected) {
    _failures.add('$what: got $actual, expected $expected');
  }
}
