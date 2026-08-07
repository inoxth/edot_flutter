// Seam 2, host half — asserts that Dart Errors reach the collector as error records.
//
//   dart run tool/verify_error.dart -d <android-device>
//
// Android only: flush() drains log records on Android but not on iOS (ADR-0011), so an
// iOS run would be asserting on the Agent's own export timers. The device half fails
// loudly rather than quietly passing there.
//
// Exits non-zero with a report listing every failed assertion.
import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';

import '../integration_test/error_contract.dart';

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
    // Keyed on markers rather than sources: the in-operation error is reported by the
    // app too, so waiting on `dart_reported` to be non-empty would go ahead while it was
    // still in flight.
    final output = await collector.waitFor(
      (o) =>
          _markers.every((marker) => _recordsMarked(o, marker).isNotEmpty) &&
          o.spansNamed(failingOperationName).isNotEmpty,
    );

    _report(output);
    _assertFrameworkError(output);
    _assertUncaughtError(output);
    _assertIsolateError(output);
    _assertReportedError(output);
    _assertNonFatal(output);
    _assertTheFailingOperation(output);
  } finally {
    await collector.stop();
  }

  if (_failures.isEmpty) {
    stdout.writeln('\nDart Errors survived export from every source.');
    return;
  }

  stderr.writeln('\nDart Error capture failed:');
  for (final failure in _failures) {
    stderr.writeln('  - $failure');
  }
  exit(1);
}

const _sources = <String>[
  frameworkSource,
  uncaughtSource,
  isolateSource,
  reportedSource,
];

/// Every error the device half captures — five, because the in-operation one is reported
/// by the app as well and so shares a source with another.
const _markers = <String>[
  frameworkMarker,
  uncaughtMarker,
  isolateMarker,
  reportedMarker,
  operationMarker,
];

Future<int> _runDeviceHalf(List<String> args) async {
  final process = await Process.start('flutter', [
    'test',
    'integration_test/error_test.dart',
    ...args,
  ], mode: ProcessStartMode.inheritStdio);

  return process.exitCode;
}

/// Every exported record claiming this `error.source`.
List<ExportedLogRecord> _recordsFrom(CollectorOutput output, String source) =>
    output.logs
        .where((l) => l.attributes[errorSourceAttribute] == source)
        .toList();

/// Every exported record whose body names this error.
List<ExportedLogRecord> _recordsMarked(CollectorOutput output, String marker) =>
    output.logs
        .where((l) => l.body is String && (l.body as String).contains(marker))
        .toList();

void _report(CollectorOutput output) {
  for (final source in _sources) {
    for (final record in _recordsFrom(output, source)) {
      stdout.writeln(
        '    error  ${record.severityText}/${record.severityNumber}  '
        '$source  ${record.body}',
      );
    }
  }
  for (final span in output.spansNamed(failingOperationName)) {
    stdout.writeln('    span   $span  status=${span.statusCode}');
  }
}

void _assertFrameworkError(CollectorOutput output) {
  final record = _theRecord(output, frameworkSource, frameworkMarker);
  if (record == null) return;

  _assertVocabulary(record, frameworkSource, frameworkMarker);
  _expect(
    record.attributes[exceptionTypeAttribute],
    frameworkExceptionType,
    'framework error exception type',
  );

  // The framework's own description of what it was doing — the most useful line in a
  // Flutter error, and the only source that has one.
  final context = record.attributes[errorContextAttribute];
  if (context == null) {
    _failures.add(
      'framework error lost $errorContextAttribute, which is the only place the '
      'framework says what it was building',
    );
  }
}

void _assertUncaughtError(CollectorOutput output) {
  final record = _theRecord(output, uncaughtSource, uncaughtMarker);
  if (record == null) return;

  _assertVocabulary(record, uncaughtSource, uncaughtMarker);
  _expect(
    record.attributes[exceptionTypeAttribute],
    uncaughtExceptionType,
    'uncaught async error exception type',
  );
}

void _assertIsolateError(CollectorOutput output) {
  final record = _theRecord(output, isolateSource, isolateMarker);
  if (record == null) return;

  _assertVocabulary(record, isolateSource, isolateMarker);

  // An isolate's error crosses the boundary already formatted, so its Dart type is
  // gone. The Plugin says so rather than reporting the type of what arrived, which
  // would put `String` on every isolate error in Kibana.
  _expect(
    record.attributes[exceptionTypeAttribute],
    isolateExceptionType,
    'isolate error exception type',
  );
}

