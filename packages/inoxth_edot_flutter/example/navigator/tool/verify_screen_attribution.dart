// Seam 2, host half — asserts that screen attributes survive to the collector.
//
//   dart run tool/verify_screen_attribution.dart -d <device>
//
// Runs on both platforms. The log-record half is asserted on Android only, because
// flush() cannot drain log records on iOS (ADR-0011); the device half stamps its
// platform on the first span so this side knows which it got.
//
// Exits non-zero with a report listing every failed assertion.
import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';

import '../integration_test/screen_attribution_contract.dart';

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
    var output = await collector.waitFor(
      (o) => _spanNames.every((name) => o.spansNamed(name).isNotEmpty),
    );

    // Which platform ran is only knowable once the spans are in, and the log
    // record trails them. Waiting for the spans alone would let this read before
    // the log arrived and report it missing when it was merely late.
    final platform = output
        .spanNamed(spanOnFirstScreen)
        .attributes[platformAttribute];
    if (platform == 'android') {
      output = await collector.waitFor(
        (o) => o.logsWithBody(logOnFirstScreen).isNotEmpty,
      );
    }

    _report(output);
    _assertSpans(output);
    _assertLogRecord(output, platform);
  } finally {
    await collector.stop();
  }

  if (_failures.isEmpty) {
    stdout.writeln('\nScreen attributes survived export.');
    return;
  }

  stderr.writeln('\nScreen attribution failed:');
  for (final failure in _failures) {
    stderr.writeln('  - $failure');
  }
  exit(1);
}

const _spanNames = <String>[
  spanOnFirstScreen,
  spanOnSecondScreen,
  spanWithNoScreen,
];

Future<int> _runDeviceHalf(List<String> args) async {
  final process = await Process.start('flutter', [
    'test',
    'integration_test/screen_attribution_test.dart',
    ...args,
  ], mode: ProcessStartMode.inheritStdio);

  return process.exitCode;
}

void _report(CollectorOutput output) {
  for (final name in _spanNames) {
    final span = output.spanNamed(name);
    stdout.writeln(
      '    $name  $screenNameAttribute=${span.attributes[screenNameAttribute]}  '
      '$screenIdAttribute=${span.attributes[screenIdAttribute]}',
    );
  }
  for (final record in output.logsWithBody(logOnFirstScreen)) {
    stdout.writeln('    log  ${record.attributes}');
  }
}

void _assertSpans(CollectorOutput output) {
  final first = output.spanNamed(spanOnFirstScreen);
  final second = output.spanNamed(spanOnSecondScreen);

  _expect(
    first.attributes[screenNameAttribute],
    firstScreenName,
    'first span screen name',
  );
  _expect(
    second.attributes[screenNameAttribute],
    secondScreenName,
    'second span screen name',
  );

  final firstId = first.attributes[screenIdAttribute];
  final secondId = second.attributes[screenIdAttribute];

  if (firstId is! String || firstId.isEmpty) {
    _failures.add(
      'first span carries $screenIdAttribute=$firstId, expected a non-empty '
      'string',
    );
  }
  // Two entries, so two identifiers. One shared identifier would make the
  // telemetry of every entry to every screen indistinguishable, which is the
  // whole reason the identifier exists alongside the name.
  if (firstId != null && firstId == secondId) {
    _failures.add(
      'both spans carry $screenIdAttribute=$firstId, so the identifier did not '
      'change between entries',
    );
  }

  // Cleared view: neither attribute, rather than a stale screen or a placeholder.
  final none = output.spanNamed(spanWithNoScreen);
  for (final key in [screenNameAttribute, screenIdAttribute]) {
    if (none.attributes.containsKey(key)) {
      _failures.add(
        '$spanWithNoScreen carries $key=${none.attributes[key]} after the Active '
        'View was cleared, expected the attribute to be absent',
      );
    }
  }
}

void _assertLogRecord(CollectorOutput output, Object? platform) {
  if (platform != 'android') {
    stdout.writeln(
      '    (skipping the log record: flush cannot drain logs on $platform, '
      'ADR-0011)',
    );
    return;
  }

  final records = output.logsWithBody(logOnFirstScreen);
  if (records.length != 1) {
    _failures.add(
      'expected exactly one log record bodied "$logOnFirstScreen", '
      'found ${records.length}',
    );
    return;
  }

  final record = records.single;
  _expect(
    record.attributes[screenNameAttribute],
    firstScreenName,
    'log screen name',
  );

  // The strongest assertion here: a span and a log emitted during one entry must
  // carry the same identifier. Two different values would mean the two paths read
  // separate state, and no dashboard could group an entry's telemetry together.
  _expect(
    record.attributes[screenIdAttribute],
    output.spanNamed(spanOnFirstScreen).attributes[screenIdAttribute],
    'log and span agree on the entry identifier',
  );
}

void _expect(Object? actual, Object? expected, String what) {
  if (actual != expected) {
    _failures.add('$what: got $actual, expected $expected');
  }
}
