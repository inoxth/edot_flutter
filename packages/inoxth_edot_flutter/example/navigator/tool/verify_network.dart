// Seam 2, host half — asserts the client spans a traced request produces, through
// `EdotHttpClient` and through the Dio interceptor.
//
//   dart run tool/verify_network.dart -d <device>
//
// Exits non-zero with a report listing every failed assertion.
import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';

import '../integration_test/network_contract.dart';

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
    // Waits on how many request spans arrived, not on what they contain. Keying
    // this on a sanitised value would turn any sanitiser regression into "the
    // predicate timed out" instead of the assertion that actually explains it.
    final output = await collector.waitFor(
      (o) =>
          o.spansNamed(controlSpanName).isNotEmpty &&
          o.spans.where((s) => s.attributes.containsKey(urlAttribute)).length >=
              6 &&
          // Counted separately: the Dio spans arrive last, and a total that both
          // integrations contribute to is satisfied by six http spans alone.
          o.spans
                  .where((s) => s.attributes[clientAttribute] == dioClientName)
                  .length >=
              2,
    );

    _report(output);
    _assertTracedRequest(output);
    _assertDioRequest(output);
    _assertDioRejectedStatus(output);
    _assertServerFailure(output);
    _assertTransportFailure(output);
    _assertExclusions(output);
    _assertNothingLeaked(output);
    _assertSyntheticParent(output);
    _assertAmbientParentAvoidsIt(output);
  } finally {
    await collector.stop();
  }

  if (_failures.isEmpty) {
    stdout.writeln('\nNetwork spans survived export.');
    return;
  }

  stderr.writeln('\nNetwork tracing failed:');
  for (final failure in _failures) {
    stderr.writeln('  - $failure');
  }
  exit(1);
}

/// Finds a span by its `http.target`.
///
/// Not by name: every request here goes to one host, so the span names are all
/// `GET 127.0.0.1` and looking up by name could only pick one arbitrarily.
ExportedSpan? _spanFor(CollectorOutput output, String target) {
  final matches = output.spans
      .where((s) => s.attributes[targetAttribute] == target)
      .toList();

  return matches.isEmpty ? null : matches.last;
}

Future<int> _runDeviceHalf(List<String> args) async {
  final process = await Process.start('flutter', [
    'test',
    'integration_test/network_test.dart',
    ...args,
  ], mode: ProcessStartMode.inheritStdio);

  return process.exitCode;
}

void _report(CollectorOutput output) {
  for (final span in output.spans) {
    stdout.writeln(
      '    ${span.name}  kind=${span.kind.name}  '
      'client=${span.attributes[clientAttribute]}  '
      'target=${span.attributes[targetAttribute]}  '
      'status=${span.attributes[statusAttribute]}  error=${span.isError}  '
      'parent=${span.parentSpanId ?? 'root'}',
    );
  }
}

void _assertTracedRequest(CollectorOutput output) {
  final span = _spanFor(output, sanitizedTarget);
  if (span == null) {
    _failures.add('no span carried $targetAttribute=$sanitizedTarget');
    return;
  }

  // A client span, not internal: this is the one attribute that tells a dashboard
  // the span is an outbound call rather than local work.
  _expect(span.kind, SpanKind.client, 'span kind');

  _expect(span.attributes[methodAttribute], 'GET', methodAttribute);
  _expect(span.attributes[schemeAttribute], 'http', schemeAttribute);
  _expect(span.attributes[clientAttribute], 'http', clientAttribute);
  _expect(span.attributes[statusAttribute], 200, statusAttribute);
  _expect(span.attributes[peerNameAttribute], '127.0.0.1', peerNameAttribute);
  _expect(span.isError, false, 'a 200 must not be an error');

  // The screen the request was made from (ADR-0004), carried through the same
  // creation-time path as the http attributes.
  _expect(
    span.attributes[screenNameAttribute],
    screenName,
    screenNameAttribute,
  );

  final url = span.attributes[urlAttribute];
  if (url is! String || !url.endsWith(sanitizedTarget)) {
    _failures.add('$urlAttribute is $url, expected it to end $sanitizedTarget');
  }

  // The port is ephemeral, so it cannot be hardcoded — but it must agree with the
  // port in the URL, or one of the two is being derived wrongly.
  final port = span.attributes[peerPortAttribute];
  final portInUrl = url is String ? Uri.tryParse(url)?.port : null;
  if (port is! int || port <= 0) {
    _failures.add('$peerPortAttribute is $port, expected a positive integer');
  } else if (portInUrl != null && port != portInUrl) {
    _failures.add(
      '$peerPortAttribute is $port but $urlAttribute names $portInUrl',
    );
  }

  final responseSize = span.attributes[responseSizeAttribute];
  if (responseSize is! int || responseSize <= 0) {
    _failures.add(
      '$responseSizeAttribute is $responseSize, expected a positive integer',
    );
  }
}

