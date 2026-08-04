import 'dart:convert';

/// OpenTelemetry span kind, as encoded in OTLP.
enum SpanKind {
  unspecified,
  internal,
  server,
  client,
  producer,
  consumer;

  static SpanKind fromCode(Object? code) => switch (code) {
    1 => SpanKind.internal,
    2 => SpanKind.server,
    3 => SpanKind.client,
    4 => SpanKind.producer,
    5 => SpanKind.consumer,
    _ => SpanKind.unspecified,
  };
}

/// How a metric aggregates, as encoded in OTLP.
enum MetricKind {
  /// A counter or up-down counter — [ExportedMetric.isMonotonic] tells them apart.
  sum,
  gauge,
  histogram,

  /// A metric shape this harness does not decode (exponential histogram, summary).
  unknown,
}

/// Telemetry read back from the collector's file exporter.
///
/// The collector writes one JSON object per line, each an OTLP export request,
/// so a single run's output is many lines covering many signals.
class CollectorOutput {
  CollectorOutput._(this.spans, this.logs, this.metrics);

  final List<ExportedSpan> spans;
  final List<ExportedLogRecord> logs;
  final List<ExportedMetric> metrics;

  /// Parses collector file-exporter output.
  ///
  /// Blank lines are ignored. A malformed line throws rather than being skipped:
  /// silently swallowing it would be indistinguishable from the Plugin having
  /// emitted nothing, which is the failure Seam 2 exists to catch.
  static CollectorOutput parse(Iterable<String> lines) {
    final spans = <ExportedSpan>[];
    final logs = <ExportedLogRecord>[];
    final metrics = <ExportedMetric>[];

    for (final line in lines) {
      if (line.trim().isEmpty) continue;

      final request = jsonDecode(line);
      if (request is! Map<String, Object?>) {
        throw FormatException('Export request is not a JSON object', line);
      }

      _readResourceSpans(request['resourceSpans'], spans);
      _readResourceLogs(request['resourceLogs'], logs);
      _readResourceMetrics(request['resourceMetrics'], metrics);
    }

    return CollectorOutput._(spans, logs, metrics);
  }

  /// Every span with this name, in export order.
  List<ExportedSpan> spansNamed(String name) =>
      spans.where((s) => s.name == name).toList();

  /// The single span with this name. Throws when absent or ambiguous, so a test
  /// fails on the real problem rather than on a downstream null.
  ExportedSpan spanNamed(String name) {
    final matches = spansNamed(name);
    if (matches.length != 1) {
      throw StateError(
        'Expected exactly one span named "$name", found ${matches.length}. '
        'Spans present: ${spans.map((s) => s.name).toList()}',
      );
    }
    return matches.single;
  }

  /// Every span belonging to one trace.
  List<ExportedSpan> spansInTrace(String traceId) =>
      spans.where((s) => s.traceId == traceId).toList();

  /// Distinct trace ids across all spans.
  Set<String> get traceIds => spans.map((s) => s.traceId).toSet();

  /// Every log record with this body, in export order.
  List<ExportedLogRecord> logsWithBody(Object? body) =>
      logs.where((l) => l.body == body).toList();

  /// The single log record with this body. Throws when absent or ambiguous, for
  /// the same reason as [spanNamed].
  ExportedLogRecord logWithBody(Object? body) {
    final matches = logsWithBody(body);
    if (matches.length != 1) {
      throw StateError(
        'Expected exactly one log record with body "$body", '
        'found ${matches.length}. '
        'Bodies present: ${logs.map((l) => l.body).toList()}',
      );
    }
    return matches.single;
  }

  /// Every export of the metric with this name, in export order.
  List<ExportedMetric> metricsNamed(String name) =>
      metrics.where((m) => m.name == name).toList();

