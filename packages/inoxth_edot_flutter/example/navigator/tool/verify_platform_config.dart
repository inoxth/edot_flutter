// Seam 2, host half — asserts that configuration reaches the Agent and changes what is
// exported.
//
//   dart run tool/verify_platform_config.dart -d <device>
//
// Runs the device half once per configuration, because `Edot.start` may be called only once
// per process. Each run reports under its own service name, so one collector holds all four
// and an absent export is unambiguous.
//
// Coverage is deliberately uneven, because the options are. `disableAgent` is asserted on both
// platforms; session sampling only on Android and the iOS instrumentation toggles only on iOS,
// each printing a note on the platform where it does not hold. Disk buffering is asserted at
// neither — see the contract for why this harness cannot create an offline period.
//
// Exits non-zero with a report listing every failed assertion.
import 'dart:async';
import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';

import '../integration_test/platform_config_contract.dart';

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
    for (final configCase in ConfigCase.values) {
      stdout.writeln('==> running the device half: ${configCase.define}');
      final device = await _runDeviceHalf(configCase, args);
      if (device != 0) {
        stderr.writeln(
          'The device half failed for ${configCase.define}; not asserting on '
          'partial output.',
        );
        exit(device);
      }
    }

    stdout.writeln('==> reading exported telemetry');
    // Waiting on the cases that must produce something, and only as an optimisation: the
    // two that must produce nothing cannot be waited for, since waiting for an absence only
    // ever times out. A timeout here is therefore not the failure — it is answered by
    // reading whatever did arrive and letting the assertions below say what is missing,
    // which is a far more useful report than a bare TimeoutException.
    final output = await _waitOrRead(collector);

    _report(output);

    // Read from the baseline case, which is the one that always exports. The two silent
    // cases have no telemetry to carry it, and two of the assertions below hold on only
    // one platform each — session sampling on Android, the instrumentation toggles on iOS.
    // Both say so on the platform where they do not, rather than passing quietly.
    final platform = _probeOf(
      output,
      ConfigCase.normal,
    )?.attributes[platformAttribute];

    _assertTheAgentCanBeDisabled(output);
    _assertSamplingOut(output, platform);
    _assertInstrumentationTogglesDoNotStopTheApp(output, platform);
    _assertTheSessionIdentifier(output);
  } finally {
    await collector.stop();
  }

  if (_failures.isEmpty) {
    // Not "every configuration" — two of them are only assertable on one platform, and both
    // printed a note above saying so. Claiming the full set here would overstate a green run.
    stdout.writeln(
      '\nEvery configuration asserted on this platform changed the export as '
      'expected. Read the notes above for the ones it cannot assert.',
    );
    return;
  }

  stderr.writeln('\nPlatform configuration failed:');
  for (final failure in _failures) {
    stderr.writeln('  - $failure');
  }
  exit(1);
}

/// Waits for the two cases that must export, then reads whatever is there.
Future<CollectorOutput> _waitOrRead(CollectorProcess collector) async {
  try {
    return await collector.waitFor(
      (o) =>
          _probeOf(o, ConfigCase.normal) != null &&
          _probeOf(o, ConfigCase.instrumentationOff) != null,
    );
  } on TimeoutException {
    return collector.read();
  }
}

Future<int> _runDeviceHalf(ConfigCase configCase, List<String> args) async {
  final process = await Process.start('flutter', [
    'test',
    'integration_test/platform_config_test.dart',
    '--dart-define=$caseVariable=${configCase.define}',
    ...args,
  ], mode: ProcessStartMode.inheritStdio);

  return process.exitCode;
}

/// Everything exported under one case's service name, whatever its shape.
///
/// Spans, log records and metrics together: "nothing arrived" has to mean nothing, and
/// checking only spans would pass while the Agent was still exporting its own metrics.
List<String> _everythingFrom(CollectorOutput output, ConfigCase configCase) => [
  for (final span in output.spans)
    if (span.resource['service.name'] == configCase.serviceName)
      'span ${span.name}',
  for (final log in output.logs)
    if (log.resource['service.name'] == configCase.serviceName)
      'log ${log.body}',
  for (final metric in output.metrics)
    if (metric.resource['service.name'] == configCase.serviceName)
      'metric ${metric.name}',
];

ExportedSpan? _probeOf(CollectorOutput output, ConfigCase configCase) => output
    .spansNamed(probeSpanName)
    .where((s) => s.resource['service.name'] == configCase.serviceName)
    .firstOrNull;

void _report(CollectorOutput output) {
  for (final configCase in ConfigCase.values) {
    final everything = _everythingFrom(output, configCase);
    stdout.writeln(
      '    ${configCase.define.padRight(19)} ${everything.length} exported'
      '${everything.isEmpty ? '' : ': ${everything.take(4).join(', ')}'}',
    );
  }

  // Every service name that arrived, so telemetry landing under a name no case claims —
  // which is what a leftover install or a stale collector looks like — is visible rather
  // than counted as an absence.
  final names = {
    for (final span in output.spans) span.resource['service.name'],
    for (final log in output.logs) log.resource['service.name'],
    for (final metric in output.metrics) metric.resource['service.name'],
  };
  stdout.writeln('    service names present: ${names.toList()}');
}