void _assertReportedError(CollectorOutput output) {
  final record = _theRecord(output, reportedSource, reportedMarker);
  if (record == null) return;

  _assertVocabulary(record, reportedSource, reportedMarker);
  _expect(
    record.attributes[exceptionTypeAttribute],
    reportedExceptionType,
    'reported error exception type',
  );
}

/// The load-bearing assertion of this suite (ADR-0008).
///
/// Every record, checked together rather than per source: a Dart Error arriving as a
/// crash would silently corrupt crash-free rate, and one source getting it wrong is as
/// bad as all four.
void _assertNonFatal(CollectorOutput output) {
  for (final source in _sources) {
    for (final record in _recordsFrom(output, source)) {
      _expect(
        record.severityText,
        errorSeverityText,
        '$source severity text — a Dart Error is never fatal',
      );
      _expect(
        record.severityNumber,
        errorSeverityNumber,
        '$source severity number',
      );
    }
  }
}

void _assertTheFailingOperation(CollectorOutput output) {
  // Both halves of it. The record is the one anyone searching Kibana for the error will
  // find; the span is what makes the failure visible on the operation. One without the
  // other is half the feature.
  final record = _theRecord(output, reportedSource, operationMarker);
  if (record != null) {
    _assertVocabulary(record, reportedSource, operationMarker);
    _expect(
      record.attributes[exceptionTypeAttribute],
      operationExceptionType,
      'in-operation error exception type',
    );
  }

  final span = output.spansNamed(failingOperationName).firstOrNull;
  if (span == null) {
    _failures.add('the failing operation never arrived');
    return;
  }

  if (!span.isError) {
    _failures.add(
      'the failing operation arrived with status ${span.statusCode}, expected '
      'ERROR — an error inside an operation has to be visible on the operation',
    );
  }

  final event = span.eventNamed(spanExceptionEventName);
  if (event == null) {
    _failures.add(
      'the failing operation carries no $spanExceptionEventName event; events '
      'present: ${span.events.map((e) => e.name).toList()}',
    );
    return;
  }

  _expect(
    event.attributes[exceptionTypeAttribute],
    operationExceptionType,
    'operation exception event type',
  );
  _expectContains(
    event.attributes[exceptionMessageAttribute],
    operationMarker,
    'operation exception event message',
  );
}

/// The ADR-0003 error vocabulary, which every record carries whatever its source.
void _assertVocabulary(ExportedLogRecord record, String source, String marker) {
  // Fleet Alignment: this organisation's React Native SDK stamps every error record
  // with it, so a dashboard filtering on it must find this fleet's too.
  _expect(
    record.attributes[eventNameAttribute],
    exceptionEventName,
    '$source $eventNameAttribute',
  );

  _expectContains(record.body, marker, '$source record body');
  _expectContains(
    record.attributes[exceptionMessageAttribute],
    marker,
    '$source $exceptionMessageAttribute',
  );

  if (record.attributes[exceptionStacktraceAttribute] == null) {
    _failures.add('$source lost $exceptionStacktraceAttribute');
  }

  // ADR-0004: enrichment happens in Dart, so it has to survive the channel as an
  // ordinary attribute rather than being added natively.
  _expect(
    record.attributes[screenNameAttribute],
    activeView,
    '$source $screenNameAttribute',
  );

  _expect(
    record.resource['service.name'],
    'edot-flutter-seam2',
    '$source resource identity',
  );
}

/// The single record for one error, or null with a failure recorded.
///
/// Keyed on the marker as well as the source, because the source alone does not identify
/// an error: the in-operation error is reported by the app too, so `dart_reported` covers
/// two of them.
///
/// Exactly one: a second copy of the same error would mean it was captured twice, and
/// every other assertion here would pass on either copy.
ExportedLogRecord? _theRecord(
  CollectorOutput output,
  String source,
  String marker,
) {
  final records = _recordsMarked(
    output,
    marker,
  ).where((r) => r.attributes[errorSourceAttribute] == source).toList();
  if (records.length == 1) return records.single;

  _failures.add(
    'expected exactly one $source record containing "$marker", '
    'found ${records.length}',
  );
  return null;
}

void _expect(Object? actual, Object? expected, String what) {
  if (actual != expected) {
    _failures.add('$what: got $actual, expected $expected');
  }
}

void _expectContains(Object? actual, String expected, String what) {
  if (actual is! String || !actual.contains(expected)) {
    _failures.add('$what: got $actual, expected it to contain "$expected"');
  }
}