  /// The most recent export of the metric with this name. Throws when absent.
  ///
  /// Unlike [spanNamed] this tolerates repeats rather than failing on them: a
  /// metric reader re-exports every instrument once per collection cycle, so how
  /// many copies arrive depends on how long the app stayed alive.
  ExportedMetric metricNamed(String name) {
    final matches = metricsNamed(name);
    if (matches.isEmpty) {
      throw StateError(
        'No metric named "$name". '
        'Metrics present: ${metrics.map((m) => m.name).toSet().toList()}',
      );
    }
    return matches.last;
  }

  static void _readResourceSpans(Object? node, List<ExportedSpan> out) {
    for (final resourceSpans in _asList(node)) {
      final resource = _attributes(
        _asMap(resourceSpans['resource'])['attributes'],
      );

      for (final scopeSpans in _asList(resourceSpans['scopeSpans'])) {
        final scopeName = _asMap(scopeSpans['scope'])['name'] as String?;

        for (final span in _asList(scopeSpans['spans'])) {
          final status = _asMap(span['status']);
          out.add(
            ExportedSpan(
              name: span['name'] as String? ?? '',
              traceId: span['traceId'] as String? ?? '',
              spanId: span['spanId'] as String? ?? '',
              parentSpanId: _emptyToNull(span['parentSpanId'] as String?),
              kind: SpanKind.fromCode(span['kind']),
              startNanos: _int(span['startTimeUnixNano']) ?? 0,
              endNanos: _int(span['endTimeUnixNano']) ?? 0,
              attributes: _attributes(span['attributes']),
              events: _events(span['events']),
              resource: resource,
              scopeName: scopeName,
              statusCode: _int(status['code'])?.toInt() ?? 0,
              statusMessage: _emptyToNull(status['message'] as String?),
            ),
          );
        }
      }
    }
  }

  static void _readResourceLogs(Object? node, List<ExportedLogRecord> out) {
    for (final resourceLogs in _asList(node)) {
      final resource = _attributes(
        _asMap(resourceLogs['resource'])['attributes'],
      );

      for (final scopeLogs in _asList(resourceLogs['scopeLogs'])) {
        final scopeName = _asMap(scopeLogs['scope'])['name'] as String?;

        for (final record in _asList(scopeLogs['logRecords'])) {
          out.add(
            ExportedLogRecord(
              timeNanos: _int(record['timeUnixNano']) ?? 0,
              severityNumber: _int(record['severityNumber'])?.toInt() ?? 0,
              severityText: record['severityText'] as String? ?? '',
              body: _anyValue(_asMap(record['body'])),
              attributes: _attributes(record['attributes']),
              resource: resource,
              scopeName: scopeName,
            ),
          );
        }
      }
    }
  }

  static void _readResourceMetrics(Object? node, List<ExportedMetric> out) {
    for (final resourceMetrics in _asList(node)) {
      final resource = _attributes(
        _asMap(resourceMetrics['resource'])['attributes'],
      );

      for (final scopeMetrics in _asList(resourceMetrics['scopeMetrics'])) {
        final scopeName = _asMap(scopeMetrics['scope'])['name'] as String?;

        for (final metric in _asList(scopeMetrics['metrics'])) {
          final (kind, body) = _metricBody(metric);
          out.add(
            ExportedMetric(
              name: metric['name'] as String? ?? '',
              kind: kind,
              isMonotonic: kind == MetricKind.sum
                  ? body['isMonotonic'] as bool? ?? false
                  : null,
              points: _metricPoints(body['dataPoints']),
              resource: resource,
              scopeName: scopeName,
            ),
          );
        }
      }
    }
  }

  /// Reads a metric's aggregation and the node holding its data points.
  ///
  /// OTLP names the aggregation by which field is present rather than by a tag,
  /// so the shape has to be discovered the same way [_anyValue] discovers a
  /// value's type.
  static (MetricKind, Map<String, Object?>) _metricBody(
    Map<String, Object?> metric,
  ) {
    if (metric.containsKey('sum')) {
      return (MetricKind.sum, _asMap(metric['sum']));
    }
    if (metric.containsKey('gauge')) {
      return (MetricKind.gauge, _asMap(metric['gauge']));
    }
    if (metric.containsKey('histogram')) {
      return (MetricKind.histogram, _asMap(metric['histogram']));
    }
    return (MetricKind.unknown, const <String, Object?>{});
  }

