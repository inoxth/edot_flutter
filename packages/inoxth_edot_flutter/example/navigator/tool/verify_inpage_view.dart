// Seam 2, host half — asserts that an in-page view span reaches the collector.
//
//   dart run tool/verify_inpage_view.dart -d <device>
//
// Exits non-zero with a report listing every failed assertion.
import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';

import '../integration_test/inpage_view_contract.dart';

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
    // Both view spans and the work span on the second tab. Waiting on all three so a
    // partial export is not read as the whole switch.
    final output = await collector.waitFor(
      (o) =>
          o.spansNamed(screenSpanName(firstView)).isNotEmpty &&
          o.spansNamed(screenSpanName(secondView)).isNotEmpty &&
          o.spansNamed(spanOnTheSecondView).isNotEmpty,
    );

    _report(output);
    _assertTheSwitch(output);
    _assertSubsequentTelemetryIsAttributed(output);
  } finally {
    await collector.stop();
  }

  if (_failures.isEmpty) {
    stdout.writeln('\nThe in-page view span survived export.');
    return;
  }

  stderr.writeln('\nIn-page view tracking failed:');
  for (final failure in _failures) {
    stderr.writeln('  - $failure');
  }
  exit(1);
}

Future<int> _runDeviceHalf(List<String> args) async {
  final process = await Process.start('flutter', [
    'test',
    'integration_test/inpage_view_test.dart',
    ...args,
  ], mode: ProcessStartMode.inheritStdio);

  return process.exitCode;
}

/// Both exported view spans, in the order they started.
List<ExportedSpan> _viewSpans(CollectorOutput output) => [
  ...output.spansNamed(screenSpanName(firstView)),
  ...output.spansNamed(screenSpanName(secondView)),
]..sort((a, b) => a.startNanos.compareTo(b.startNanos));

void _report(CollectorOutput output) {
  for (final span in _viewSpans(output)) {
    stdout.writeln(
      '    view  ${span.name}  from=${span.attributes[lastScreenNameAttribute]}  '
      'id=${span.attributes[screenIdAttribute]}  ${span.duration}',
    );
  }
  for (final span in output.spansNamed(spanOnTheSecondView)) {
    stdout.writeln(
      '    work  ${span.name}  screen=${span.attributes[screenNameAttribute]}  '
      'id=${span.attributes[screenIdAttribute]}',
    );
  }
}

/// The switch, read off the export: the initial tab appears with nothing before it, then
/// the second names the first as where the user came from.
void _assertTheSwitch(CollectorOutput output) {
  final first = output.spansNamed(screenSpanName(firstView)).firstOrNull;
  final second = output.spansNamed(screenSpanName(secondView)).firstOrNull;

  if (first == null || second == null) {
    _failures.add('one of the two view spans never arrived');
    return;
  }

  _expect(
    first.attributes[screenNameAttribute],
    firstView,
    'the initial tab name',
  );
  // The first tab has nothing before it, and saying so with an absent attribute rather
  // than a placeholder keeps "came from nowhere" distinguishable from "a name went
  // missing".
  if (first.attributes.containsKey(lastScreenNameAttribute)) {
    _failures.add(
      'the initial tab carries $lastScreenNameAttribute='
      '${first.attributes[lastScreenNameAttribute]}; nothing preceded it',
    );
  }

  _expect(
    second.attributes[screenNameAttribute],
    secondView,
    'the switched-to tab name',
  );
  _expect(
    second.attributes[lastScreenNameAttribute],
    firstView,
    'the tab the switch came from',
  );

  for (final span in [first, second]) {
    _expect(
      span.resource['service.name'],
      'edot-flutter-seam2',
      '${span.name} resource identity',
    );
  }
}

/// AC: an in-page switch sets the Active View, so what follows is attributed to the new tab.
///
/// The identifier is the load-bearing part: a dashboard joining a tab's telemetry to the
/// switch that opened it needs the same one on both.
void _assertSubsequentTelemetryIsAttributed(CollectorOutput output) {
  final work = output.spansNamed(spanOnTheSecondView).firstOrNull;
  final transition = output.spansNamed(screenSpanName(secondView)).firstOrNull;

  if (work == null || transition == null) {
    _failures.add('the second tab span or the work on it never arrived');
    return;
  }

  _expect(
    work.attributes[screenNameAttribute],
    secondView,
    'the tab the later span was attributed to',
  );
  _expect(
    work.attributes[screenIdAttribute],
    transition.attributes[screenIdAttribute],
    'the entry identifier shared by a tab and the switch that opened it',
  );
}

void _expect(Object? actual, Object? expected, String what) {
  if (actual != expected) {
    _failures.add('$what: got $actual, expected $expected');
  }
}
