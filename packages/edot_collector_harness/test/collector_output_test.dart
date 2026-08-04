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

    test('finds a record by body, failing loudly when it never arrived', () {
      expect(output.logWithBody(output.logs.single.body).severityText, 'ERROR');
      expect(output.logsWithBody('nope'), isEmpty);
      expect(() => output.logWithBody('nope'), throwsStateError);
    });
  });

  group('metrics', () {
    test('distinguishes a counter from an up-down counter', () {
      // The two are the same OTLP sum; only isMonotonic separates them, so a
      // Seam 2 test asserting "this was a counter" has nothing else to look at.
      expect(output.metricNamed('checkout.total').kind, MetricKind.sum);
      expect(output.metricNamed('checkout.total').isMonotonic, isTrue);
      expect(output.metricNamed('cart.items').isMonotonic, isFalse);
    });

    test('reads a point value and its dimensions', () {
      final point = output.metricsNamed('checkout.total').first.point;

      expect(point.value, 42.5);
      expect(point.attributes['currency'], 'THB');
    });

    test('reads a histogram as count and sum rather than a point value', () {
      final histogram = output.metricNamed('checkout.latency');

      expect(histogram.kind, MetricKind.histogram);
      expect(histogram.isMonotonic, isNull);
      expect(histogram.point.count, 1);
      expect(histogram.point.sum, 180.0);
      expect(histogram.point.value, isNull);
    });

    test('exposes every export of a repeatedly collected metric', () {
      // A metric reader re-exports each instrument per collection cycle, so how
      // many copies arrive depends on how long the app ran.
      expect(output.metricsNamed('checkout.total'), hasLength(2));
      expect(output.metricNamed('checkout.total').point.value, 84.0);
    });

    test('refuses to pick one of several dimensions', () {
      final byChannel = output.metricNamed('checkout.by_channel');

      expect(byChannel.points, hasLength(2));
      expect(() => byChannel.point, throwsStateError);
    });

    test('fails loudly on a metric that never arrived', () {
      expect(() => output.metricNamed('nope'), throwsStateError);
    });

    test('exposes resource attributes on metrics', () {
      expect(
        output.metricNamed('cart.items').resource['session.id'],
        '5f2b1c9a',
      );
    });
  });

  group('robustness', () {
    test('ignores blank lines', () {
      final parsed = CollectorOutput.parse(['', '   ', '']);

      expect(parsed.spans, isEmpty);
      expect(parsed.logs, isEmpty);
      expect(parsed.metrics, isEmpty);
    });

    test('surfaces malformed lines instead of silently skipping them', () {
      // A silently-swallowed parse failure would look identical to "the Plugin
      // emitted nothing", which is the failure mode Seam 2 exists to catch.
      expect(
        () => CollectorOutput.parse(['{not json']),
        throwsA(isA<FormatException>()),
      );
    });

    test('ignores export requests carrying signals it does not parse', () {
      // Profiles are a real OTLP signal the Plugin never emits; an unrecognised
      // request is not the harness's problem to report.
      final parsed = CollectorOutput.parse(['{"resourceProfiles":[]}']);

      expect(parsed.spans, isEmpty);
      expect(parsed.logs, isEmpty);
      expect(parsed.metrics, isEmpty);
    });

    test('reports an undecodable metric shape rather than guessing', () {
      // An exponential histogram would otherwise silently arrive as a sum.
      final parsed = CollectorOutput.parse([
        '{"resourceMetrics":[{"scopeMetrics":[{"metrics":['
            '{"name":"m","exponentialHistogram":{"dataPoints":[]}}]}]}]}',
      ]);

      expect(parsed.metricNamed('m').kind, MetricKind.unknown);
    });
  });
}
