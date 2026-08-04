// Seam 2, host half — asserts what the device actually exported.
//
// The device half (integration_test/tracer_bullet_test.dart) runs on a
// simulator or emulator and cannot read the collector's output file, which
// lives on this machine. So this script owns the assertions, and drives the
// device half itself so the whole check is one command:
//
//   dart run tool/verify_tracer_bullet.dart            # first attached device
//   dart run tool/verify_tracer_bullet.dart -d emulator-5554
//
// Exits non-zero with a report on the first failed assertion.
import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';

/// Matches the span names and identity in the device half. Kept in sync by hand;
/// the two halves run in different processes on different machines, so there is
/// nowhere to share a constant.
const _slowSpanName = 'tracer-bullet-span';
const _fastSpanName = 'tracer-bullet-fast';
const _serviceName = 'edot-flutter-seam2';
const _serviceVersion = '0.0.1';
const _environment = 'integration-test';
const _scopeName = 'inoxth_edot_flutter';

/// The device half waits this long inside the slow span.
const _slowSpanWait = Duration(milliseconds: 250);

final _failures = <String>[];

Future<void> main(List<String> args) async {
  // Paths are relative to this package, matching the existing Seam 2 test. The
  // output goes to a temp directory so a run cannot inherit a previous run's
  // spans through a checked-in path.
  final collector = CollectorProcess(
    composeDirectory: Directory('../../../tool/collector'),
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
          o.spansNamed(_slowSpanName).isNotEmpty &&
          o.spansNamed(_fastSpanName).isNotEmpty,
    );

    _assertSpans(output);
  } finally {
    await collector.stop();
  }

  if (_failures.isEmpty) {
    stdout.writeln('\nSeam 2 passed.');
    return;
  }

  stderr.writeln('\nSeam 2 failed:');
  for (final failure in _failures) {
    stderr.writeln('  - $failure');
  }
  exit(1);
}

Future<int> _runDeviceHalf(List<String> args) async {
  final process = await Process.start('flutter', [
    'test',
    'integration_test/tracer_bullet_test.dart',
    ...args,
  ], mode: ProcessStartMode.inheritStdio);

  return process.exitCode;
}

void _assertSpans(CollectorOutput output) {
  final slow = output.spanNamed(_slowSpanName);
  final fast = output.spanNamed(_fastSpanName);

  // The Agent is authoritative for identity, so both spans must carry it
  // (ADR-0002). Checking both catches a resource that is attached per-export
  // batch rather than per-process.
  for (final span in [slow, fast]) {
    _expect(
      span.resource['service.name'],
      _serviceName,
      '${span.name}: service.name',
    );
    _expect(
      span.resource['service.version'],
      _serviceVersion,
      '${span.name}: service.version',
    );

    // Both spellings, deliberately. The Agent sets one; APM Server 8.16+ reads
    // the other. Emitting only one leaves telemetry unattributed on one stack
    // or the other.
    _expect(
      span.resource['deployment.environment'],
      _environment,
      '${span.name}: deployment.environment',
    );
    _expect(
      span.resource['deployment.environment.name'],
      _environment,
      '${span.name}: deployment.environment.name',
    );

    _expect(span.scopeName, _scopeName, '${span.name}: instrumentation scope');
    _expect(span.parentSpanId, null, '${span.name}: is a root span');
  }

  // Dart owns the timestamps (ADR-0005). The slow span's duration must reflect
  // the wait the device performed, not when the native side happened to receive
  // the channel message.
  final slowMs = slow.duration.inMilliseconds;
  if (slowMs < _slowSpanWait.inMilliseconds) {
    _failures.add(
      '$_slowSpanName: duration ${slowMs}ms is shorter than the '
      '${_slowSpanWait.inMilliseconds}ms the device waited, so the timestamps '
      'did not survive the channel',
    );
  }
  if (slowMs > _slowSpanWait.inMilliseconds * 4) {
    _failures.add(
      '$_slowSpanName: duration ${slowMs}ms is far longer than the '
      '${_slowSpanWait.inMilliseconds}ms wait, suggesting native clock '
      'substitution or channel latency leaking into the span',
    );
  }

  // The fast span did no work. If channel latency were being timed instead of
  // the Dart operation, this is where it would show up.
  final fastMs = fast.duration.inMilliseconds;
  if (fastMs > 50) {
    _failures.add(
      '$_fastSpanName: duration ${fastMs}ms for a span that did no work — '
      'channel latency is being measured instead of the operation',
    );
  }

  // Distinct spans, one trace each, with real Agent-minted ids (ADR-0002: Dart
  // never mints trace ids).
  _expectNotEmpty(slow.traceId, '$_slowSpanName: trace id');
  _expectNotEmpty(slow.spanId, '$_slowSpanName: span id');
  if (slow.spanId == fast.spanId) {
    _failures.add('both spans share span id ${slow.spanId}');
  }

  stdout.writeln(
    '    $_slowSpanName  ${slowMs}ms  trace=${slow.traceId}\n'
    '    $_fastSpanName  ${fastMs}ms  trace=${fast.traceId}\n'
    '    service=${slow.resource['service.name']}@'
    '${slow.resource['service.version']} env=${slow.resource['deployment.environment']}',
  );
}

void _expect(Object? actual, Object? expected, String what) {
  if (actual != expected) {
    _failures.add('$what: expected $expected, got $actual');
  }
}

void _expectNotEmpty(String? actual, String what) {
  if (actual == null || actual.isEmpty) {
    _failures.add('$what: expected a value, got ${actual ?? 'null'}');
  }
}
