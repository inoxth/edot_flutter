import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'edot_active_view.dart' as active_view;
import 'edot_channel.dart';
import 'edot_errors.dart';
// Imported a second time under a prefix so [Edot.isolateErrorPort] can forward to the
// library getter of the same name. Unprefixed, the name inside the getter's own body
// would resolve to the getter, and the forward would recurse.
import 'edot_errors.dart' as errors show isolateErrorPort;
import 'edot_http_overrides.dart';
import 'edot_config.dart';
import 'edot_signals.dart';
import 'edot_tracing_rules.dart';
import 'edot_tracer.dart';

/// Entry point to the Plugin.
///
/// Call [start] once, early in `main`, then use [tracer] to create spans.
///
/// Static rather than an injected instance because the Agent underneath is itself
/// a process-wide singleton on both platforms — modelling it as anything else
/// would imply an independence that does not exist.
abstract final class Edot {
  static EdotTracer? _tracer;

  /// Whether [start] has completed.
  static bool get isStarted => _tracer != null;

  /// Starts the Agent.
  ///
  /// Throws [ArgumentError] for invalid configuration (see [EdotConfig]) and
  /// [StateError] if called twice. Both are programming errors worth failing
  /// loudly for; a silent second initialisation would leave two export pipelines
  /// racing.
  ///
  /// Transport failures are not reported here — the Agent buffers to disk and
  /// retries, so an unreachable collector is not a startup error.
  static Future<void> start(EdotConfig config) async {
    if (_tracer != null) {
      throw StateError(
        'Edot.start has already been called. Starting twice would leave two '
        'export pipelines running.',
      );
    }

    debugLoggingEnabled = config.debug;
    edotLog('starting agent: $config');

    await edotChannel.invokeMethod<void>('initialize', encodeConfig(config));

    _tracer = EdotTracer();
    setTracingRules(EdotTracingRules.fromConfig(config));

    // After the rules, never before: the override starts tracing the moment it is in
    // place, and without rules it could not tell the Collector Host from anything else.
    if (config.traceAllHttpTraffic) {
      installHttpOverrides();
      edotLog('tracing all dart:io traffic');
    }

    // Automatic, not opt-in: since Flutter 3.3 an uncaught async error can be caught
    // without a guarded zone, so there is nothing for the app to restructure (ADR-0008).
    //
    // EdotErrorBoundary's own hook is deliberately not installed here. It claims it
    // while a boundary is mounted, so an app without one keeps the error display it
    // always had.
    installErrorHandlers();

    edotLog('agent started');
  }

  /// Creates spans. Available once [start] has completed.
  static EdotTracer get tracer {
    final tracer = _tracer;
    if (tracer == null) {
      throw StateError(
        'Edot.start must complete before creating spans. Telemetry produced '
        'before then is currently dropped rather than queued.',
      );
    }
    return tracer;
  }

  /// The screen currently visible to the user, or null when none is set.
  static active_view.EdotActiveView? get activeView => active_view.activeView;

  /// Records which screen the user is now on, so subsequent telemetry can be
  /// attributed to it.
  ///
  /// Navigation sets this for you. Call it yourself where switching screens pushes
  /// no route and so cannot be observed — bottom navigation bars and in-page
  /// switchers.
  ///
  /// Usable before [start]: the first screen is often visible before the Agent has
  /// finished starting, and requiring otherwise would force apps to sequence
  /// navigation behind telemetry.
  ///
  /// Each call is a fresh entry and gets its own identifier, including a repeat
  /// entry to a screen already named. Throws [ArgumentError] on a blank name.
  static void setActiveView(String name) => active_view.setActiveView(name);

  /// Forgets the Active View, for leaving all screens.
  ///
  /// Subsequent telemetry omits the screen attributes rather than reporting the
  /// last screen the user happened to be on.
  static void clearActiveView() => active_view.clearActiveView();

  /// Emits a structured log record.
  ///
  /// For events that are not operations. Fire-and-forget, like span creation
  /// (ADR-0002), so this does not await the Agent.
  ///
  /// [attributes] may hold `String`, `int`, `double` or `bool` values, and their
  /// types survive to the collector. Anything else throws [ArgumentError].
  ///
  /// The record also carries the current [activeView]'s screen attributes, unless
  /// [attributes] sets those keys itself — an explicit value from the caller wins,
  /// because otherwise the call would silently do nothing.
  ///
  /// Note that [flush] does **not** drain log records on iOS — see its
  /// documentation before relying on one having left the device.
  static void log(
    EdotSeverity severity,
    String message, {
    Map<String, Object> attributes = const {},
  }) {
    _requireStarted('emit a log record');

    sendOneWay('emitLog', <String, Object?>{
      'severity': severity.name,
      'message': message,
      'attributes': encodeLogAttributes({
        ...active_view.activeViewAttributes(),
        ...attributes,
      }),
    });
  }

