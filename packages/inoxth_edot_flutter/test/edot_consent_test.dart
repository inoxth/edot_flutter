import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter/src/edot_emission.dart'
    show droppedBeforeStartAttribute, emissionBufferLimit;

/// The wire values read out of this organisation's React Native SDK, at
/// `github.com/inoxth/react-native-edot-sdk`,
/// `packages/react-native/src/types.ts`:
///
/// ```ts
/// export type TrackingConsent = 'granted' | 'not_granted' | 'pending';
/// ```
///
/// **Transcribed, not verified.** Nothing in this repo can reach that one, so this
/// records what that file said when it was read. A rename on the React Native side
/// would go undetected here — re-read it whenever either fleet's names move.
const _reactNativeConsentValues = <String>['granted', 'not_granted', 'pending'];

/// Seam 1 — the Tracking Consent gate and the queue for telemetry produced before
/// the Agent was ready.
///
/// Asserted at the channel because that is where the promise lives: telemetry the
/// user has not permitted must not reach the platform boundary at all. A test that
/// only checked no *export* happened would pass on an implementation that handed
/// refused telemetry to the Agent and asked it not to send — which is what this
/// Plugin deliberately does not do.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(edotChannelName), (
          call,
        ) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(edotChannelName), null);
    Edot.resetForTesting();
  });

  Future<void> startPlugin({
    EdotTrackingConsent consent = EdotTrackingConsent.granted,
    bool keepCalls = false,
  }) async {
    await Edot.start(
      EdotConfig(
        serviceName: 'example-app',
        serviceVersion: '1.2.3',
        deploymentEnvironment: 'test',
        serverUrl: 'http://localhost:4318',
        trackingConsent: consent,
      ),
    );
    if (!keepCalls) calls.clear();
  }

  Map<Object?, Object?> argumentsOf(MethodCall call) =>
      call.arguments as Map<Object?, Object?>;

  List<String> methodsCalled() => calls.map((c) => c.method).toList();

  /// Produces one of each signal, so a gate that only covers some is visible.
  ///
  /// All three because the gate exists once, at the channel, and the risk it is
  /// guarding against is a path that does not go through it. Spans, log records and
  /// metrics are the three paths there are.
  void emitEverySignal() {
    Edot.tracer.startSpan('operation').end();
    Edot.log(EdotSeverity.info, 'something happened');
    Edot.recordMetric('counter', 1);
  }

  group('the consent vocabulary', () {
    test('wire values still agree with the transcribed list', () {
      expect(
        EdotTrackingConsent.values.map((c) => c.wireValue),
        _reactNativeConsentValues,
      );
    });

    test('only granted allows emission', () {
      // The rule the whole gate rests on, asserted over every value rather than the
      // one that differs — a fourth state added later without a decision about it
      // would otherwise inherit whatever `allowsEmission` happened to do.
      expect(
        {
          for (final consent in EdotTrackingConsent.values)
            consent.wireValue: consent.allowsEmission,
        },
        {'granted': true, 'not_granted': false, 'pending': false},
      );
    });
  });

  group('with consent withheld', () {
    // AC: no spans, logs or metrics cross the channel; pending behaves as not granted.
    for (final consent in [
      EdotTrackingConsent.notGranted,
      EdotTrackingConsent.pending,
    ]) {
      test('${consent.wireValue} emits none of the three signals', () async {
        await startPlugin(consent: consent);

        emitEverySignal();
        // Drained, because a channel call is dispatched asynchronously: an assertion
        // in the same turn would find `calls` empty whether or not anything was sent.
        await Future<void>.delayed(Duration.zero);

        expect(calls, isEmpty);
      });
    }

    test(
      'the Agent is still initialised, so consent can be granted later',
      () async {
        // Consent gates telemetry, not the Agent. Refusing to initialise would mean a
        // later grant needed a restart to take effect, which AC 2 forbids — and would
        // conflate consent with `disableAgent`, which is a developer's switch.
        await startPlugin(
          consent: EdotTrackingConsent.pending,
          keepCalls: true,
        );

        expect(methodsCalled(), ['initialize']);
      },
    );

    test(
      'span enrichment and ending are withheld too, not just creation',
      () async {
        // Every span method is its own channel call, so a gate on creation alone would
        // let a span's attributes and its end cross for a span that never existed.
        await startPlugin(consent: EdotTrackingConsent.notGranted);

        final span = Edot.tracer.startSpan('operation')
          ..setString('key', 'value')
          ..setInt('count', 1)
          ..recordException(StateError('bad'))
          ..markFailed('failed');
        span.end();
        await Future<void>.delayed(Duration.zero);

        expect(calls, isEmpty);
      },
    );

    test('a reported error is withheld', () async {
      // Errors are log records (ADR-0008), so they go through the same gate — but they
      // are the signal most likely to be given an exception "because it matters", and
      // an exception here would be telemetry the user refused.
      await startPlugin(consent: EdotTrackingConsent.notGranted);

      Edot.reportError(StateError('something failed'));
      await Future<void>.delayed(Duration.zero);

      expect(calls, isEmpty);
    });
  });

  group('changing consent at runtime', () {
    // AC: granting at runtime resumes emission without a restart.
    test('granting resumes emission', () async {
      await startPlugin(consent: EdotTrackingConsent.pending);

      Edot.setTrackingConsent(EdotTrackingConsent.granted);
      Edot.log(EdotSeverity.info, 'now permitted');
      await Future<void>.delayed(Duration.zero);

      expect(methodsCalled(), ['emitLog']);
    });

    // AC: withdrawing at runtime stops emission immediately.
    test('withdrawing stops emission from the very next call', () async {
      await startPlugin();

      Edot.log(EdotSeverity.info, 'permitted');
      Edot.setTrackingConsent(EdotTrackingConsent.notGranted);
      Edot.log(EdotSeverity.info, 'no longer permitted');
      await Future<void>.delayed(Duration.zero);

      // Immediately means immediately: the record before the withdrawal is kept, and
      // the one after it is not. Anything queued or batched would blur that boundary.
      expect(methodsCalled(), ['emitLog']);
      expect(argumentsOf(calls.single)['message'], 'permitted');
    });

    test('the current consent is readable', () async {
      await startPlugin();
      expect(Edot.trackingConsent, EdotTrackingConsent.granted);

      Edot.setTrackingConsent(EdotTrackingConsent.pending);

      // Readable so an app can render its own privacy screen from one source of truth,
      // rather than keeping a second copy that can disagree with this one.
      expect(Edot.trackingConsent, EdotTrackingConsent.pending);
    });

    test('what was refused is not released by a later grant', () async {
      Edot.setTrackingConsent(EdotTrackingConsent.notGranted);
      Edot.log(EdotSeverity.info, 'produced while refused');

      // Started *with consent granted*, which is the moment a queue that had held the
      // refused record would flush it. Consent is not retroactive: a later yes permits
      // future telemetry, it does not license what was collected during the no — so the
      // refusal has to discard, not defer.
      await startPlugin(consent: EdotTrackingConsent.granted, keepCalls: true);
      await Future<void>.delayed(Duration.zero);

      expect(methodsCalled(), ['initialize']);
    });

    test('consent settled before start is honoured by start', () async {
      Edot.setTrackingConsent(EdotTrackingConsent.notGranted);

      // Deliberately not overridden by the config's default. An app that resolved
      // consent from storage before starting would otherwise have that answer silently
      // replaced by `granted` at the moment the Agent came up.
      await startPlugin(consent: EdotTrackingConsent.notGranted);

      Edot.log(EdotSeverity.info, 'still refused');
      await Future<void>.delayed(Duration.zero);

      expect(calls, isEmpty);
    });
  });

  group('telemetry produced before the Agent is ready', () {
    // AC: replayed in its original order.
    test('is replayed in the order it was produced', () async {
      final span = Edot.tracer.startSpan('early');
      Edot.log(EdotSeverity.info, 'early record');
      span.end();
      Edot.recordMetric('early.counter', 1);

      expect(calls, isEmpty, reason: 'the Agent cannot receive these yet');

      await startPlugin(keepCalls: true);
      await Future<void>.delayed(Duration.zero);

      // Order is the assertion, not merely arrival: the Agent builds a span from a
      // start and an end, so a replay that reordered them would produce a span that
      // ended before it began — or no span at all.
      expect(methodsCalled(), [
        'initialize',
        'spanStart',
        'emitLog',
        'spanEnd',
        'recordMetric',
      ]);
    });

    test('a held span keeps the timestamps it had, not the replay time', () async {
      final before = DateTime.now().toUtc().microsecondsSinceEpoch;
      final span = Edot.tracer.startSpan('early');
      span.end();
      final afterSpan = DateTime.now().toUtc().microsecondsSinceEpoch;

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await startPlugin(keepCalls: true);

      final started = calls.singleWhere((c) => c.method == 'spanStart');
      final ended = calls.singleWhere((c) => c.method == 'spanEnd');

      // Held telemetry that was stamped on arrival would report a duration of nearly
      // nothing, at the wrong moment — and the reason ADR-0005 puts timestamps in Dart
      // is precisely so that the queue cannot distort them.
      expect(
        argumentsOf(started)['startUs'] as int,
        inInclusiveRange(before, afterSpan),
      );
      expect(
        argumentsOf(ended)['endUs'] as int,
        inInclusiveRange(before, afterSpan),
      );
    });

    test('is discarded rather than replayed when consent withholds it', () async {
      Edot.log(EdotSeverity.info, 'produced before consent was known');

      await startPlugin(
        consent: EdotTrackingConsent.notGranted,
        keepCalls: true,
      );
      await Future<void>.delayed(Duration.zero);

      // Not held for a later yes. Telemetry collected before the user refused is not
      // made acceptable by their changing their mind afterwards, so a grant must not
      // release it.
      expect(methodsCalled(), ['initialize']);

      Edot.setTrackingConsent(EdotTrackingConsent.granted);
      await Future<void>.delayed(Duration.zero);

      expect(methodsCalled(), ['initialize']);
    });

    test('is discarded the moment consent is withdrawn, before any start', () async {
      Edot.log(EdotSeverity.info, 'produced while consent was unknown');
      Edot.setTrackingConsent(EdotTrackingConsent.notGranted);
      Edot.setTrackingConsent(EdotTrackingConsent.granted);

      await startPlugin(keepCalls: true);
      await Future<void>.delayed(Duration.zero);

      // Discarded when the refusal arrived, not merely filtered at replay — so
      // re-granting cannot bring it back. Keeping it would mean a refusal left the
      // data sitting in memory, which is not what a user who declined would expect.
      expect(methodsCalled(), ['initialize']);
    });
  });

  group('when the queue overflows', () {
    // AC: the oldest are dropped, and the dropped count is surfaced as an attribute.
    test('the oldest are dropped and the newest survive', () async {
      for (var i = 0; i < emissionBufferLimit + 10; i++) {
        Edot.log(EdotSeverity.info, 'record $i');
      }

      await startPlugin(keepCalls: true);

      final messages = calls
          .where((c) => c.method == 'emitLog')
          .map((c) => argumentsOf(c)['message'])
          .toList();

      // The ten oldest are gone and the limit's worth of newest remain, plus the
      // Plugin's own report of the loss. Dropping newest instead would mean a burst
      // hid everything that followed it, which is the opposite of useful.
      expect(messages, hasLength(emissionBufferLimit + 1));
      expect(messages, isNot(contains('record 0')));
      expect(messages, contains('record 10'));
      expect(messages, contains('record ${emissionBufferLimit + 9}'));
    });

    test('the dropped count is reported as telemetry', () async {
      for (var i = 0; i < emissionBufferLimit + 10; i++) {
        Edot.log(EdotSeverity.info, 'record $i');
      }

      await startPlugin(keepCalls: true);

      final report = calls.lastWhere((c) => c.method == 'emitLog');
      final attributes = argumentsOf(report)['attributes']! as List<Object?>;
      final dropped = attributes.cast<Map<Object?, Object?>>().singleWhere(
        (a) => a['key'] == droppedBeforeStartAttribute,
      );

      // A bound nobody can see is indistinguishable from an app that was quiet
      // (ADR-0005), so the loss is itself telemetry rather than a debug line.
      expect(dropped['value'], 10);
      expect(argumentsOf(report)['severity'], 'warn');
    });

    test('nothing is reported when nothing was dropped', () async {
      Edot.log(EdotSeverity.info, 'the only record');

      await startPlugin(keepCalls: true);

      // Otherwise every start would carry a report of zero loss, and the attribute
      // would stop meaning anything the moment someone searched for it.
      final records = calls.where((c) => c.method == 'emitLog');
      expect(records, hasLength(1));
      expect(argumentsOf(records.single)['message'], 'the only record');
    });

    test('the loss report is withheld when consent withholds it', () async {
      for (var i = 0; i < emissionBufferLimit + 10; i++) {
        Edot.log(EdotSeverity.info, 'record $i');
      }

      await startPlugin(
        consent: EdotTrackingConsent.notGranted,
        keepCalls: true,
      );
      await Future<void>.delayed(Duration.zero);

      // The report is telemetry too. Emitting it under a refusal would leak the fact
      // that the app was producing telemetry, and how much, which is exactly the kind
      // of thing consent is withheld to prevent.
      expect(methodsCalled(), ['initialize']);
    });
  });
}
