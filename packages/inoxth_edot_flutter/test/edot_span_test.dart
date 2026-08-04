import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

/// Seam 1 — the platform channel.
///
/// The ordered sequence of channel calls is the Plugin's contract with both
/// native implementations, so these tests assert that sequence and nothing about
/// how the Dart side is structured internally.
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

  Future<void> startPlugin() => Edot.start(
    EdotConfig(
      serviceName: 'example-app',
      serviceVersion: '1.2.3',
      deploymentEnvironment: 'test',
      serverUrl: 'http://localhost:4318',
      auth: const EdotAuth.apiKey('key'),
    ),
  );

  group('debug logging', () {
    test('never emits a credential, even with debug enabled', () async {
      // Asserting on the log rather than on EdotConfig.toString: redaction is
      // only worth anything at the point the text actually escapes the process,
      // and debug mode is exactly when a credential would leak.
      final printed = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');

      addTearDown(() => debugPrint = previous);

      await Edot.start(
        EdotConfig(
          serviceName: 'example-app',
          serviceVersion: '1.2.3',
          deploymentEnvironment: 'test',
          serverUrl: 'http://localhost:4318',
          auth: const EdotAuth.apiKey('super-secret-key'),
          debug: true,
        ),
      );

      expect(printed, isNotEmpty, reason: 'debug mode must log something');
      expect(printed.join('\n'), isNot(contains('super-secret-key')));
    });
  });

  group('initialisation', () {
    test('sends initialize with the configured identity', () async {
      await startPlugin();

      expect(calls.single.method, 'initialize');
      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args['serviceName'], 'example-app');
      expect(args['serviceVersion'], '1.2.3');
      expect(args['deploymentEnvironment'], 'test');
      expect(args['serverUrl'], 'http://localhost:4318');
    });

    test('sends the Collector Host for the self-tracing exclusion', () async {
      // ADR-0006 needs one agreed host on both sides. Deriving it natively as
      // well would risk the two disagreeing, and a host they disagree about is
      // exactly the self-tracing leak the exclusion exists to prevent.
      await startPlugin();

      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args['collectorHost'], 'localhost');
    });

    test(
      'passes the credential through so authentication actually works',
      () async {
        // Redaction applies to human-readable output only; stripping the
        // credential here would silently disable authentication.
        await startPlugin();

        final args = calls.single.arguments as Map<Object?, Object?>;
        expect(args['apiKey'], 'key');
        expect(args['secretToken'], isNull);
      },
    );

    test('creating a span before start throws rather than dropping it', () {
      // Silently discarding telemetry would be indistinguishable from a quiet
      // app. The pre-initialisation buffer ticket replaces this with queueing.
      expect(() => Edot.tracer.startSpan('too-early'), throwsStateError);
    });

    test(
      'starting twice throws rather than silently re-initialising',
      () async {
        await startPlugin();
        await expectLater(startPlugin, throwsStateError);
      },
    );
  });

  group('span lifecycle', () {
    test('emits spanStart then spanEnd sharing one shadow id', () async {
      await startPlugin();
      calls.clear();

      final span = Edot.tracer.startSpan('checkout');
      expect(calls.single.method, 'spanStart');
      final startArgs = calls.single.arguments as Map<Object?, Object?>;

      span.end();
      expect(calls.map((c) => c.method), ['spanStart', 'spanEnd']);
      final endArgs = calls.last.arguments as Map<Object?, Object?>;

      expect(startArgs['name'], 'checkout');
      expect(startArgs['shadowId'], isNotEmpty);
      expect(endArgs['shadowId'], startArgs['shadowId']);
    });

    test('distinct spans get distinct shadow ids', () async {
      await startPlugin();
      calls.clear();

      Edot.tracer.startSpan('a');
      Edot.tracer.startSpan('b');

      final ids = calls
          .map((c) => (c.arguments as Map<Object?, Object?>)['shadowId'])
          .toSet();
      expect(ids, hasLength(2));
    });

    test('neither start nor end awaits the Agent', () async {
      // ADR-0002: span start and end are fire-and-forget. If either awaited a
      // reply, hot paths and synchronous build/paint callbacks could not use them.
      await startPlugin();
      calls.clear();

      final span = Edot.tracer.startSpan('sync');
      // The call has already been dispatched with no intervening await.
      expect(calls, hasLength(1));
      span.end();
      expect(calls, hasLength(2));
    });

    test(
      'ending twice is ignored rather than emitting a second spanEnd',
      () async {
        await startPlugin();
        final span = Edot.tracer.startSpan('once');
        calls.clear();

        span.end();
        span.end();

        expect(calls.where((c) => c.method == 'spanEnd'), hasLength(1));
      },
    );
  });

  group('timestamps', () {
    test('carries start and end timestamps in microseconds', () async {
      await startPlugin();
      calls.clear();

      final span = Edot.tracer.startSpan('timed');
      span.end();

      final startUs =
          (calls.first.arguments as Map<Object?, Object?>)['startUs'] as int;
      final endUs =
          (calls.last.arguments as Map<Object?, Object?>)['endUs'] as int;

      expect(startUs, greaterThan(0));
      expect(endUs, greaterThanOrEqualTo(startUs));
      // Sanity-check the unit: microseconds since epoch is ~1.7e15 in 2026.
      expect(startUs, greaterThan(1600000000000000));
    });

    test(
      'duration comes from elapsed time, not from a second clock reading',
      () async {
        // ADR-0005: the end timestamp is derived from the anchored start plus a
        // monotonic elapsed measurement, so a wall-clock jump mid-span cannot
        // distort the duration. Here the clock leaps an hour between the two
        // readings while only 50ms actually elapses.
        await startPlugin();
        calls.clear();

        final base = DateTime.utc(2026, 1, 1, 12);
        var reading = 0;
        final tracer = EdotTracer.withClock(
          () => reading++ == 0 ? base : base.add(const Duration(hours: 1)),
          () => const Duration(milliseconds: 50),
        );

        tracer.startSpan('jumpy').end();

        final startUs =
            (calls.first.arguments as Map<Object?, Object?>)['startUs'] as int;
        final endUs =
            (calls.last.arguments as Map<Object?, Object?>)['endUs'] as int;

        expect(startUs, base.microsecondsSinceEpoch);
        expect(
          endUs - startUs,
          const Duration(milliseconds: 50).inMicroseconds,
          reason:
              'the one-hour wall-clock jump must not appear in the duration',
        );
      },
    );
  });

  group('flush', () {
    test('sends flush and awaits the Agent', () async {
      await startPlugin();
      calls.clear();

      await Edot.flush();

      expect(calls.single.method, 'flush');
    });

    test('flushing before start throws rather than pretending to succeed', () {
      expect(Edot.flush, throwsStateError);
    });
  });
}