/// AC: disabling the Agent stops all telemetry.
void _assertTheAgentCanBeDisabled(CollectorOutput output) {
  final everything = _everythingFrom(output, ConfigCase.disabled);
  if (everything.isNotEmpty) {
    _failures.add(
      'the disabled Agent exported ${everything.length} item(s): '
      '${everything.join(', ')}',
    );
  }
}

/// AC: Session sampling reduces the proportion of sessions reporting.
///
/// At a rate of zero, which is the only rate whose effect is deterministic — asserting that
/// a rate of 0.5 halves anything would need a fleet of sessions, not one run.
///
/// **Android only, because the pinned iOS Agent does not reliably apply the rate.** Its
/// `SessionSampler` starts out sampling everything and only consults the configured rate when
/// the session-refresh notification fires, which the session manager posts only for a session
/// that is new or has expired. So a rate reaches the sampler on a cold start and is ignored
/// for the lifetime of an already-live session. Nothing the Plugin can do about it: the
/// refresh is not public API, and the React Native SDK hands the same rate to the same Agent,
/// so working around it here would break Fleet Alignment rather than fix a fleet. Recorded in
/// ADR-0001 and in the doc comment on `sessionSamplingRate`.
void _assertSamplingOut(CollectorOutput output, Object? platform) {
  final everything = _everythingFrom(output, ConfigCase.sampledOut);

  if (platform != 'android') {
    // Said out loud rather than skipped quietly. A suite that reported nothing here would
    // read as coverage it does not have.
    stdout.writeln(
      '    note: session sampling is not asserted on $platform — the pinned Agent '
      'ignores the rate for an already-live session (ADR-0001). '
      '${everything.length} item(s) arrived.',
    );
    return;
  }

  if (everything.isNotEmpty) {
    _failures.add(
      'a session sampled out at 0.0 exported ${everything.length} item(s): '
      '${everything.join(', ')}',
    );
  }
}

/// The instrumentation toggles govern what the Agent collects on its own, not whether the
/// export pipeline works — so telemetry the app produces itself must still arrive.
///
/// **iOS only, because the toggles are iOS-only.** Android's Agent installs whatever
/// instrumentation is on the classpath and offers no runtime switches (ADR-0009), so its
/// native side never reads this configuration at all — which makes this case the same
/// configuration as the baseline there, and this assertion one that would pass on an Android
/// run with the entire feature deleted. It is reported on Android rather than asserted, for
/// the same reason the sampling note is.
///
/// What it proves where it does hold. It exercises the native path that applies all four
/// options, so a wrong builder call or a misspelled key fails here. It cannot show that each
/// toggle suppressed its own instrumentation: CPU and memory sampling, MetricKit reports and
/// crash handlers are either unobservable within one test run or exported on a timer that
/// `flush` cannot drive (ADR-0011).
void _assertInstrumentationTogglesDoNotStopTheApp(
  CollectorOutput output,
  Object? platform,
) {
  final probe = _probeOf(output, ConfigCase.instrumentationOff);

  if (platform != 'ios') {
    stdout.writeln(
      '    note: the instrumentation toggles are not asserted on $platform — they '
      'are iOS-only, so this case is the baseline configuration here (ADR-0009). '
      'The probe span ${probe == null ? 'did not arrive' : 'arrived'}.',
    );
    return;
  }

  if (probe == null) {
    _failures.add(
      'no telemetry arrived with every instrumentation option off; these govern '
      'what the Agent collects on its own, not whether export works',
    );
  }
}

/// AC: the Session identifier is readable on iOS, and empty on Android.
///
/// Read against the identifier the Agent stamped on the very span the app reported it on.
/// An accessor returning *a* well-formed identifier that is not *the* one on the telemetry
/// would look right on a support screen and find nothing in Kibana.
void _assertTheSessionIdentifier(CollectorOutput output) {
  final probe = _probeOf(output, ConfigCase.normal);
  if (probe == null) {
    _failures.add('the baseline case exported nothing to read a Session from');
    return;
  }

  final platform = probe.attributes[platformAttribute];
  final reported = probe.attributes[reportedSessionIdAttribute];
  final stamped = probe.attributes[sessionIdAttribute];

  if (stamped == null) {
    _failures.add(
      'the exported span carries no $sessionIdAttribute, so there is nothing to '
      'compare the accessor against',
    );
    return;
  }

  switch (platform) {
    case 'ios':
      if (reported != stamped) {
        _failures.add(
          'the Session identifier the app read was $reported, but the Agent '
          'stamped $stamped on the same span',
        );
      }
    case 'android':
      // ADR-0001: the Agent exposes its session manager only as internal, explicitly
      // unstable API, so there is nothing to read. Asserted rather than skipped — a value
      // appearing here would mean the Plugin invented one, and an invented identifier finds
      // nothing in Kibana while looking entirely plausible on a support screen.
      if (reported != noSessionId) {
        _failures.add(
          'the Session identifier reported $reported on Android, where the Agent '
          'has none to give',
        );
      }
    default:
      _failures.add('the probe span names no platform; got $platform');
  }
}
