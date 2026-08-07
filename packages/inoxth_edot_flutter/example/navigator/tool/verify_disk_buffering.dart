// Seam 2, host half — asserts that telemetry produced with no collector to reach arrives once
// there is one.
//
//   dart run tool/verify_disk_buffering.dart -d <android-device>
//
// Android only. On iOS delivery from the buffer is driven by the Agent's own persistence
// worker, whose delay grows on every failure to a 20-second ceiling and which flush() cannot
// drive (ADR-0011); runs there measured the same case delivering everything and then nothing.
// The device half fails loudly rather than quietly passing.
//
// The only suite that takes the collector away mid-run, because that is the condition disk
// buffering exists for. Per case:
//
//   1. stop the collector                    — now genuinely unreachable
//   2. launch the app, which emits a probe    — buffered to disk, or lost
//   3. wait for the app's signal              — it has finished emitting offline
//   4. bring the collector back, keeping what has already arrived
//   5. let the app run on                     — the Agent's drain job now has a destination
//
// Step 3 is a signal rather than a timer because the build, install and launch ahead of it take
// an unpredictable amount of time, and reconnecting too early would mean the telemetry was
// never really offline. The suite also asserts that nothing arrived before step 4, so a
// mistimed run fails loudly instead of passing as something weaker.
//
// Exits non-zero with a report listing every failed assertion.
import 'dart:async';
import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';

import '../integration_test/disk_buffering_contract.dart';

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

  // Started before anything else so the output directory exists and holds no previous run's
  // telemetry. Each case stops it again immediately.
  stdout.writeln('==> starting collector');
  stdout.writeln('    output: ${collector.outputFile.path}');
  await collector.start();

  try {
    for (final bufferingCase in BufferingCase.values) {
      await _runCase(bufferingCase, collector, args);
    }

    final output = collector.read();
    _report(output);

    final platform = output
        .spansNamed(reachableMarkerSpanName)
        .firstOrNull
        ?.attributes[platformAttribute];

    _assertTheRunWasAndroid(platform);
    _assertTheCollectorWasReachableAgain(output);
    _assertBufferedTelemetryArrivesLate(output);
    _assertUnbufferedTelemetryIsLost(output);
    _reportDeliveryDuplication(output);
  } finally {
    await collector.stop();
  }

  if (_failures.isEmpty) {
    stdout.writeln(
      '\nTelemetry buffered with no collector to reach arrived once there was one.',
    );
    return;
  }

  stderr.writeln('\nDisk buffering failed:');
  for (final failure in _failures) {
    stderr.writeln('  - $failure');
  }
  exit(1);
}

/// One case: collector away, app emits, collector back, app delivers.
Future<void> _runCase(
  BufferingCase bufferingCase,
  CollectorProcess collector,
  List<String> args,
) async {
  stdout.writeln('==> ${bufferingCase.define}: taking the collector away');
  await collector.stop();

  // Bound before the app launches, so a signal cannot arrive before there is anything to
  // receive it.
  final server = await HttpServer.bind(InternetAddress.anyIPv4, signalPort);
  final signal = _firstSignal(server);

  stdout.writeln('==> ${bufferingCase.define}: launching the app');
  final device = _runDeviceHalf(bufferingCase, args);

  // Whichever comes first. A device half that dies before signalling — a build failure, a
  // crash — would otherwise leave this waiting on a signal that is never coming.
  final signalled = await Future.any<bool>([
    signal.then<bool>((_) => true),
    device.then<bool>((_) => false),
  ]);

  if (!signalled) {
    stderr.writeln(
      'The device half exited before signalling for ${bufferingCase.define}; '
      'not asserting on partial output.',
    );
    exit(await device);
  }

  // The assertion that gives the rest of the suite its meaning: everything below is about
  // telemetry that could not be delivered when it was produced, and this is what establishes
  // that it could not.
  _assertNothingArrivedWhileOffline(collector.read(), bufferingCase);

  stdout.writeln('==> ${bufferingCase.define}: bringing the collector back');
  await collector.resume();

  final code = await device;
  if (code != 0) {
    stderr.writeln(
      'The device half failed for ${bufferingCase.define}; not asserting on '
      'partial output.',
    );
    exit(code);
  }

  // Let the collector get what it has just received onto disk, before the next case stops it
  // or `main` reads it. See [collectorFlushSettle].
  await Future<void>.delayed(collectorFlushSettle);
}

/// Completes when the device says it has produced its telemetry offline.
///
/// Closes [server] afterwards, because the next case binds the same port.
Future<void> _firstSignal(HttpServer server) async {
  final request = await server.first;

  await request.drain<void>();
  request.response.statusCode = HttpStatus.noContent;
  await request.response.close();

  await server.close();
}

