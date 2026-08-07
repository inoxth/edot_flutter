import 'dart:isolate';

import 'package:flutter/widgets.dart';

import 'edot_active_view.dart' as active_view;
import 'edot_channel.dart';
import 'edot_consent.dart';
import 'edot_emission.dart' as emission;
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
import 'edot_view_claims.dart';

/// Entry point to the Plugin.
///
/// Call [start] once, early in `main`, then use [tracer] to create spans.
///
/// Static rather than an injected instance because the Agent underneath is itself
/// a process-wide singleton on both platforms — modelling it as anything else
/// would imply an independence that does not exist.
abstract final class Edot {
  static EdotTracer? _tracer;
  static bool _started = false;

  /// The Screen Span still waiting for its frame, if any.
  ///
  /// Global rather than per-observer, so a route navigation and an in-page switch
  /// share one in-flight transition and cannot leave two competing spans open.
  static EdotSpan? _pendingViewSpan;

  /// Whether [start] has completed.
  ///
  /// Tracked separately from [_tracer] now that the tracer is available before the
  /// Agent is: telemetry produced early is held rather than refused, so the presence
  /// of a tracer no longer means the Agent is running.
  static bool get isStarted => _started;

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
    if (_started) {
      throw StateError(
        'Edot.start has already been called. Starting twice would leave two '
        'export pipelines running.',
      );
    }

    debugLoggingEnabled = config.debug;
    edotLog('starting agent: $config');

    // Before the Agent is told anything, so telemetry held from before this call is
    // judged by the consent the app is starting with — and discarded rather than
    // replayed when that consent withholds it.
    emission.setTrackingConsent(config.trackingConsent);

    await edotChannel.invokeMethod<void>('initialize', encodeConfig(config));

    _started = true;
    _tracer ??= EdotTracer();
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

    // Last, so everything above is in place before the held telemetry moves: the
    // Agent is initialised and can receive it, and the rules that decide what gets
    // traced are set.
    sendBufferedEmissions();
    _reportHeldTelemetryLoss();