  static List<ExportedMetricPoint> _metricPoints(Object? node) => [
    for (final point in _asList(node))
      ExportedMetricPoint(
        timeNanos: _int(point['timeUnixNano']) ?? 0,
        attributes: _attributes(point['attributes']),
        value: _pointValue(point),
        count: _int(point['count']),
        sum: _double(point['sum']),
      ),
  ];

  /// The value of a sum or gauge point. Null on a histogram point, which reports
  /// [ExportedMetricPoint.count] and [ExportedMetricPoint.sum] instead.
  static double? _pointValue(Map<String, Object?> point) {
    if (point.containsKey('asDouble')) return _double(point['asDouble']);
    if (point.containsKey('asInt')) return _int(point['asInt'])?.toDouble();
    return null;
  }

  /// Decodes an OTLP KeyValue list into a plain map.
  static Map<String, Object?> _attributes(Object? node) {
    final decoded = <String, Object?>{};
    for (final entry in _asList(node)) {
      final key = entry['key'] as String?;
      if (key == null) continue;
      decoded[key] = _anyValue(_asMap(entry['value']));
    }
    return decoded;
  }

  static List<ExportedSpanEvent> _events(Object? raw) => [
    for (final event in _asList(raw))
      ExportedSpanEvent(
        name: event['name'] as String? ?? '',
        timeNanos: _int(event['timeUnixNano']) ?? 0,
        attributes: _attributes(event['attributes']),
      ),
  ];

  /// Decodes an OTLP AnyValue.
  ///
  /// OTLP JSON encodes 64-bit integers as strings, so `intValue` is parsed back
  /// to [int] deliberately — reporting it as a double would defeat the point of
  /// asserting that integer attributes survive as integers.
  static Object? _anyValue(Map<String, Object?> value) {
    if (value.containsKey('stringValue')) return value['stringValue'];
    if (value.containsKey('intValue')) return _int(value['intValue']);
    if (value.containsKey('doubleValue')) return _double(value['doubleValue']);
    if (value.containsKey('boolValue')) return value['boolValue'];
    if (value.containsKey('bytesValue')) return value['bytesValue'];
    if (value.containsKey('arrayValue')) {
      return _asList(
        _asMap(value['arrayValue'])['values'],
      ).map((v) => _anyValue(v)).toList();
    }
    if (value.containsKey('kvlistValue')) {
      return _attributes(_asMap(value['kvlistValue'])['values']);
    }
    return null;
  }

  static int? _int(Object? raw) => switch (raw) {
    final int value => value,
    final String value => int.tryParse(value),
    final num value => value.toInt(),
    _ => null,
  };

  static double? _double(Object? raw) => switch (raw) {
    final num value => value.toDouble(),
    final String value => double.tryParse(value),
    _ => null,
  };

  static String? _emptyToNull(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  static List<Map<String, Object?>> _asList(Object? node) => node is List
      ? node.whereType<Map<String, Object?>>().toList()
      : const <Map<String, Object?>>[];

  static Map<String, Object?> _asMap(Object? node) =>
      node is Map<String, Object?> ? node : const <String, Object?>{};
}

/// A span as it arrived at the collector.
class ExportedSpan {
  ExportedSpan({
    required this.name,
    required this.traceId,
    required this.spanId,
    required this.parentSpanId,
    required this.kind,
    required this.startNanos,
    required this.endNanos,
    required this.attributes,
    required this.events,
    required this.resource,
    required this.scopeName,
    required this.statusCode,
    required this.statusMessage,
  });

  final String name;
  final String traceId;
  final String spanId;

  /// Null for a root span.
  final String? parentSpanId;
  final SpanKind kind;
  final int startNanos;
  final int endNanos;
  final Map<String, Object?> attributes;

  /// Events recorded on the span, in export order.
  final List<ExportedSpanEvent> events;

