import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:test/test.dart';

/// These tests exercise the harness against recorded collector output, so the
/// assertion plumbing every Seam 2 test depends on is itself verified without
/// needing Docker or a device.
void main() {
  late CollectorOutput output;

  setUp(() {
    output = CollectorOutput.parse(
      File('test/fixtures/telemetry.jsonl').readAsLinesSync(),
    );
  });

  group('spans', () {
    test('reads every span across multiple export requests', () {
      expect(
        output.spans.map((s) => s.name),
        containsAll(['GET', 'checkout', 'route.push']),
      );
    });

    test('finds spans by name', () {
      expect(output.spansNamed('GET'), hasLength(1));
      expect(output.spansNamed('nope'), isEmpty);
    });

    test('exposes a single span by name, failing loudly when ambiguous', () {
      expect(output.spanNamed('GET').name, 'GET');
      expect(() => output.spanNamed('nope'), throwsStateError);
    });

    test('reports duration from the nanosecond timestamps', () {
      expect(
        output.spanNamed('GET').duration,
        const Duration(milliseconds: 180),
      );
      expect(
        output.spanNamed('route.push').duration,
        const Duration(milliseconds: 250),
      );
    });

    test('preserves parent-child structure', () {
      final parent = output.spanNamed('GET');
      final child = output.spanNamed('checkout');

      expect(child.parentSpanId, parent.spanId);
      expect(child.traceId, parent.traceId);
      expect(parent.parentSpanId, isNull, reason: 'GET is a root span');
    });

    test('groups spans sharing a trace', () {
      expect(
        output.spansInTrace('4bf92f3577b34da6a3ce929d0e0e4736'),
        hasLength(2),
      );
      expect(output.traceIds, hasLength(2));
    });

    test('exposes span kind', () {
      expect(output.spanNamed('GET').kind, SpanKind.client);
      expect(output.spanNamed('checkout').kind, SpanKind.internal);
    });

    test('reports error status with its message', () {
      final failed = output.spanNamed('checkout');

      expect(failed.isError, isTrue);
      expect(failed.statusMessage, 'boom');
      expect(output.spanNamed('GET').isError, isFalse);
    });
  });

  group('attribute typing', () {
    // Integer attributes exported as floating point would make numeric
    // attributes useless to aggregate, so the distinction is asserted directly.
    test('decodes strings, ints, doubles and bools to their Dart types', () {
      final attrs = output.spanNamed('GET').attributes;

      expect(attrs['http.method'], 'GET');
      expect(attrs['http.status_code'], 200);
      expect(attrs['http.status_code'], isA<int>());
      expect(attrs['net.peer.port'], isA<int>());
      expect(attrs['http.request_body.size'], isA<double>());
      expect(attrs['edot.retried'], isTrue);
    });

    test('reports absent attributes as null rather than throwing', () {
      expect(output.spanNamed('GET').attributes['nope'], isNull);
    });
  });

  group('resource attributes', () {
    test('exposes resource attributes alongside each span', () {
      final resource = output.spanNamed('GET').resource;

      expect(resource['service.name'], 'example-app');
      expect(resource['service.version'], '1.2.3');
      expect(resource['session.id'], '5f2b1c9a');
    });

    test('exposes both deployment environment spellings', () {
      // The pinned iOS Agent hardcodes deployment.environment, so ADR-0001
      // requires the Plugin to set both spellings.
      final resource = output.spanNamed('GET').resource;

      expect(resource['deployment.environment'], 'test');
      expect(resource['deployment.environment.name'], 'test');
    });
  });

  group('logs', () {
    test('reads log records with severity, body and attributes', () {
      expect(output.logs, hasLength(1));

      final log = output.logs.single;
      expect(log.severityText, 'ERROR');
      expect(log.severityNumber, 17);
      expect(log.body, contains('FormatException'));
      expect(log.attributes['exception.type'], 'FormatException');
      expect(log.attributes['error.source'], 'flutter.onError');
    });

    test('exposes resource attributes on log records', () {
      expect(output.logs.single.resource['session.id'], '5f2b1c9a');
    });
  });

  group('robustness', () {
    test('ignores blank lines', () {
      final parsed = CollectorOutput.parse(['', '   ', '']);

      expect(parsed.spans, isEmpty);
      expect(parsed.logs, isEmpty);
    });

    test('surfaces malformed lines instead of silently skipping them', () {
      // A silently-swallowed parse failure would look identical to "the Plugin
      // emitted nothing", which is the failure mode Seam 2 exists to catch.
      expect(
        () => CollectorOutput.parse(['{not json']),
        throwsA(isA<FormatException>()),
      );
    });

    test('ignores export requests carrying signals it does not parse yet', () {
      // Metric parsing lands with the logs-and-metrics ticket.
      final parsed = CollectorOutput.parse(['{"resourceMetrics":[]}']);

      expect(parsed.spans, isEmpty);
      expect(parsed.logs, isEmpty);
    });
  });
}