Future<int> _runDeviceHalf(
  BufferingCase bufferingCase,
  List<String> args,
) async {
  final process = await Process.start('flutter', [
    'test',
    'integration_test/disk_buffering_test.dart',
    '--dart-define=$caseVariable=${bufferingCase.define}',
    ...args,
  ], mode: ProcessStartMode.inheritStdio);

  return process.exitCode;
}

ExportedSpan? _spanFrom(
  CollectorOutput output,
  BufferingCase bufferingCase,
  String name,
) => output
    .spansNamed(name)
    .where((s) => s.resource['service.name'] == bufferingCase.serviceName)
    .firstOrNull;

void _report(CollectorOutput output) {
  for (final bufferingCase in BufferingCase.values) {
    final spans = [
      for (final span in output.spans)
        if (span.resource['service.name'] == bufferingCase.serviceName)
          span.name,
    ];
    stdout.writeln(
      '    ${bufferingCase.define.padRight(11)} ${spans.length} span(s)'
      '${spans.isEmpty ? '' : ': ${spans.join(', ')}'}',
    );
  }
}

/// Says out loud when the buffer delivered the same span more than once.
///
/// Not a failure. A durable buffer that re-delivers a batch it is unsure reached the collector
/// is behaving reasonably, and the Plugin has no say in it — but it means buffered delivery is
/// at-least-once, and anything counting spans will over-count after an outage. Identity is read
/// from the span id, so this is re-delivery of one span rather than two spans that happen to
/// share a name.
void _reportDeliveryDuplication(CollectorOutput output) {
  for (final bufferingCase in BufferingCase.values) {
    final ids = [
      for (final span in output.spansNamed(probeSpanName))
        if (span.resource['service.name'] == bufferingCase.serviceName)
          span.spanId,
    ];

    if (ids.length > ids.toSet().length) {
      stdout.writeln(
        '    note: ${bufferingCase.define} delivered ${ids.length} copies of '
        '${ids.toSet().length} span(s) — buffered delivery is at-least-once, so a '
        'dashboard counting spans will over-count after an outage.',
      );
    }
  }
}

/// The offline period has to have been real.
///
/// Checked per case, while the collector is still down. Without it the suite would pass against
/// a collector that never went away — the probe would arrive live, and "buffered telemetry
/// arrived" would mean no more than "telemetry arrived".
void _assertNothingArrivedWhileOffline(
  CollectorOutput output,
  BufferingCase bufferingCase,
) {
  final arrived = [
    for (final span in output.spans)
      if (span.resource['service.name'] == bufferingCase.serviceName) span.name,
  ];

  if (arrived.isNotEmpty) {
    _failures.add(
      '${bufferingCase.define}: ${arrived.length} span(s) reached the collector while '
      'it was stopped, so nothing in this case was buffered: ${arrived.join(', ')}',
    );
  }
}

/// Distinguishes telemetry that was lost from telemetry that had nowhere to go.
void _assertTheCollectorWasReachableAgain(CollectorOutput output) {
  for (final bufferingCase in BufferingCase.values) {
    if (_spanFrom(output, bufferingCase, reachableMarkerSpanName) == null) {
      _failures.add(
        '${bufferingCase.define}: the marker emitted after the collector returned never '
        'arrived, so the collector was not reachable by then and nothing else in this '
        'case can be read as buffering behaviour',
      );
    }
  }
}

/// AC: telemetry produced offline arrives after reconnection.
void _assertBufferedTelemetryArrivesLate(CollectorOutput output) {
  if (_spanFrom(output, BufferingCase.buffered, probeSpanName) == null) {
    _failures.add(
      'the span buffered while the collector was unreachable never arrived, within '
      '$drainWindow of the collector returning',
    );
  }
}

/// AC: with buffering off, the same telemetry is confirmed lost rather than buffered.
///
/// This is what stops the positive case being vacuous. If a probe survives with buffering off,
/// either the Agent ignored the setting or the export was never really offline — and under
/// either, the arrival asserted above proves nothing about the buffer.
void _assertUnbufferedTelemetryIsLost(CollectorOutput output) {
  if (_spanFrom(output, BufferingCase.unbuffered, probeSpanName) != null) {
    _failures.add(
      'a span emitted with disk buffering off, while the collector was unreachable, '
      'arrived anyway — so it was buffered despite the setting, or the collector was '
      'reachable when it should not have been',
    );
  }
}

/// The run really was Android, where alone this suite means anything.
///
/// The device half refuses to run elsewhere, so this cannot normally fail — it is here because
/// every other assertion is read as Android behaviour, and a suite whose subject is "which
/// platform am I proving something about" should not infer that from the absence of a failure.
void _assertTheRunWasAndroid(Object? platform) {
  if (platform != 'android') {
    _failures.add(
      'the telemetry reports platform "$platform"; every assertion here describes the '
      'Android Agent and none of them transfers',
    );
  }
}