  /// Resource attributes of the export this span arrived in.
  final Map<String, Object?> resource;
  final String? scopeName;
  final int statusCode;
  final String? statusMessage;

  /// Wall duration, truncated to microseconds — Dart's [Duration] resolution.
  Duration get duration =>
      Duration(microseconds: (endNanos - startNanos) ~/ 1000);

  /// OTLP status code 2 is ERROR.
  bool get isError => statusCode == 2;

  /// The single event named [name], or null if absent.
  ///
  /// Throws [StateError] when several match, because an assertion written against
  /// "the" event would otherwise silently pick one and pass for the wrong reason.
  ExportedSpanEvent? eventNamed(String name) {
    final matches = events.where((event) => event.name == name).toList();
    if (matches.length > 1) {
      throw StateError(
        'Span "$this" has ${matches.length} events named "$name". '
        'Assert on `events` directly.',
      );
    }
    return matches.isEmpty ? null : matches.single;
  }

  @override
  String toString() =>
      'ExportedSpan($name, kind: ${kind.name}, '
      'duration: $duration, attributes: $attributes)';
}

/// An event recorded on a span, such as a recorded exception.
class ExportedSpanEvent {
  ExportedSpanEvent({
    required this.name,
    required this.timeNanos,
    required this.attributes,
  });

  final String name;
  final int timeNanos;
  final Map<String, Object?> attributes;

  @override
  String toString() => 'ExportedSpanEvent($name, attributes: $attributes)';
}

/// A log record as it arrived at the collector.
class ExportedLogRecord {
  ExportedLogRecord({
    required this.timeNanos,
    required this.severityNumber,
    required this.severityText,
    required this.body,
    required this.attributes,
    required this.resource,
    required this.scopeName,
  });

  final int timeNanos;
  final int severityNumber;
  final String severityText;
  final Object? body;
  final Map<String, Object?> attributes;
  final Map<String, Object?> resource;
  final String? scopeName;

  @override
  String toString() =>
      'ExportedLogRecord($severityText, body: $body, attributes: $attributes)';
}

/// A metric as it arrived at the collector.
class ExportedMetric {
  ExportedMetric({
    required this.name,
    required this.kind,
    required this.isMonotonic,
    required this.points,
    required this.resource,
    required this.scopeName,
  });

  final String name;
  final MetricKind kind;

  /// True for a counter, false for an up-down counter, null when [kind] is not
  /// [MetricKind.sum] — which is the only way the two counters differ on the wire.
  final bool? isMonotonic;

  /// One point per distinct set of dimensions.
  final List<ExportedMetricPoint> points;

  /// Resource attributes of the export this metric arrived in.
  final Map<String, Object?> resource;
  final String? scopeName;

  /// The only point. Throws when the metric carries several, so an assertion
  /// written against "the" value cannot pass by picking an arbitrary dimension.
  ExportedMetricPoint get point {
    if (points.length != 1) {
      throw StateError(
        'Metric "$name" has ${points.length} data points. '
        'Assert on `points` directly.',
      );
    }
    return points.single;
  }

  @override
  String toString() =>
      'ExportedMetric($name, kind: ${kind.name}, '
      'monotonic: $isMonotonic, points: $points)';
}

/// One data point of an [ExportedMetric].
class ExportedMetricPoint {
  ExportedMetricPoint({
    required this.timeNanos,
    required this.attributes,
    required this.value,
    required this.count,
    required this.sum,
  });

  final int timeNanos;

  /// The point's dimensions.
  final Map<String, Object?> attributes;

  /// The value of a sum or gauge point; null on a histogram point.
  final double? value;

  /// Recorded-value count on a histogram point; null otherwise.
  final int? count;

  /// Total of the recorded values on a histogram point; null otherwise.
  final double? sum;

  @override
  String toString() => value != null
      ? 'ExportedMetricPoint($value, attributes: $attributes)'
      : 'ExportedMetricPoint(count: $count, sum: $sum, attributes: $attributes)';
}
