// Seam 2, host half — asserts that Screen Spans reach the collector.
//
//   dart run tool/verify_navigation.dart -d <device>
//
// Exits non-zero with a report listing every failed assertion.
import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';

import '../integration_test/navigation_contract.dart';

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
    // Three transitions: home, the order, and home again. Waiting on the count rather than
    // on presence, because the third arrives last and the second would otherwise be read
    // as the end of the journey.
    final output = await collector.waitFor(
      (o) =>
          o.spansNamed(screenSpanName(homeRoute)).length >= 2 &&
          o.spansNamed(screenSpanName(orderScreenName)).isNotEmpty &&
          o.spansNamed(spanOnTheOrderScreen).isNotEmpty,
    );

    _report(output);
    _assertTheJourney(output);
    _assertTheOrderScreenIsCollapsed(output);
    _assertSubsequentTelemetryIsAttributed(output);
  } finally {
    await collector.stop();
  }

  if (_failures.isEmpty) {
    stdout.writeln('\nScreen Spans survived export.');
    return;
  }

  stderr.writeln('\nNavigation tracing failed:');
  for (final failure in _failures) {
    stderr.writeln('  - $failure');
  }
  exit(1);
}

Future<int> _runDeviceHalf(List<String> args) async {
  final process = await Process.start('flutter', [
    'test',
    'integration_test/navigation_test.dart',
    ...args,
  ], mode: ProcessStartMode.inheritStdio);

  return process.exitCode;
}

/// Every exported Screen Span, in export order.
List<ExportedSpan> _screenSpans(CollectorOutput output) => [
  ...output.spansNamed(screenSpanName(homeRoute)),
  ...output.spansNamed(screenSpanName(orderScreenName)),
]..sort((a, b) => a.startNanos.compareTo(b.startNanos));

void _report(CollectorOutput output) {
  for (final span in _screenSpans(output)) {
    stdout.writeln(
      '    screen  ${span.name}  from=${span.attributes[lastScreenNameAttribute]}  '
      'id=${span.attributes[screenIdAttribute]}  ${span.duration}',
    );
  }
  for (final span in output.spansNamed(spanOnTheOrderScreen)) {
    stdout.writeln(
      '    work    ${span.name}  screen=${span.attributes[screenNameAttribute]}  '
      'id=${span.attributes[screenIdAttribute]}',
    );
  }
}

/// The journey, read off the export in the order it happened.
///
/// Asserted as a sequence rather than span by span, because what a dashboard answers with
/// these is "where did users come from" — and that question is only answerable if each
/// transition names the one before it.
void _assertTheJourney(CollectorOutput output) {
  final spans = _screenSpans(output);
  final journey = spans
      .map(
        (s) =>
            '${s.attributes[lastScreenNameAttribute] ?? '-'} → '
            '${s.attributes[screenNameAttribute]}',
      )
      .toList();

  const expected = [
    '- → $homeRoute',
    '$homeRoute → $orderScreenName',
    '$orderScreenName → $homeRoute',
  ];

  if (journey.join(' | ') != expected.join(' | ')) {
    _failures.add(
      'the exported journey is ${journey.join(' | ')}, expected '
      '${expected.join(' | ')}',
    );
  }

  // The first transition has nothing before it, and saying so with an absent attribute
  // rather than a placeholder is what keeps "came from nowhere" distinguishable from
  // "came from a screen whose name went missing".
  final first = spans.firstOrNull;
  if (first != null && first.attributes.containsKey(lastScreenNameAttribute)) {
    _failures.add(
      'the first transition carries $lastScreenNameAttribute='
      '${first.attributes[lastScreenNameAttribute]}; nothing preceded it',
    );
  }

  for (final span in spans) {
    _expect(
      span.resource['service.name'],
      'edot-flutter-seam2',
      '${span.name} resource identity',
    );
  }
}

/// The reason a Screen Name is safe to attach to every span in the system.
void _assertTheOrderScreenIsCollapsed(CollectorOutput output) {
  if (output.spansNamed(screenSpanName(orderRoute)).isNotEmpty) {
    _failures.add(
      'a Screen Span arrived named for $orderRoute rather than $orderScreenName, so the '
      'order id is now in a span name and in every span attribute on that screen',
    );
  }

  final orders = output.spansNamed(screenSpanName(orderScreenName));
  for (final span in orders) {
    _expect(
      span.attributes[screenNameAttribute],
      orderScreenName,
      'the order screen name',
    );
  }
}

/// AC: navigating sets the Active View, so what follows is attributed to the new screen.
///
/// The identifier is the load-bearing part. Both sides minting their own would still look
/// right in isolation, and a dashboard joining a screen's telemetry to the transition that
/// opened it would silently return nothing.
void _assertSubsequentTelemetryIsAttributed(CollectorOutput output) {
  final work = output.spansNamed(spanOnTheOrderScreen).firstOrNull;
  final transition = output
      .spansNamed(screenSpanName(orderScreenName))
      .firstOrNull;

  if (work == null || transition == null) {
    _failures.add('the order screen span or the work on it never arrived');
    return;
  }

  _expect(
    work.attributes[screenNameAttribute],
    orderScreenName,
    'the screen the later span was attributed to',
  );
  _expect(
    work.attributes[screenIdAttribute],
    transition.attributes[screenIdAttribute],
    'the entry identifier shared by a screen and the transition that opened it',
  );
}

void _expect(Object? actual, Object? expected, String what) {
  if (actual != expected) {
    _failures.add('$what: got $actual, expected $expected');
  }
}