/// A Dio-originated span survives export, carrying what the other integration's does.
///
/// The attributes come from one shared `EdotRequestTrace` (ADR-0013), so this is not
/// a second test of how they are computed — Seam 1 owns that. It is the evidence that
/// a Dio request reaches the collector at all, and is attributed to Dio when it does.
void _assertDioRequest(CollectorOutput output) {
  final span = _spanFor(output, dioPath);
  if (span == null) {
    _failures.add('no span carried $targetAttribute=$dioPath');
    return;
  }

  _expect(span.attributes[clientAttribute], dioClientName, clientAttribute);
  _expect(span.kind, SpanKind.client, 'span kind');
  _expect(span.attributes[methodAttribute], 'GET', methodAttribute);
  _expect(span.attributes[statusAttribute], 200, statusAttribute);
  _expect(span.attributes[peerNameAttribute], '127.0.0.1', peerNameAttribute);
  _expect(span.isError, false, 'a 200 must not be an error');

  // The screen the request was made from, which reaches a Dio span through the same
  // creation-time path (ADR-0004).
  _expect(
    span.attributes[screenNameAttribute],
    screenName,
    screenNameAttribute,
  );

  // The other integration's span must still say it is the other integration's, or
  // this assertion would pass on a run where every span claimed to be Dio's.
  final wrapped = _spanFor(output, sanitizedTarget);
  _expect(
    wrapped?.attributes[clientAttribute],
    httpClientName,
    '$clientAttribute of the $sanitizedTarget span',
  );
}

/// The one behaviour Dio does not share, asserted where it is observable.
///
/// Dio raises a rejected status as an exception where `package:http` returns a
/// response. Recorded naively that puts an exception event on Dio's 500 spans and not
/// on the other integration's, for identical server behaviour — so the two are
/// compared against each other here rather than each against a fixed expectation.
void _assertDioRejectedStatus(CollectorOutput output) {
  final dioSpan = _spanFor(output, dioFailingPath);
  if (dioSpan == null) {
    _failures.add('no span carried $targetAttribute=$dioFailingPath');
    return;
  }

  _expect(dioSpan.attributes[statusAttribute], 500, statusAttribute);
  _expect(dioSpan.isError, true, 'a 500 must be an error');

  if (dioSpan.eventNamed(exceptionEventName) != null) {
    _failures.add(
      'the Dio 500 span carries an $exceptionEventName event. Dio raises a '
      'rejected status as an exception, but a status code is an answer — and the '
      '$failingPath span does not carry one, so the two integrations would '
      'report the same server behaviour differently',
    );
  }
}

void _assertServerFailure(CollectorOutput output) {
  final span = _spanFor(output, failingPath);
  if (span == null) {
    _failures.add('no span carried $targetAttribute=$failingPath');
    return;
  }

  _expect(span.attributes[statusAttribute], 500, statusAttribute);
  _expect(span.isError, true, 'a 500 must be an error');

  // What separates it from a transport failure: the server answered, so there is
  // no exception event.
  if (span.eventNamed(exceptionEventName) != null) {
    _failures.add(
      'the 500 span carries an $exceptionEventName event; a status code is an '
      'answer, not an exception',
    );
  }
}

void _assertTransportFailure(CollectorOutput output) {
  final span = _spanFor(output, unreachablePath);
  if (span == null) {
    _failures.add('no span carried $targetAttribute=$unreachablePath');
    return;
  }

  _expect(span.isError, true, 'a refused connection must be an error');

  // The other half of telling failures apart: no status code, because nothing
  // answered, and an exception event naming the type that did happen.
  if (span.attributes.containsKey(statusAttribute)) {
    _failures.add(
      'the unreachable span carries $statusAttribute='
      '${span.attributes[statusAttribute]}, but nothing answered it',
    );
  }

  final event = span.eventNamed(exceptionEventName);
  if (event == null) {
    _failures.add('the unreachable span carries no $exceptionEventName event');
    return;
  }

  final type = event.attributes[exceptionTypeAttribute];
  if (type is! String || type.isEmpty) {
    _failures.add(
      '$exceptionTypeAttribute is $type, expected the transport failure type',
    );
  }
}

