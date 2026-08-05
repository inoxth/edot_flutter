import 'dart:async';

import 'package:flutter/foundation.dart';

import 'edot_active_view.dart';
import 'edot_channel.dart';
import 'edot_ids.dart';

/// Zone key holding the ambient parent span.
///
/// A zone rather than a field on the tracer, because parenting is per-flow: two
/// concurrent async flows must not steal each other's parent. A mutable
/// "currently active span" would do exactly that, and would produce trace trees
/// that look plausible and are wrong — worse than no nesting at all. Zones are
/// Dart's own mechanism and survive `await` boundaries, which is what makes them
/// the right fit (see ADR-0004, which contrasts this with the Active View's
/// deliberately global singleton).
final Object _ambientParentKey = Object();

/// What kind of operation a span measures.
///
/// Only the two kinds this Plugin produces. A mobile app makes outbound calls and
/// does local work; it does not serve requests or drive a message queue, so the
/// remaining OpenTelemetry kinds would be values nothing could ever set.
enum EdotSpanKind {
  /// Local work. The default.
  internal,

  /// An outbound request, waiting on something remote.
  client,
}

/// Creates spans.
///
/// Under ADR-0002 the Agent is authoritative: it holds the real span, keyed by
/// the Shadow Span identifier this tracer mints. Nothing here awaits the Agent,
/// so spans can be created from synchronous code such as build and paint
/// callbacks.
class EdotTracer {
  /// Creates a tracer backed by the real wall clock.
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

  /// The span that [startSpan] would nest under right now, if any.
  ///
  /// Set by [runWithParent] and inherited across `await` boundaries.
  EdotSpan? get ambientParent => Zone.current[_ambientParentKey] as EdotSpan?;

  /// Runs [body] with [parent] as the ambient parent, so spans created anywhere
  /// inside it — including after an `await` — become its children without being
  /// passed a parent.
  ///
  /// Generic over the return type so one method serves both synchronous and
  /// asynchronous bodies: an `async` body returns a `Future`, and the zone is
  /// inherited by its continuations.
  ///
  /// The scope is the body, not the span's lifetime. Spans started after this
  /// returns are not children of [parent], even if it has not ended yet — which
  /// is the point, because tying the scope to the span would make it ambient for
  /// concurrent work that has nothing to do with it.
  R runWithParent<R>(EdotSpan parent, R Function() body) =>
      runZoned(body, zoneValues: {_ambientParentKey: parent});

  /// Starts a span. Call [EdotSpan.end] to finish it.
  ///
  /// Nests under [parent] when given, otherwise under [ambientParent], otherwise
  /// starts a new trace as a root.
  ///
  /// Being the most recently started span does *not* make a span a parent. That
  /// rule is what produces plausible-looking, wrong trace trees as soon as two
  /// async flows overlap; use [runWithParent] to establish parenting explicitly.
  ///
  /// The returned span is already registered with the Agent — this does not
  /// await, so a dropped span surfaces in debug logs rather than as an exception
  /// at the call site.
  ///
  /// The span records the Active View as it is *now*. A span that outlives a
  /// navigation still belongs to the screen it began on.
  ///
  /// [attributes] are applied before the span starts, so samplers and processors
  /// see them; anything set afterwards arrives too late for that. They are merged
  /// over the Active View's, which cannot collide with them in practice — the
  /// screen keys are the Plugin's own.
  EdotSpan startSpan(
    String name, {
    EdotSpan? parent,
    EdotSpanKind kind = EdotSpanKind.internal,
    Map<String, String> attributes = const {},
  }) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'span name must not be blank');
    }

    final shadowId = newLocalId();
    final startedAt = _now();
    final resolvedParent = parent ?? ambientParent;

    sendOneWay('spanStart', <String, Object?>{
      'shadowId': shadowId,
      'name': name,
      'startUs': startedAt.microsecondsSinceEpoch,
      // Null means root. A parent that has already ended is no longer in the
      // Agent's registry, so the Agent logs it and starts a root instead —
      // ending a parent before its children is a caller bug, and silently
      // re-rooting it here would hide that rather than surface it.
      'parentShadowId': resolvedParent?.shadowId,
      'kind': kind.name,
      // Applied before the span starts, so sampling and processors see them.
      // Attributes set afterwards would arrive too late for that.
      'attributes': {...activeViewAttributes(), ...attributes},
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

  /// The span's name, as passed to [EdotTracer.startSpan].
  final String name;

  final DateTime _startedAt;
  final Duration Function() _elapsed;
  bool _ended = false;

  /// Whether [end] has already run.
  bool get isEnded => _ended;

  /// W3C Trace Context headers naming this span as the caller, for an outgoing
  /// request.
  ///
  /// The one call that waits for the Agent (ADR-0002). It has to: the headers carry
  /// the real trace and span ids, and those belong to the Agent's span. A locally
  /// minted identifier would link the receiving service's spans to a span Kibana
  /// has never heard of, which is worse than no link.
  ///
  /// W3C only — `traceparent`, plus `tracestate` when the span carries one. Elastic's
  /// own `elastic-apm-traceparent` is deprecated and deliberately never sent.
  ///
  /// Empty when the span has already ended, when the Agent is not running, or when
  /// the call failed. The caller then sends an uncorrelated request rather than no
  /// request at all.
  Future<Map<String, String>> traceContextHeaders() {
    // The Agent dropped this span from its registry when it ended, so it has no
    // context left to hand back.
    if (_ended) return Future.value(const {});

    return fetchStringMap('spanTraceContext', <String, Object?>{
      'shadowId': shadowId,
    });
  }

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
  ///
  /// [type] overrides `exception.type`, which is otherwise [error]'s runtime type.
  /// For a library whose one exception class covers many causes, the class name
  /// cannot tell a cancellation from a timeout, and that distinction is most of what
  /// the attribute is read for.
  void recordException(Object error, {StackTrace? stackTrace, String? type}) {
    if (_ended) return;

    sendOneWay('spanRecordException', <String, Object?>{
      'shadowId': shadowId,
      'type': type ?? error.runtimeType.toString(),
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
