import 'dart:math';

import 'package:flutter/foundation.dart';

import 'edot_channel.dart';

/// Creates spans.
///
/// Under ADR-0002 the Agent is authoritative: it holds the real span, keyed by
/// the Shadow Span identifier this tracer mints. Nothing here awaits the Agent,
/// so spans can be created from synchronous code such as build and paint
/// callbacks.
class EdotTracer {
  EdotTracer() : _now = _utcNow, _elapsed = null;

  /// Injects the clocks, so the timestamp rules in ADR-0005 are testable — a
  /// wall-clock jump mid-span cannot be provoked otherwise.
  ///
  /// Positional because Dart forbids private named parameters, and these fields
  /// have no business being public.
  @visibleForTesting
  EdotTracer.withClock(this._now, this._elapsed);

  final DateTime Function() _now;
  final Duration Function()? _elapsed;

  static DateTime _utcNow() => DateTime.now().toUtc();

  /// Random per-process prefix, so identifiers from two runs cannot collide in
  /// the Agent's registry if one outlives a hot restart.
  static final String _idPrefix = () {
    final random = Random.secure();
    return List.generate(
      4,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }();

  static int _idCounter = 0;

  /// Starts a span. Call [EdotSpan.end] to finish it.
  ///
  /// The returned span is already registered with the Agent — this does not
  /// await, so a dropped span surfaces in debug logs rather than as an exception
  /// at the call site.
  EdotSpan startSpan(String name) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'span name must not be blank');
    }

    final shadowId = '$_idPrefix-${_idCounter++}';
    final startedAt = _now();

    sendOneWay('spanStart', <String, Object?>{
      'shadowId': shadowId,
      'name': name,
      'startUs': startedAt.microsecondsSinceEpoch,
    });

    return EdotSpan._(
      shadowId,
      name,
      startedAt,
      _elapsed ?? _stopwatchElapsed(),
    );
  }

  /// A monotonic elapsed reader for one span.
  static Duration Function() _stopwatchElapsed() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }
}

/// A span held by the Agent, referenced from Dart by its Shadow Span identifier.
class EdotSpan {
  /// Positional because two of the four fields are private, and Dart forbids
  /// private named parameters.
  EdotSpan._(this.shadowId, this.name, this._startedAt, this._elapsed);

  /// Identifier the Agent's registry is keyed by. Not the OpenTelemetry span id,
  /// which the Agent owns and Dart never sees.
  final String shadowId;

  final String name;

  final DateTime _startedAt;
  final Duration Function() _elapsed;
  bool _ended = false;

  /// Whether [end] has already run.
  bool get isEnded => _ended;

  /// Attaches a string attribute.
  ///
  /// Keys the Plugin's own instrumentation emits come from the Elastic Mobile
  /// Attribute Set (ADR-0003), not the stable OpenTelemetry conventions. Callers
  /// setting their own keys are unconstrained.
  void setString(String key, String value) =>
      _enrich('spanSetString', key, value);

  /// Attaches an integer attribute.
  ///
  /// Separate from [setDouble] because the two cannot be told apart on iOS once
  /// they have crossed the channel: Flutter delivers numbers as `NSNumber`, which
  /// casts happily to either. An integer that arrived as a double would stop being
  /// aggregatable, which is most of what a numeric attribute is for.
  void setInt(String key, int value) => _enrich('spanSetInt', key, value);

  /// Attaches a floating-point attribute. See [setInt] for why these are separate.
  void setDouble(String key, double value) =>
      _enrich('spanSetDouble', key, value);

  /// Attaches a boolean attribute.
  void setBool(String key, bool value) => _enrich('spanSetBool', key, value);

  void _enrich(String method, String key, Object value) {
    if (key.trim().isEmpty) {
      throw ArgumentError.value(key, 'key', 'attribute key must not be blank');
    }
    // The Agent dropped this span from its registry when it ended, so the only
    // thing sending now would achieve is a warning on the other side.
    if (_ended) return;

    sendOneWay(method, <String, Object?>{
      'shadowId': shadowId,
      'key': key,
      'value': value,
    });
  }

  /// Records [error] against the span as an exception event.
  ///
  /// Does **not** fail the span. OpenTelemetry keeps the two separate, and so does
  /// this: an exception can be recorded on an operation that recovered and
  /// succeeded. Call [markFailed] when the operation itself failed.
  void recordException(Object error, {StackTrace? stackTrace}) {
    if (_ended) return;

    sendOneWay('spanRecordException', <String, Object?>{
      'shadowId': shadowId,
      'type': error.runtimeType.toString(),
      'message': error.toString(),
      'stacktrace': stackTrace?.toString(),
    });
  }

  /// Marks the span failed, so the failure is visible on the operation itself
  /// rather than only in an event attached to it.
  void markFailed([String? description]) {
    if (_ended) return;

    sendOneWay('spanMarkFailed', <String, Object?>{
      'shadowId': shadowId,
      'description': description,
    });
  }

  /// Ends the span.
  ///
  /// The end timestamp is the anchored start plus monotonic elapsed time, never a
  /// second wall-clock reading — so a clock change mid-span cannot distort the
  /// duration (ADR-0005).
  ///
  /// Calling this twice is ignored. A double-end is a caller bug, but throwing
  /// would turn it into a crash in the host app for a telemetry mistake.
  void end() {
    if (_ended) return;
    _ended = true;

    final endedAt = _startedAt.add(_elapsed());

    sendOneWay('spanEnd', <String, Object?>{
      'shadowId': shadowId,
      'endUs': endedAt.microsecondsSinceEpoch,
    });
  }
}
