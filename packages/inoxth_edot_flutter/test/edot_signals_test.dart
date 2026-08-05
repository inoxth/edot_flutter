import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

/// The wire values read out of the React Native SDK, at
/// `github.com/inoxth/react-native-edot-sdk`:
///
/// - severities from `packages/react-native/src/NativeEdotReactNative.ts`
/// - metric kinds from `packages/react-native-tracer-provider/src/meter-provider.ts`
///
/// **Transcribed, not verified.** Nothing in this repo can reach that one, so these
/// lists record what those files said when they were read. The tests below prove
/// only that the Dart enums still agree with the transcription — a rename on the
/// React Native side would go undetected here, so re-read both files whenever
/// either fleet's names move.
const _reactNativeSeverities = <String>[
  'trace',
  'debug',
  'info',
  'warn',
  'error',
  'fatal',
];

const _reactNativeMetricKinds = <String>[
  'counter',
  'histogram',
  'upDownCounter',
];

/// Seam 1 — the channel contract for log records and metrics.
///
/// The method names and value shapes follow the React Native SDK's native module
/// (`emitLog`, `recordMetric`) so one Kibana dashboard serves both fleets.
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

  Future<void> startPlugin() async {
    await Edot.start(
      EdotConfig(
        serviceName: 'example-app',
        serviceVersion: '1.2.3',
        deploymentEnvironment: 'test',
        serverUrl: 'http://localhost:4318',
      ),
    );
    calls.clear();
  }

  /// Starts without clearing [calls], for the tests that assert on what was held
  /// before the start and replayed by it.
  Future<void> startPluginKeepingCalls() => Edot.start(
    EdotConfig(
      serviceName: 'example-app',
      serviceVersion: '1.2.3',
      deploymentEnvironment: 'test',
      serverUrl: 'http://localhost:4318',
    ),
  );

  Map<Object?, Object?> argumentsOf(MethodCall call) =>
      call.arguments as Map<Object?, Object?>;

  group('log records', () {
    test('sends severity, message and attributes', () async {
      await startPlugin();

      Edot.log(
        EdotSeverity.warn,
        'cart abandoned',
        attributes: {'cart.items': 3},
      );

      expect(calls.single.method, 'emitLog');
      final args = argumentsOf(calls.single);
      expect(args['severity'], 'warn');
      expect(args['message'], 'cart abandoned');
    });

    test(
      'severity wire values still agree with the transcribed list',
      () async {
        await startPlugin();

        for (final severity in EdotSeverity.values) {
          Edot.log(severity, 'message');
        }

        expect(
          calls.map((c) => argumentsOf(c)['severity']),
          _reactNativeSeverities,
        );
      },
    );

    test(
      'attributes carry their type, so an int does not become a double',
      () async {
        // Same reason span attributes are typed per method: on iOS a bare number is
        // an NSNumber and casts happily to either, so the type has to travel
        // alongside the value rather than being inferred from it.
        await startPlugin();

        Edot.log(
          EdotSeverity.info,
          'mixed',
          attributes: {
            'a.string': 'text',
            'a.int': 42,
            'a.double': 3.0,
            'a.bool': true,
          },
        );

        final attributes =
            argumentsOf(calls.single)['attributes']! as List<Object?>;
        expect(attributes.map((a) => (a! as Map<Object?, Object?>)['type']), [
          'string',
          'int',
          'double',
          'bool',
        ]);

        final tagged = attributes.map((a) => a! as Map<Object?, Object?>);

        final intAttribute = tagged.firstWhere((a) => a['key'] == 'a.int');
        expect(intAttribute['value'], isA<int>());
        expect(intAttribute['value'], isNot(isA<double>()));

        final doubleAttribute = tagged.firstWhere(
          (a) => a['key'] == 'a.double',
        );
        expect(doubleAttribute['value'], isA<double>());
      },
    );

    test('rejects an attribute type the wire cannot carry', () async {
      // Silently dropping it would lose data the caller believes was recorded.
      await startPlugin();

      expect(
        () => Edot.log(
          EdotSeverity.info,
          'bad',
          attributes: {
            'a.list': [1, 2],
          },
        ),
        throwsArgumentError,
      );
    });

    test('logging before start is held, then replayed once started', () async {
      Edot.log(EdotSeverity.info, 'too early');
      expect(calls, isEmpty, reason: 'the Agent cannot receive this yet');

      await startPluginKeepingCalls();

      final replayed = calls.where((c) => c.method == 'emitLog');
      expect(argumentsOf(replayed.single)['message'], 'too early');
    });
  });

  group('metrics', () {
    test('sends name, value, kind and attributes', () async {
      await startPlugin();

      Edot.recordMetric(
        'checkout.total',
        42.5,
        attributes: {'currency': 'THB'},
      );

      expect(calls.single.method, 'recordMetric');
      final args = argumentsOf(calls.single);
      expect(args['name'], 'checkout.total');
      expect(args['value'], 42.5);
      expect(args['attributes'], {'currency': 'THB'});
    });

    test('kind wire values still agree with the transcribed list', () async {
      await startPlugin();

      for (final kind in EdotMetricKind.values) {
        Edot.recordMetric('m', 1, kind: kind);
      }

      expect(
        calls.map((c) => argumentsOf(c)['metricType']),
        _reactNativeMetricKinds,
      );
    });

    test('defaults to a counter', () async {
      await startPlugin();

      Edot.recordMetric('m', 1);

      expect(argumentsOf(calls.single)['metricType'], 'counter');
    });

    test('the value crosses as a double even when whole', () async {
      // The Agent's meter takes a double. Sending 1 as an int would leave the
      // native side guessing, which is the trap the span attributes avoid.
      await startPlugin();

      Edot.recordMetric('m', 1);

      final value = argumentsOf(calls.single)['value'];
      expect(value, isA<double>());
      expect(value, 1.0);
    });

    test(
      'recording before start is held, then replayed once started',
      () async {
        Edot.recordMetric('m', 1);
        expect(calls, isEmpty, reason: 'the Agent cannot receive this yet');

        await startPluginKeepingCalls();

        final replayed = calls.where((c) => c.method == 'recordMetric');
        expect(argumentsOf(replayed.single)['name'], 'm');
      },
    );
  });
}