  /// Reports an error the app caught and handled.
  ///
  /// For a failure the app dealt with but still wants to know about — a retry that gave
  /// up, a response that would not parse. Recorded exactly as an automatically captured
  /// Dart Error is, with `error.source` saying the app reported it, so both arrive in
  /// one place and neither counts towards crash-free rate (ADR-0008).
  ///
  /// Records against the operation in flight, if the caller established one with
  /// [EdotTracer.runWithParent].
  static void reportError(Object error, {StackTrace? stackTrace}) =>
      captureError(error, stackTrace, EdotErrorSource.dartReported);

  /// The port an isolate reports its errors to.
  ///
  /// Pass it to `Isolate.spawn`'s `onError` for a spawned isolate's uncaught errors to
  /// be captured. A spawned isolate reports only to the ports its spawner gave it, so
  /// this is the one thing an app has to wire up itself. `Isolate.run` and `compute`
  /// need nothing — their failures come back as a failed future.
  ///
  /// Null before [start].
  static SendPort? get isolateErrorPort => errors.isolateErrorPort;

  /// Records a metric value.
  ///
  /// One call rather than an instrument registry: [kind] selects the instrument,
  /// and the Agent's global meter provider owns it. Fire-and-forget, like [log].
  ///
  /// [attributes] are the metric's dimensions and are `String`-valued only. That
  /// is a hard limit of the pinned iOS Agent's legacy meter, not a simplification
  /// — see ADR-0012. Convert numeric dimensions at the call site.
  static void recordMetric(
    String name,
    num value, {
    EdotMetricKind kind = EdotMetricKind.counter,
    Map<String, String> attributes = const {},
  }) {
    _requireStarted('record a metric');

    sendOneWay('recordMetric', <String, Object?>{
      'name': name,
      // Always a double. The Agent's meter takes one, and sending a whole number
      // as an int would leave the native side inferring a type it cannot infer.
      'value': value.toDouble(),
      'metricType': kind.name,
      'attributes': attributes,
    });
  }

  static void _requireStarted(String action) {
    if (_tracer == null) {
      throw StateError('Edot.start must complete before you can $action.');
    }
  }

  /// Drains the Agent's in-memory buffers.
  ///
  /// This does **not** promise the telemetry has reached the collector. What it
  /// promises is that nothing is still sitting in a batch queue waiting on a
  /// timer. Where it goes next depends on the platform and on whether the
  /// Agent's durable buffer is in the way — see ADR-0011 for why neither pinned
  /// Agent can be made to promise more:
  ///
  /// - **Android, [EdotAndroidConfig.diskBufferingEnabled] false** — the spans
  ///   are on the wire before this future completes.
  /// - **Android, disk buffering enabled (the default)** — the spans reach the
  ///   disk buffer, and a periodic job uploads them afterwards.
  /// - **iOS** — the spans reach the Agent's on-disk buffer, which cannot be
  ///   disabled, and its own worker uploads them seconds later. There is no
  ///   configuration that makes flush upload synchronously.
  ///
  /// Which signals it reaches also differs:
  ///
  /// - **Android** — traces, log records and metrics.
  /// - **iOS** — traces only. The pinned logger provider exposes no flush and does
  ///   not surface its processor, and the Agent is still on the deprecated meter
  ///   provider, which has no flush either — its metrics leave on a 60-second
  ///   timer that cannot be forced (ADR-0011).
  ///
  /// Because of all of the above, do not build a shutdown path that assumes
  /// telemetry has left the device once this returns.
  static Future<void> flush() async {
    if (_tracer == null) {
      throw StateError('Edot.start must complete before flushing.');
    }
    await edotChannel.invokeMethod<void>('flush');
  }

  /// Clears state between tests. Does not stop the Agent.
  @visibleForTesting
  static void resetForTesting() {
    _tracer = null;
    debugLoggingEnabled = false;
    active_view.clearActiveView();
    clearTracingRules();
    uninstallHttpOverrides();
    uninstallErrorHandlers();
  }
}
