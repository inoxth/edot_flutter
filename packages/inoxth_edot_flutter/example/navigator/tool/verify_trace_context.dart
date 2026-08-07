// Seam 2, host half — asserts the Trace Context a traced request carries.
//
//   dart run tool/verify_trace_context.dart -d <device>
//
// Exits non-zero with a report listing every failed assertion.
import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';

import '../integration_test/trace_context_contract.dart';

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
    // Waits on arrival counts, not on header contents: keying the predicate on the
    // traceparent would turn a propagation regression into "the predicate timed out"
    // rather than the assertion that explains it.
    final output = await collector.waitFor(
      (o) =>
          o.spansNamed(downstreamSpanName).length >= 3 &&
          o.spans.where((s) => s.attributes.containsKey(urlAttribute)).length >=
              2,
    );

    _report(output);
    _assertPropagated(output);
    _assertNotPropagatedToOthers(output);
    _assertUntracedRequestsCarryNothing(output);
    _assertNoLegacyHeader(output);
    _assertCollectorHostProducedNoSpan(output);
  } finally {
    await collector.stop();
  }

  if (_failures.isEmpty) {
    stdout.writeln('\nTrace Context reached the service.');
    return;
  }

  stderr.writeln('\nTrace Context propagation failed:');
  for (final failure in _failures) {
    stderr.writeln('  - $failure');
  }
  exit(1);
}

Future<int> _runDeviceHalf(List<String> args) async {
  final process = await Process.start('flutter', [
    'test',
    'integration_test/trace_context_test.dart',
    ...args,
  ], mode: ProcessStartMode.inheritStdio);

  return process.exitCode;
}

/// The client span for [path], found by its `http.target`.
///
/// Every request here goes to one host, so the span names are all `GET 127.0.0.1`
/// and looking up by name could only pick one arbitrarily.
ExportedSpan? _clientSpanFor(CollectorOutput output, String path) {
  final matches = output.spans
      .where((s) => s.attributes[targetAttribute] == path)
      .toList();

  return matches.isEmpty ? null : matches.last;
}

/// What the service recorded for the request to [path].
ExportedSpan? _serviceSpanFor(CollectorOutput output, String path) {
  final matches = output
      .spansNamed(downstreamSpanName)
      .where((s) => s.attributes[requestedPathAttribute] == path)
      .toList();

  return matches.isEmpty ? null : matches.last;
}

String? _receivedTraceparent(CollectorOutput output, String path) {
  final span = _serviceSpanFor(output, path);
  if (span == null) {
    _failures.add('the service recorded no span for $path');
    return null;
  }

  final value = span.attributes[receivedTraceparentAttribute];
  if (value is! String) {
    _failures.add(
      'the service span for $path carries $receivedTraceparentAttribute='
      '$value, expected a string',
    );
    return null;
  }

  return value;
}

void _report(CollectorOutput output) {
  for (final span in output.spansNamed(downstreamSpanName)) {
    stdout.writeln(
      '    service saw ${span.attributes[requestedPathAttribute]}  '
      'traceparent=${span.attributes[receivedTraceparentAttribute]}',
    );
  }
  for (final span in output.spans.where(
    (s) => s.attributes.containsKey(urlAttribute),
  )) {
    stdout.writeln(
      '    client span ${span.attributes[targetAttribute]}  '
      'trace=${span.traceId}  span=${span.spanId}',
    );
  }
}

/// The headline: the header the service received names the exported client span.
///
/// Both halves of it matter. The trace id is what puts the service's work in this
/// app's trace; the span id is what makes the client span its parent rather than some
/// other span in the same trace.
void _assertPropagated(CollectorOutput output) {
  final client = _clientSpanFor(output, propagatedPath);
  if (client == null) {
    _failures.add('no client span carried $targetAttribute=$propagatedPath');
    return;
  }

  final traceparent = _receivedTraceparent(output, propagatedPath);
  if (traceparent == null) return;

  if (traceparent == absentHeader) {
    _failures.add(
      'the service received no traceparent for $propagatedPath, which the '
      'target list matches',
    );
    return;
  }

  // `00-<32 hex trace id>-<16 hex span id>-<2 hex flags>`. Parsed rather than
  // string-matched so a malformed header fails as malformed.
  final parts = traceparent.split('-');
  if (parts.length != 4 ||
      parts[0] != '00' ||
      parts[1].length != 32 ||
      parts[2].length != 16 ||
      parts[3].length != 2) {
    _failures.add('traceparent "$traceparent" is not a W3C version-00 header');
    return;
  }

  _expect(parts[1], client.traceId, 'the trace id the service received');
  _expect(parts[2], client.spanId, 'the span id the service received');

  // Sampled: the client span was exported, so a service told otherwise would drop
  // its own half of a trace that does exist.
  if (parts[3] != '01') {
    _failures.add(
      'traceparent flags are ${parts[3]}, expected 01 — the span was exported, '
      'so the service must be told the trace is sampled',
    );
  }
}

/// A traced request that is not a target reaches the service with no context, and
/// still produces its own span.
void _assertNotPropagatedToOthers(CollectorOutput output) {
  if (_clientSpanFor(output, plainPath) == null) {
    _failures.add(
      'no client span carried $targetAttribute=$plainPath — narrowing '
      'propagation must cost the link, not the span',
    );
  }

  final traceparent = _receivedTraceparent(output, plainPath);
  if (traceparent != null && traceparent != absentHeader) {
    _failures.add(
      'the service received traceparent "$traceparent" for $plainPath, which '
      'the target list does not match',
    );
  }
}

/// An untraced request has no span to name, so it carries nothing.
void _assertUntracedRequestsCarryNothing(CollectorOutput output) {
  final traceparent = _receivedTraceparent(output, excludedPath);
  if (traceparent != null && traceparent != absentHeader) {
    _failures.add(
      'the service received traceparent "$traceparent" for the excluded '
      '$excludedPath',
    );
  }
}

/// Elastic's own header is deprecated and must never be sent.
///
/// Asserted against the header names that actually arrived, so a second header
/// nobody thought to look for still fails this.
void _assertNoLegacyHeader(CollectorOutput output) {
  final seen = output.spansNamed(downstreamSpanName);
  if (seen.isEmpty) {
    _failures.add('the service recorded no spans at all');
    return;
  }

  for (final span in seen) {
    final path = span.attributes[requestedPathAttribute];
    final headers = span.attributes[receivedHeadersAttribute];

    if (headers is! String) {
      _failures.add(
        'the service span for $path carries $receivedHeadersAttribute='
        '$headers, expected a string',
      );
      continue;
    }

    final names = headers.split(',');
    if (names.contains(legacyHeaderName)) {
      _failures.add('$path received the deprecated $legacyHeaderName');
    }

    // The list is only evidence of absence if it is evidence of presence too: the
    // propagated request must show `traceparent` in the very same list.
    if (path == propagatedPath && !names.contains('traceparent')) {
      _failures.add(
        '$propagatedPath received headers $headers, with no traceparent among '
        'them',
      );
    }
  }
}

void _assertCollectorHostProducedNoSpan(CollectorOutput output) {
  final leaked = output.spans
      .where((s) => '${s.attributes[targetAttribute]}'.contains(collectorPath))
      .toList();

  if (leaked.isNotEmpty) {
    _failures.add(
      'the Collector Host produced ${leaked.length} span(s), so it also had '
      'context to propagate',
    );
  }
}

void _expect(Object? actual, Object? expected, String what) {
  if (actual != expected) {
    _failures.add('$what: got $actual, expected $expected');
  }
}
