import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter/src/edot_config.dart' show encodeConfig;

/// Seam 1 — the platform-scoped configuration blocks and the Session identifier.
///
/// Each option is thin on its own and they all follow one path: a Dart field reaches the
/// platform's Agent builder. What is worth asserting here is that path — that the option
/// crosses the channel under the name the native side reads, and that it is scoped to the
/// platform it applies to. Whether the Agent then honours it is Seam 2's question.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  String? sessionIdReply;
  Object? sessionIdError;

  setUp(() {
    calls.clear();
    sessionIdReply = null;
    sessionIdError = null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(edotChannelName), (
          call,
        ) async {
          calls.add(call);

          if (call.method == 'sessionId') {
            if (sessionIdError != null) throw sessionIdError!;
            return sessionIdReply;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(edotChannelName), null);
    Edot.resetForTesting();
  });

  EdotConfig configWith({
    EdotIosConfig ios = const EdotIosConfig(),
    EdotAndroidConfig android = const EdotAndroidConfig(),
    bool disableAgent = false,
    bool debug = false,
    EdotAuth auth = const EdotAuth.none(),
  }) => EdotConfig(
    serviceName: 'example-app',
    serviceVersion: '1.2.3',
    deploymentEnvironment: 'test',
    serverUrl: 'https://apm.example.com:4318',
    ios: ios,
    android: android,
    disableAgent: disableAgent,
    debug: debug,
    auth: auth,
  );

  Map<String, Object?> blockOf(EdotConfig config, String platform) =>
      encodeConfig(config)[platform]! as Map<String, Object?>;

  group('the iOS block', () {
    test('defaults to what the Agent does on its own', () {
      // Which is also what this organisation's React Native SDK gets, because it passes a
      // bare instrumentation configuration. An app that sets none of these behaves as the
      // React Native fleet does, so offering the toggles costs no Fleet Alignment.
      expect(blockOf(configWith(), 'ios'), {
        'crashReportingEnabled': true,
        'systemMetricsEnabled': true,
        'appMetricsEnabled': true,
        'lifecycleEventsEnabled': true,
      });
    });

    test('carries each option across the channel', () {
      // Every field, not a sample: a passthrough that is dropped in the encoder is a
      // silent no-op, which is the one failure mode this whole ticket exists to prevent.
      expect(
        blockOf(
          configWith(
            ios: const EdotIosConfig(
              crashReportingEnabled: false,
              systemMetricsEnabled: false,
              appMetricsEnabled: false,
              lifecycleEventsEnabled: false,
            ),
          ),
          'ios',
        ),
        {
          'crashReportingEnabled': false,
          'systemMetricsEnabled': false,
          'appMetricsEnabled': false,
          'lifecycleEventsEnabled': false,
        },
      );
    });

    test('is where native crash reporting is opted out of', () {
      // An opt-out rather than an opt-in, matching the React Native SDK (ADR-0009) even
      // though off-by-default would be the safer choice — both fleets must report crashes
      // identically, and this is the direction that achieves it.
      expect(
        blockOf(
          configWith(ios: const EdotIosConfig(crashReportingEnabled: false)),
          'ios',
        )['crashReportingEnabled'],
        isFalse,
      );
    });
  });

  group('platform scope', () {
    test('the Android block holds only Android options', () {
      // The exact key set, so an option added to the wrong block fails here. Native crash
      // reporting is the one that matters: Android's Agent installs whatever
      // instrumentation is on the classpath with no runtime switch, so a toggle here could
      // only ever be a field that does nothing (ADR-0009).
      expect(blockOf(configWith(), 'android').keys, ['diskBufferingEnabled']);
    });

    test('the iOS block holds no Android options', () {
      // Disk buffering is the asymmetric one in the other direction: the pinned iOS Agent
      // persists unconditionally and cannot be told not to, so there is nothing to expose.
      expect(
        blockOf(configWith(), 'ios').keys,
        isNot(contains('diskBufferingEnabled')),
      );
    });

    test('the two blocks share no option', () {
      final android = blockOf(configWith(), 'android').keys.toSet();
      final ios = blockOf(configWith(), 'ios').keys.toSet();

      expect(android.intersection(ios), isEmpty);
    });
  });

  group('debug logging', () {
    test('never emits a credential', () async {
      // The startup line reports the whole configuration, which is what makes it useful
      // and what makes it dangerous: a debug log reaches a terminal, a CI artefact and
      // sometimes a bug report.
      final printed = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      addTearDown(() => debugPrint = previous);

      await Edot.start(
        configWith(debug: true, auth: const EdotAuth.apiKey('an-api-key')),
      );

      expect(printed, isNotEmpty, reason: 'debug logging produced nothing');
      expect(printed.join('\n'), isNot(contains('an-api-key')));
      expect(printed.join('\n'), contains('apiKey(redacted)'));
    });

    test('reports both platform blocks', () async {
      // They are the first thing to check when telemetry is missing on one platform and
      // present on the other, and a report that omitted them would send someone to the
      // collector instead.
      final printed = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      addTearDown(() => debugPrint = previous);

      await Edot.start(
        configWith(
          debug: true,
          ios: const EdotIosConfig(crashReportingEnabled: false),
          android: const EdotAndroidConfig(diskBufferingEnabled: false),
        ),
      );

      final output = printed.join('\n');
      expect(output, contains('crashReportingEnabled: false'));
      expect(output, contains('diskBufferingEnabled: false'));
    });

    test('emits nothing when it is off', () async {
      final printed = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      addTearDown(() => debugPrint = previous);

      await Edot.start(configWith());

      expect(printed, isEmpty);
    });
  });

  group('disabling the Agent', () {
    test('is what crosses the channel, for the native side to act on', () {
      // Dart cannot honour this on its own: the Agent is what holds the export pipeline,
      // so the decision has to reach it. Seam 2 is where the silence is asserted.
      expect(
        encodeConfig(configWith(disableAgent: true))['disableAgent'],
        isTrue,
      );
      expect(encodeConfig(configWith())['disableAgent'], isFalse);
    });
  });

  group('the Session identifier', () {
    test('is what the Agent answered', () async {
      await Edot.start(configWith());
      sessionIdReply = 'a-session-uuid';

      expect(await Edot.currentSessionId(), 'a-session-uuid');
    });

    test('is asked for by name, and nothing else is sent', () async {
      // No arguments: the Agent knows its own Session, and anything Dart passed could only
      // disagree with it.
      await Edot.start(configWith());
      calls.clear();

      await Edot.currentSessionId();

      expect(calls.single.method, 'sessionId');
      expect(calls.single.arguments, isNull);
    });

    test('is empty when the platform has none to give', () async {
      // Android, where the Agent exposes its session manager only as internal, explicitly
      // unstable API (ADR-0001). Empty rather than null, so a support screen has one
      // absent case to handle rather than two.
      await Edot.start(configWith());
      sessionIdReply = null;

      expect(await Edot.currentSessionId(), isEmpty);
    });

    test('is empty rather than throwing when the call fails', () async {
      // A support screen asking for an identifier must not be the thing that breaks.
      await Edot.start(configWith());
      sessionIdError = PlatformException(code: 'boom');

      expect(await Edot.currentSessionId(), isEmpty);
    });

    test('is empty before start, without throwing', () async {
      // Unlike the telemetry calls, which throw before start. A support screen should be
      // able to ask without knowing whether telemetry was ever switched on.
      expect(await Edot.currentSessionId(), isEmpty);
    });
  });
}
