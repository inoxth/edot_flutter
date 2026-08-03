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

/// Telemetry read back from the collector's file exporter.
///
/// The collector writes one JSON object per line, each an OTLP export request,
/// so a single run's output is many lines covering many signals.
class CollectorOutput {
  CollectorOutput._(this.spans, this.logs);

  final List<ExportedSpan> spans;
  final List<ExportedLogRecord> logs;

  /// Parses collector file-exporter output.
  ///
  /// Blank lines are ignored. A malformed line throws rather than being skipped:
  /// silently swallowing it would be indistinguishable from the Plugin having
  /// emitted nothing, which is the failure Seam 2 exists to catch.
  static CollectorOutput parse(Iterable<String> lines) {
    final spans = <ExportedSpan>[];
    final logs = <ExportedLogRecord>[];

    for (final line in lines) {
      if (line.trim().isEmpty) continue;

      final request = jsonDecode(line);
      if (request is! Map<String, Object?>) {
        throw FormatException('Export request is not a JSON object', line);
      }

      _readResourceSpans(request['resourceSpans'], spans);
      _readResourceLogs(request['resourceLogs'], logs);
      // Metric parsing lands with the logs-and-metrics ticket; unknown signals
      // are ignored rather than treated as an error.
    }

    return CollectorOutput._(spans, logs);
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

  /// Decodes an OTLP AnyValue.
  ///
  /// OTLP JSON encodes 64-bit integers as strings, so `intValue` is parsed back
  /// to [int] deliberately — reporting it as a double would defeat the point of
  /// asserting that integer attributes survive as integers.
  static Object? _anyValue(Map<String, Object?> value) {
    if (value.containsKey('stringValue')) return value['stringValue'];
    if (value.containsKey('intValue')) return _int(value['intValue']);
    if (value.containsKey('doubleValue')) {
      final raw = value['doubleValue'];
      return raw is num ? raw.toDouble() : double.tryParse('$raw');
    }
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

  @override
  String toString() =>
      'ExportedSpan($name, kind: ${kind.name}, '
      'duration: $duration, attributes: $attributes)';
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