void _assertExclusions(CollectorOutput output) {
  // Both exclusions are absence, so they are asserted over every span rather than
  // by looking one up — the failure mode is a span existing at all.
  for (final (what, needle) in [
    ('the excluded URL', excludedPath),
    ('the Collector Host', collectorPath),
  ]) {
    final leaked = output.spans
        .where((s) => '${s.attributes[targetAttribute]}'.contains(needle))
        .toList();

    if (leaked.isNotEmpty) {
      _failures.add(
        '$what produced ${leaked.length} span(s): '
        '${leaked.map((s) => s.attributes[targetAttribute]).toList()}',
      );
    }
  }
}

void _assertNothingLeaked(CollectorOutput output) {
  // The sanitiser's whole job. Checked across every attribute of every span
  // rather than only the URL, because a query string reaches more than one of them
  // and a second copy would defeat the first assertion.
  for (final span in output.spans) {
    for (final entry in span.attributes.entries) {
      if ('${entry.value}'.contains(secretQueryValue)) {
        _failures.add(
          'span "${span.name}" leaked the query string in ${entry.key}: '
          '${entry.value}',
        );
      }
    }
  }
}

/// Pins the Agent behaviour from ADR-0001.
///
/// On iOS every root span carrying `http.url` is exported with a manufactured
/// parent so it belongs to a transaction; on Android nothing of the sort happens.
/// Asserted rather than tolerated, so an Agent bump that changes it is noticed here
/// instead of in a dashboard where request counts quietly move.
void _assertSyntheticParent(CollectorOutput output) {
  final platform = output
      .spanNamed(controlSpanName)
      .attributes[platformAttribute];
  // Both integrations: the Agent keys this off `http.url`, not off which transport
  // produced the span, so a Dio span is subject to exactly the same rule.
  final traced =
      [sanitizedTarget, failingPath, unreachablePath, dioPath, dioFailingPath]
          .map((target) => _spanFor(output, target))
          .whereType<ExportedSpan>()
          .toList();

  for (final span in traced) {
    final target = span.attributes[targetAttribute];

    if (platform != 'ios') {
      if (span.parentSpanId != null) {
        _failures.add(
          '$target has parent ${span.parentSpanId} on $platform, expected a root',
        );
      }
      continue;
    }

    if (span.parentSpanId == null) {
      _failures.add(
        '$target is a root on iOS, expected the Agent to have given it a '
        'synthetic parent (ADR-0001)',
      );
      continue;
    }

    final parent = output.spans
        .where((s) => s.spanId == span.parentSpanId)
        .firstOrNull;

    if (parent == null) {
      _failures.add(
        '$target names parent ${span.parentSpanId}, which was not exported',
      );
      continue;
    }

    _expect(
      parent.name,
      span.name,
      "the synthetic parent of $target takes its name",
    );
    _expect(
      parent.traceId,
      span.traceId,
      'the synthetic parent shares the trace',
    );
    if (parent.attributes.containsKey(urlAttribute)) {
      _failures.add(
        'the synthetic parent of $target carries $urlAttribute, so it is a real '
        'request span and this assertion is matching the wrong thing',
      );
    }
  }
}

/// The escape hatch from the synthetic parent, on both platforms.
///
/// A request made inside an ambient parent is not a root, so the Agent has nothing
/// to adopt and manufactures nothing. Asserted rather than merely documented on
/// `EdotHttpClient`: an escape hatch nobody checks is a claim, not a feature.
void _assertAmbientParentAvoidsIt(CollectorOutput output) {
  final request = _spanFor(output, parentedPath);
  if (request == null) {
    _failures.add('no span carried $targetAttribute=$parentedPath');
    return;
  }

  final parent = output.spans
      .where((s) => s.spanId == request.parentSpanId)
      .firstOrNull;

  if (parent == null) {
    _failures.add(
      '$parentedPath has parent ${request.parentSpanId ?? 'none'}, expected to be '
      'under $ambientParentSpanName',
    );
    return;
  }

  // The point of the assertion: the parent is *ours*, named, not an attribute-less
  // copy the Agent made. Asserting only "has a parent" would pass on a synthetic one.
  _expect(
    parent.name,
    ambientParentSpanName,
    'the parent of $parentedPath is the ambient span, not a manufactured one',
  );
  _expect(
    parent.traceId,
    request.traceId,
    'the ambient parent shares the trace',
  );
}

void _expect(Object? actual, Object? expected, String what) {
  if (actual != expected) {
    _failures.add('$what: got $actual, expected $expected');
  }
}
