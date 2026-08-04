import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

/// Seam 1 — the channel contract for span enrichment.
///
/// The reason attributes cross as four distinct methods rather than one
/// loosely-typed one is iOS: Flutter delivers numbers as `NSNumber`, and
/// `NSNumber(value: 3.0) as? Int` succeeds just as `NSNumber(value: 3) as? Double`
/// does. A single method could not tell an integer from a double, so an integer
/// would land as a floating-point attribute and stop being aggregatable. These
/// tests pin the distinction at the boundary where it is still recoverable.
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

  Future<EdotSpan> startSpan() async {
    await Edot.start(
      EdotConfig(
        serviceName: 'example-app',
        serviceVersion: '1.2.3',
        deploymentEnvironment: 'test',
        serverUrl: 'http://localhost:4318',
      ),
    );
    final span = Edot.tracer.startSpan('enriched');
    calls.clear();
    return span;
  }

  Map<Object?, Object?> argumentsOf(MethodCall call) =>
      call.arguments as Map<Object?, Object?>;

  group('typed attributes', () {
    test('each type uses its own channel method', () async {
      final span = await startSpan();

      span
        ..setString('probe.string', 'text')
        ..setInt('probe.int', 42)
        ..setDouble('probe.double', 1.5)
        ..setBool('probe.bool', true);

      expect(calls.map((c) => c.method), [
        'spanSetString',
        'spanSetInt',
        'spanSetDouble',
        'spanSetBool',
      ]);
    });

    test('carries the key, the value and the owning shadow id', () async {
      final span = await startSpan();

      span.setString('probe.string', 'text');

      final args = argumentsOf(calls.single);
      expect(args['shadowId'], span.shadowId);
      expect(args['key'], 'probe.string');
      expect(args['value'], 'text');
    });

    test('an integer value stays an int on the channel', () async {
      // The whole point of the typed methods. If this arrives as 42.0 the native
      // side has no way to recover the distinction.
      final span = await startSpan();

      span.setInt('probe.int', 42);

      final value = argumentsOf(calls.single)['value'];
      expect(value, isA<int>());
      expect(value, isNot(isA<double>()));
      expect(value, 42);
    });

    test('a whole-number double stays a double on the channel', () async {
      // The mirror image, and the easier one to get wrong: 3.0 must not be
      // narrowed to 3 on its way out.
      final span = await startSpan();

      span.setDouble('probe.double', 3.0);

      final value = argumentsOf(calls.single)['value'];
      expect(value, isA<double>());
      expect(value, 3.0);
    });

    test('setting an attribute after end is ignored', () async {
      // The Agent has already dropped the span from its registry, so this could
      // only produce a warning there. Dart is where it can be dropped quietly.
      final span = await startSpan();
      span.end();
      calls.clear();

      span.setString('probe.late', 'value');

      expect(calls, isEmpty);
    });
  });

  group('recorded exceptions', () {
    test('sends type, message and stack trace', () async {
      final span = await startSpan();

      span.recordException(
        FormatException('bad input'),
        stackTrace: StackTrace.fromString('#0 somewhere'),
      );

      expect(calls.single.method, 'spanRecordException');
      final args = argumentsOf(calls.single);
      expect(args['shadowId'], span.shadowId);
      expect(args['type'], 'FormatException');
      expect(args['message'], contains('bad input'));
      expect(args['stacktrace'], contains('somewhere'));
    });

    test(
      'a missing stack trace is sent as null, not as the string "null"',
      () async {
        final span = await startSpan();

        span.recordException(StateError('no trace'));

        expect(argumentsOf(calls.single)['stacktrace'], isNull);
      },
    );

    test('does not by itself fail the span', () async {
      // OpenTelemetry keeps these separate and so do we: an exception can be
      // recorded on an operation that went on to succeed.
      final span = await startSpan();

      span.recordException(StateError('handled'));

      expect(calls.map((c) => c.method), ['spanRecordException']);
    });

    test('recording after end is ignored', () async {
      final span = await startSpan();
      span.end();
      calls.clear();

      span.recordException(StateError('too late'));

      expect(calls, isEmpty);
    });
  });

  group('error status', () {
    test('marks the span failed with a description', () async {
      final span = await startSpan();

      span.markFailed('payment declined');

      expect(calls.single.method, 'spanMarkFailed');
      final args = argumentsOf(calls.single);
      expect(args['shadowId'], span.shadowId);
      expect(args['description'], 'payment declined');
    });

    test('the description is optional', () async {
      final span = await startSpan();

      span.markFailed();

      expect(argumentsOf(calls.single)['description'], isNull);
    });

    test('marking failed after end is ignored', () async {
      final span = await startSpan();
      span.end();
      calls.clear();

      span.markFailed('too late');

      expect(calls, isEmpty);
    });
  });
}
