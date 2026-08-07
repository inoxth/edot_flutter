// Seam 2, host half — asserts the Collector Host exclusion (ADR-0006).
//
// Drives the device half and then asserts on what reached the collector:
//
//   dart run tool/verify_collector_host_exclusion.dart -d <ios-simulator-id>
//
// iOS only. Exits non-zero with a report listing every failed assertion.
import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';

import '../integration_test/exclusion_contract.dart';

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
    // Waiting on the control span, not on the absence of feedback spans: you
    // cannot wait for something not to arrive, so the control span is what tells
    // us the export happened and the absence assertions are meaningful.
    final output = await collector.waitFor(
      (o) => o.spansNamed(controlSpanName).isNotEmpty,
    );

    _assertExclusion(output);
  } finally {
    await collector.stop();
  }

  if (_failures.isEmpty) {
    stdout.writeln('\nCollector Host exclusion holds.');
    return;
  }

  stderr.writeln('\nCollector Host exclusion failed:');
  for (final failure in _failures) {
    stderr.writeln('  - $failure');
  }
  exit(1);
}

Future<int> _runDeviceHalf(List<String> args) async {
  final process = await Process.start('flutter', [
    'test',
    'integration_test/collector_host_exclusion_test.dart',
    ...args,
  ], mode: ProcessStartMode.inheritStdio);

  return process.exitCode;
}

void _assertExclusion(CollectorOutput output) {
  final spans = output.spans;
  stdout.writeln('    ${spans.length} span(s) exported:');
  for (final span in spans) {
    stdout.writeln('      ${span.name}');
  }

  // Every span that mentions the Collector Host anywhere. This is deliberately
  // broader than checking span names: the Agent's own export spans, and its
  // central-configuration polling, would surface the host in an attribute such
  // as http.url even if the span name did not carry it.
  final referencingCollector = spans
      .where((span) => _referencesHost(span, collectorHost))
      .toList();

  if (referencingCollector.isNotEmpty) {
    for (final span in referencingCollector) {
      _failures.add(
        'span "${span.name}" references the Collector Host '
        '($collectorHost): ${_hostEvidence(span, collectorHost)}',
      );
    }
  }

  // The alias host resolves to the same machine but is a different host string,
  // so ADR-0006 leaves it traced. This is the assertion that stops the exclusion
  // from being implemented as "drop everything".
  final tracedAliasHost = spans.any((span) => _referencesHost(span, aliasHost));
  if (!tracedAliasHost) {
    _failures.add(
      'no span references $aliasHost — native traffic to other hosts must '
      'still be traced, otherwise the exclusion has become a blanket mute',
    );
  }

  for (final entry in probeRequests.entries) {
    final host = Uri.parse(entry.key).host;
    final traced = spans.any((span) => _referencesHost(span, host));
    if (entry.value && !traced) {
      _failures.add('${entry.key}: expected a span, found none');
    }
    // The excluded cases are already covered by the Collector Host sweep above;
    // re-asserting per URL here would report the same defect several times.
  }

  final tracedHosts = <String>{
    for (final span in spans)
      for (final host in [collectorHost, aliasHost])
        if (_referencesHost(span, host)) host,
  };
  stdout.writeln('    hosts appearing in spans: ${tracedHosts.join(', ')}');
}

/// Whether [span] mentions [host] in its name or in any attribute value.
bool _referencesHost(ExportedSpan span, String host) =>
    span.name.contains(host) ||
    span.attributes.values.any((value) => '$value'.contains(host));

String _hostEvidence(ExportedSpan span, String host) {
  if (span.name.contains(host)) return 'in the span name';

  final attribute = span.attributes.entries.firstWhere(
    (entry) => '${entry.value}'.contains(host),
  );
  return 'in ${attribute.key}=${attribute.value}';
}
