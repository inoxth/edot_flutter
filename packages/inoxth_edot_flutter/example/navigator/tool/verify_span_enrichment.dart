// Seam 2, host half — asserts that span enrichment survives native decoding.
//
//   dart run tool/verify_span_enrichment.dart -d <device>
//
// Exits non-zero with a report listing every failed assertion.
import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';

import '../integration_test/enrichment_contract.dart';

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
          o.spansNamed(enrichedSpanName).isNotEmpty &&
          o.spansNamed(failedSpanName).isNotEmpty,
    );

    _assertAttributeTypes(output.spanNamed(enrichedSpanName));
    _assertRecordedException(output.spanNamed(enrichedSpanName));
    _assertErrorStatus(output.spanNamed(failedSpanName));
  } finally {
    await collector.stop();
  }

  if (_failures.isEmpty) {
    stdout.writeln('\nSpan enrichment survived export.');
    return;
  }

  stderr.writeln('\nSpan enrichment failed:');
  for (final failure in _failures) {
    stderr.writeln('  - $failure');
  }
  exit(1);
}

Future<int> _runDeviceHalf(List<String> args) async {
  final process = await Process.start('flutter', [
    'test',
    'integration_test/span_enrichment_test.dart',
    ...args,
  ], mode: ProcessStartMode.inheritStdio);

  return process.exitCode;
}

void _assertAttributeTypes(ExportedSpan span) {
  final attributes = span.attributes;
  stdout.writeln(
    '    $stringKey=${attributes[stringKey]} (${attributes[stringKey].runtimeType})\n'
    '    $intKey=${attributes[intKey]} (${attributes[intKey].runtimeType})\n'
    '    $doubleKey=${attributes[doubleKey]} (${attributes[doubleKey].runtimeType})\n'
    '    $boolKey=${attributes[boolKey]} (${attributes[boolKey].runtimeType})',
  );

  _expectValue(attributes[stringKey], stringValue, stringKey);
  _expectValue(attributes[boolKey], boolValue, boolKey);

  // The assertion this ticket exists for. The harness maps OTLP `intValue` to
  // Dart int and `doubleValue` to Dart double, so the runtime type here reports
  // which OTLP field the value actually arrived in — not merely what it equals.
  // An integer that became a float would show up as 42.0, a double, and would
  // still pass an `== 42` check.
  final exportedInt = attributes[intKey];
  if (exportedInt is! int) {
    _failures.add(
      '$intKey exported as ${exportedInt.runtimeType} ($exportedInt), not int — '
      'the integer was widened to a floating-point attribute somewhere between '
      'Dart and export, which makes it useless to aggregate',
    );
  } else {
    _expectValue(exportedInt, intValue, intKey);
  }

  // The mirror image: a whole-numbered double must not come back narrowed.
  final exportedDouble = attributes[doubleKey];
  if (exportedDouble is! double) {
    _failures.add(
      '$doubleKey exported as ${exportedDouble.runtimeType} ($exportedDouble), '
      'not double — a whole-numbered double was narrowed to an integer',
    );
  } else {
    _expectValue(exportedDouble, doubleValue, doubleKey);
  }
}

void _assertRecordedException(ExportedSpan span) {
  final event = span.eventNamed('exception');
  if (event == null) {
    _failures.add(
      'no "exception" event on $enrichedSpanName; '
      'events present: ${span.events.map((e) => e.name).toList()}',
    );
    return;
  }

  stdout.writeln('    exception event: ${event.attributes}');

  _expectValue(
    event.attributes['exception.type'],
    'StateError',
    'exception.type',
  );

  final message = event.attributes['exception.message'];
  if (message is! String || !message.contains(exceptionMessageFragment)) {
    _failures.add(
      'exception.message does not contain "$exceptionMessageFragment": $message',
    );
  }

  final stacktrace = event.attributes['exception.stacktrace'];
  if (stacktrace is! String || stacktrace.trim().isEmpty) {
    _failures.add('exception.stacktrace missing or empty: $stacktrace');
  }

  // Recording an exception must not fail the span. If this flips, the two
  // operations have been conflated somewhere native.
  if (span.isError) {
    _failures.add(
      '$enrichedSpanName is in error status, but only an exception was recorded '
      'on it — recordException must not fail a span',
    );
  }
}

void _assertErrorStatus(ExportedSpan span) {
  stdout.writeln(
    '    $failedSpanName status=${span.statusCode} "${span.statusMessage}"',
  );

  if (!span.isError) {
    _failures.add(
      '$failedSpanName exported with status ${span.statusCode}, expected 2 (ERROR)',
    );
  }
  _expectValue(span.statusMessage, failureDescription, 'status message');
}

void _expectValue(Object? actual, Object? expected, String what) {
  if (actual != expected) {
    _failures.add('$what: expected $expected, got $actual');
  }
}