    edotLog('agent started');
  }

  /// Reports how much held telemetry the buffer had to drop, if any.
  ///
  /// As telemetry of its own, because a bound nobody can see is indistinguishable
  /// from an app that was quiet (ADR-0005). Emitted after the replay so it cannot be
  /// the thing that pushes the buffer over its own limit.
  static void _reportHeldTelemetryLoss() {
    final dropped = emission.droppedEmissionCount;
    if (dropped == 0) return;

    emission.clearDroppedEmissionCount();

    log(
      EdotSeverity.warn,
      'telemetry produced before Edot.start exceeded the buffer and was dropped',
      attributes: <String, Object>{
        emission.droppedBeforeStartAttribute: dropped,
      },
    );
  }

  /// Creates spans.
  ///
  /// Usable before [start]: spans produced then are held and replayed once the Agent
  /// is running (ADR-0005). Their timestamps are captured when they happen, not when
  /// they are replayed, so an early span's duration is its real one.
  static EdotTracer get tracer => _tracer ??= EdotTracer();

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

  /// Enters a view: moves the Active View to [name] and emits its Screen Span.
  ///
  /// What a navigation does, made callable directly. It sets the Active View — so
  /// every span and log that follows is attributed to the new screen — and starts a
  /// `"<name> - view appearing"` Screen Span that ends on the next frame, measuring
  /// what the user waited for. The span carries `last.screen.name` when the view
  /// actually changed, so a dashboard answers "where did the user come from" for an
  /// in-page switch exactly as it does for a route (ADR-0004).
  ///
  /// Use it for a view change that pushes no route and so cannot be observed — a
  /// bottom navigation bar, a `PageView`, an `IndexedStack`. [EdotNavigatorObserver]
  /// is built on this, so a route navigation and an in-page switch produce an
  /// identical Screen Span through one path. For attribution without a transition —
  /// re-tagging telemetry without measuring a switch — use [setActiveView] instead.
  ///
  /// Each call is a fresh entry with its own identifier, including a repeat entry to
  /// a screen already named, because two entries can legitimately share a Screen
  /// Name (`/orders/1` and `/orders/2`). De-duplicating no-op switches is therefore
  /// the caller's job — the observer does it by route, an in-page observer by index.
  /// Throws [ArgumentError] on a blank name.
  ///
  /// A faster switch that overtakes this one before its frame ends this span rather
  /// than leaving it open. Usable before [start]: the span is held and replayed
  /// (ADR-0005).
  static void enterView(String name) {
    // The Active View rather than the last route seen: an in-page switch moves the
    // view with no route changing, so reading routes would name a screen the user
    // left two changes ago.
    final from = active_view.activeView?.name;

    // Before the span starts, so it carries the same `screen.id` every later span on
    // this screen will — what lets a dashboard join a screen's telemetry to the
    // transition that opened it. Throws on a blank name before anything else happens,
    // leaving any in-flight transition untouched.
    active_view.setActiveView(name);

    // Whatever the previous transition was measuring is over: the user has left.
    _pendingViewSpan?.end();

    final span = tracer.startSpan(
      '$name - view appearing',
      attributes: <String, String>{
        // Fleet Alignment: the React Native SDK sets this on its own Screen Spans.
        // Omitted when the screen has not changed — naming the screen the user is
        // already on answers nothing.
        if (from != null && from != name) 'last.screen.name': from,
      },
    );
    _pendingViewSpan = span;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Only if it is still the transition in flight. A switch that overtook this one
      // has already ended it, and ending the span that replaced it would report the
      // wrong duration for the wrong screen.
      if (!identical(_pendingViewSpan, span)) return;

      span.end();
      _pendingViewSpan = null;
    });
  }

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
    sendOneWay('emitLog', <String, Object?>{
      'severity': severity.name,
      // Stamped here rather than on arrival, for the same reason spans are (ADR-0005)
      // — and it matters more for a record than a span, because a record held before
      // start would otherwise be dated when the Agent replayed it.
      'timestampUs': DateTime.now().toUtc().microsecondsSinceEpoch,
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

  /// The Session identifier the Agent is stamping onto telemetry right now.
  ///
  /// For a support screen, so a user can read out the identifier that finds their
  /// telemetry in Kibana. It is the same value as the `session.id` attribute on
  /// everything the Agent is currently exporting.
  ///
  /// **Empty on Android.** Its Agent exposes the session manager only as internal,
  /// explicitly-unstable API (ADR-0001), so there is nothing to read. A support
  /// screen must therefore handle an empty answer rather than displaying it — this
  /// organisation's React Native SDK has the same gap for the same reason, and the
  /// two will regain it together if the Agent ever publishes an accessor.
  ///
  /// Reading this does not extend the Session. The iOS Agent's accessor refreshes
  /// the inactivity timer by default, which would mean looking at a support screen
  /// kept a Session alive — so the Plugin asks it not to.
  ///
  /// Empty before [start] too, rather than throwing: a support screen should be
  /// able to ask without knowing whether telemetry was ever switched on.
  static Future<String> currentSessionId() async =>
      (await fetchString('sessionId')) ?? '';

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
    sendOneWay('recordMetric', <String, Object?>{
      'name': name,
      // Always a double. The Agent's meter takes one, and sending a whole number
      // as an int would leave the native side inferring a type it cannot infer.
      'value': value.toDouble(),
      'metricType': kind.name,
      'attributes': attributes,
    });
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
  ///   are on the wire before this future completes, *once the Agent's exporter gate
  ///   has opened*. For roughly the first **3 seconds** after [start] that gate
  ///   enqueues telemetry instead of exporting it and reports success regardless, so a
  ///   flush in that window completes with the telemetry still on the device. An app
  ///   that starts the Agent, emits and is killed inside that window loses it, and
  ///   there is no configuration or API that shortens the wait (ADR-0011).
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
    if (!_started) {
      throw StateError('Edot.start must complete before flushing.');
    }
    await edotChannel.invokeMethod<void>('flush');
  }

  /// The user's Tracking Consent right now.
  ///
  /// [EdotTrackingConsent.granted] until told otherwise, matching the React Native
  /// SDK — see [EdotConfig.trackingConsent] before relying on that default.
  static EdotTrackingConsent get trackingConsent => emission.trackingConsent;

  /// Records the user's Tracking Consent, in effect from the very next emission.
  ///
  /// Call this when the user answers a permission prompt, and whenever they change
  /// the answer. No restart is needed in either direction, and nothing is queued for
  /// a later yes: telemetry the app produces while consent withholds emission is
  /// discarded, because a later grant does not make it acceptable to have collected.
  ///
  /// Withdrawing consent cannot retract telemetry already exported. That has left the
  /// device and the Plugin has no way to reach it — deleting it is a matter for
  /// whoever administers the Elastic cluster.
  ///
  /// Usable before [start], so an app can settle consent before any telemetry exists.
  static void setTrackingConsent(EdotTrackingConsent consent) =>
      emission.setTrackingConsent(consent);

  /// Clears state between tests. Does not stop the Agent.
  @visibleForTesting
  static void resetForTesting() {
    _tracer = null;
    _started = false;
    _pendingViewSpan = null;
    emission.resetEmissionGate();
    debugLoggingEnabled = false;
    active_view.clearActiveView();
    clearViewClaims();
    clearTracingRules();
    uninstallHttpOverrides();
    uninstallErrorHandlers();
  }
}
