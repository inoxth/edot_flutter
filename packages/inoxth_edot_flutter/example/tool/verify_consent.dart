// Seam 2, host half — asserts that Tracking Consent decides what reaches the collector,
// and that telemetry held before the Agent started keeps the time it happened.
//
//   dart run tool/verify_consent.dart -d <android-device>
//
// Android only: two of the three records are log records, which flush() does not drain on
// iOS (ADR-0011). The device half fails loudly rather than quietly passing there.
//
// Not a re-run of the Seam 1 gate, which is asserted exhaustively at the channel. This is
// here for the one thing that tier cannot reach: the outcome at the collector — that refused
// telemetry is absent from it and held telemetry arrives in it.
//
// Where a held record lands on the timeline is reported rather than asserted; see
// _reportHeldRecordTiming for why no platform can assert it.
//
// Exits non-zero with a report listing every failed assertion.
import 'dart:async';
import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';

import '../integration_test/consent_contract.dart';

final _failures = <String>[];

Future<void> main(List<String> args) async {
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
    final device = await Process.start('flutter', [
      'test',
      'integration_test/consent_test.dart',
      ...args,
    ], mode: ProcessStartMode.inheritStdio);

    final code = await device.exitCode;
    if (code != 0) {
      stderr.writeln(
        'The device half failed; not asserting on partial output.',
      );
      exit(code);
    }

    stdout.writeln('==> reading exported telemetry');
    final output = await _waitOrRead(collector);

    _report(output);

    _assertPermittedTelemetryArrives(output);
    _assertWithheldTelemetryNeverArrives(output);
    _assertHeldTelemetryIsReplayed(output);
    _reportHeldRecordTiming(output);
  } finally {
    await collector.stop();
  }

  if (_failures.isEmpty) {
    stdout.writeln(
      '\nConsent decided what was exported, and telemetry held before start arrived.',
    );
    return;
  }

  stderr.writeln('\nTracking Consent failed:');
  for (final failure in _failures) {
    stderr.writeln('  - $failure');
  }
  exit(1);
}

/// Waits for the two records that must arrive, then reads whatever is there.
///
/// A timeout is answered by reading and letting the assertions report what is missing,
/// which is far more useful than a bare TimeoutException.
Future<CollectorOutput> _waitOrRead(CollectorProcess collector) async {
  try {
    return await collector.waitFor(
      (o) =>
          _recordWith(o, heldRecordBody) != null &&
          _recordWith(o, permittedRecordBody) != null,
    );
  } on TimeoutException {
    return collector.read();
  }
}

ExportedLogRecord? _recordWith(CollectorOutput output, String body) => output
    .logs
    .where((l) => l.resource['service.name'] == serviceName && l.body == body)
    .firstOrNull;

void _report(CollectorOutput output) {
  final records = output.logs.where(
    (l) => l.resource['service.name'] == serviceName,
  );

  stdout.writeln('    ${records.length} record(s) under $serviceName:');
  for (final record in records) {
    stdout.writeln('      ${record.severityText}: ${record.body}');
  }

  // Spans and metrics too, though this suite emits none of either. Anything here came from
  // the Agent's own instrumentation, which does not pass through the channel and so is not
  // covered by the Tracking Consent gate (ADR-0015). Printed so that limitation is visible
  // in a run rather than only in prose.
  final spans = output.spans
      .where((s) => s.resource['service.name'] == serviceName)
      .map((s) => s.name)
      .toSet();
  final metrics = output.metrics
      .where((m) => m.resource['service.name'] == serviceName)
      .map((m) => m.name)
      .toSet();

  stdout.writeln(
    '    the Agent also emitted, of its own accord: '
    '${spans.length} span kind(s) ${spans.toList()}, '
    '${metrics.length} metric(s) ${metrics.toList()}',
  );
}

/// The control: consent granted means telemetry arrives.
///
/// Without it, a run in which nothing was exported at all — a broken endpoint, a device
/// half that never got going — would satisfy the absence asserted below.
void _assertPermittedTelemetryArrives(CollectorOutput output) {
  if (_recordWith(output, permittedRecordBody) == null) {
    _failures.add(
      'the record produced after consent was restored never arrived, so nothing here '
      'shows the pipeline was working and no absence below means anything',
    );
  }
}

/// AC: with consent not granted, nothing is emitted.
void _assertWithheldTelemetryNeverArrives(CollectorOutput output) {
  if (_recordWith(output, withheldRecordBody) != null) {
    _failures.add(
      'a record produced while consent was withdrawn reached the collector, which is '
      'the one thing Tracking Consent exists to prevent',
    );
  }
}

/// AC: telemetry produced before initialisation completes is replayed.
void _assertHeldTelemetryIsReplayed(CollectorOutput output) {
  if (_recordWith(output, heldRecordBody) == null) {
    _failures.add(
      'the record produced before Edot.start never arrived, so the queue dropped it '
      'rather than replaying it — which is how an early-startup error goes missing',
    );
  }
}

/// Reports where a held record ended up on the timeline, drawing no conclusion from it.
///
/// **The Plugin sends each record's own timestamp; on Android the Agent overrides it.** It
/// tags every record with a monotonic elapsed time at creation and, at export, replaces the
/// timestamp with that elapsed time plus its own NTP offset (`ClockExporterGateManager`). For
/// a record the queue replayed, "creation" is the replay.
///
/// Deliberately reported and not judged, because this harness cannot tell the two
/// explanations apart. Measured across two runs on the same emulator, the gap between these
/// records came out as 6 **nanoseconds** and then as nearly nine **hours** — the first being
/// both records dated at replay, the second an NTP offset standing between two records dated
/// by different clocks. Neither is the three seconds that actually separated them, and a rule
/// of "gap ≥ the delay means honoured" would have called the second one a pass.
///
/// So the number is printed for a human to read, and the property is left unasserted. It
/// cannot be asserted anywhere in this harness: Android overrides the value, and iOS — where
/// the Agent has no such rewrite — cannot run this suite at all, since `flush` does not drain
/// log records there (ADR-0011). Recorded in ADR-0005; do not build an alert on the absolute
/// timestamp of an Android record.
void _reportHeldRecordTiming(CollectorOutput output) {
  final held = _recordWith(output, heldRecordBody);
  final permitted = _recordWith(output, permittedRecordBody);
  if (held == null || permitted == null) return;

  final gap = Duration(
    microseconds: (permitted.timeNanos - held.timeNanos) ~/ 1000,
  );

  stdout.writeln(
    '    note: the held record is dated $gap before the one produced after start; '
    '$heldRecordDelay actually separated them. Not asserted — this harness cannot tell '
    "the Agent honouring the Plugin's timestamp from a clock offset between the two "
    'records (ADR-0005). Exported nanos: ${held.timeNanos} and ${permitted.timeNanos}.',
  );
}
