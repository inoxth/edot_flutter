import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter/src/edot_channel.dart'
    show debugLoggingEnabled;

/// Seam 1 — capturing Dart Errors.
///
/// A Dart Error is a log record, never a crash event: ADR-0008 keeps them out of
/// crash-free rate, because a layout overflow counted as a crash would make the one
/// metric mobile teams alert on untrustworthy. The attribute names are the Elastic
/// Mobile Attribute Set (ADR-0003) and match this organisation's React Native SDK
/// verbatim, `event.name` included. Do not "correct" them.
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
        serverUrl: 'https://apm.example.com:4318',
      ),
    );
    calls.clear();
  }

  List<MethodCall> callsTo(String method) =>
      calls.where((c) => c.method == method).toList();

  Map<Object?, Object?> argumentsOf(MethodCall call) =>
      call.arguments as Map<Object?, Object?>;

  /// Attributes of the single captured error record, by key.
  Map<Object?, Object?> errorAttributes() {
    final record = callsTo('emitLog').single;
    final encoded = argumentsOf(record)['attributes']! as List<Object?>;

    return {
      for (final entry in encoded.cast<Map<Object?, Object?>>())
        entry['key']: entry['value'],
    };
  }

  group('the record a captured error becomes', () {
    test('carries type, message, stack trace and source', () async {
      await startPlugin();

      Edot.reportError(
        const FormatException('bad payload'),
        stackTrace: StackTrace.fromString('#0 somewhere'),
      );

      final attributes = errorAttributes();
      expect(attributes['exception.type'], 'FormatException');
      expect(attributes['exception.message'], contains('bad payload'));
      expect(attributes['exception.stacktrace'], contains('somewhere'));
      expect(attributes['error.source'], 'dart_reported');
      // Fleet Alignment: the React Native SDK sets this on every error record, so a
      // dashboard filtering on it must find this fleet's too.
      expect(attributes['event.name'], 'exception');
    });

    test('is an error, never a fatal', () async {
      // ADR-0008: a Dart Error must not reach crash-free rate. It is one log record at
      // error severity and nothing else — asserted as the whole set of calls the Agent
      // receives, because the way this breaks is a second call to something that does
      // feed crash-free rate, and naming the method that must be absent would only test
      // for the one route somebody thought of.
      await startPlugin();

      Edot.reportError(StateError('handled'));

      expect(calls.map((c) => c.method), ['emitLog']);
      expect(argumentsOf(callsTo('emitLog').single)['severity'], 'error');
    });

    test('carries the Active View', () async {
      await startPlugin();
      Edot.setActiveView('Checkout');

      Edot.reportError(StateError('handled'));

      expect(errorAttributes()['screen.name'], 'Checkout');
      expect(errorAttributes()['screen.id'], isNotNull);
    });

    test('records against the operation in flight, which fails', () async {
      // The failure belongs on the operation, not only in a log nobody correlated.
      await startPlugin();

      final span = Edot.tracer.startSpan('checkout');
      Edot.tracer.runWithParent(span, () => Edot.reportError(StateError('no')));
      span.end();

      expect(callsTo('spanRecordException'), hasLength(1));
      expect(
        argumentsOf(callsTo('spanRecordException').single)['shadowId'],
        argumentsOf(callsTo('spanStart').single)['shadowId'],
      );
      expect(callsTo('spanMarkFailed'), hasLength(1));
    });

    test('records against no span when no operation is in flight', () async {
      // Not the most recently started span: that rule produces plausible, wrong
      // attribution as soon as two flows overlap.
      await startPlugin();

      final span = Edot.tracer.startSpan('unrelated');
      Edot.reportError(StateError('no'));
      span.end();

      expect(callsTo('spanRecordException'), isEmpty);
      expect(callsTo('spanMarkFailed'), isEmpty);
    });
  });

  group('the three sources', () {
    test(
      'a Flutter framework error is captured with no app-side handling',
      () async {
        await startPlugin();

        FlutterError.reportError(
          FlutterErrorDetails(
            exception: StateError('build failed'),
            context: ErrorDescription('while building MyWidget'),
          ),
        );

        expect(errorAttributes()['error.source'], 'flutter_framework');
        // The framework's own context is the most useful line in a Flutter error.
        expect(
          errorAttributes()['error.context'],
          contains('while building MyWidget'),
        );
      },
    );

    test('an uncaught async error is captured with no guarded zone', () async {
      // The reason capture is automatic rather than opt-in: since Flutter 3.3 this
      // arrives without the app wrapping its entry point in `runZonedGuarded`
      // (ADR-0008). Delivered through the handler the Plugin installed, exactly as the
      // engine delivers it.
      await startPlugin();

      final handled = PlatformDispatcher.instance.onError!(
        StateError('nobody awaited this'),
        StackTrace.fromString('#0 async gap'),
      );

      expect(errorAttributes()['error.source'], 'dart_uncaught');
      // The runtime's decision is left where it was: there was no previous handler, so
      // the error stays unhandled and the app behaves as it would have.
      expect(handled, isFalse);
    });

    test('an error from a spawned isolate is captured', () async {
      await startPlugin();

      final port = Edot.isolateErrorPort;
      expect(port, isNotNull, reason: 'the listener must exist after start');

      // A real isolate, failing for real: what matters is the payload shape, two
      // preformatted strings, because neither an error nor a stack trace can cross an
      // isolate boundary as an object.
      await Isolate.spawn(
        _failInAnIsolate,
        null,
        onError: port,
        errorsAreFatal: true,
      );

      // The port is a RawReceivePort inside the Plugin; give the isolate's error time
      // to arrive on it. Bounded, so a regression that stops capturing isolate errors
      // fails here rather than hanging whatever is running the suite.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (callsTo('emitLog').isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        callsTo('emitLog'),
        hasLength(1),
        reason: "the isolate's error never reached the listener",
      );

      expect(errorAttributes()['error.source'], 'dart_isolate');
      expect(
        errorAttributes()['exception.message'],
        contains('isolate went wrong'),
      );
      // Not `String`, which is the type of what actually arrived: the Dart type did not
      // survive the boundary, and reporting the carrier's type would put `String` on
      // every isolate error in Kibana.
      expect(errorAttributes()['exception.type'], 'IsolateError');
      expect(errorAttributes()['exception.stacktrace'], isNotNull);
    });
  });

  group('chaining', () {
    test('a Flutter handler registered before start still runs', () async {
      // Adding this Plugin must not silently stop an incumbent reporter — the kind of
      // breakage nobody notices until an incident.
      final seen = <Object>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) => seen.add(details.exception);
      addTearDown(() => FlutterError.onError = previous);

      await startPlugin();

      final error = StateError('build failed');
      FlutterError.reportError(FlutterErrorDetails(exception: error));

      expect(seen, [error]);
      expect(callsTo('emitLog'), hasLength(1));
    });

    test(
      'an async handler registered before start still runs, and decides',
      () async {
        // Including its return value: whether the app survives an uncaught error is the
        // incumbent's decision, not the Plugin's.
        final seen = <Object>[];
        final previous = PlatformDispatcher.instance.onError;
        PlatformDispatcher.instance.onError = (error, stack) {
          seen.add(error);
          return true;
        };
        addTearDown(() => PlatformDispatcher.instance.onError = previous);

        await startPlugin();

        final error = StateError('nobody awaited this');
        final handled = PlatformDispatcher.instance.onError!(
          error,
          StackTrace.empty,
        );

        expect(seen, [error]);
        expect(handled, isTrue);
      },
    );

    test('the handlers are restored when the Plugin stops', () async {
      final before = FlutterError.onError;

      await startPlugin();
      expect(FlutterError.onError, isNot(before));

      Edot.resetForTesting();
      expect(FlutterError.onError, before);
    });

    test('a handler registered after start survives the Plugin stopping', () async {
      // The other direction of the same courtesy. A reporter that registered after the
      // Plugin owns the handler now and is chaining to ours; restoring over it on the way
      // out would take that app's error reporting away to tidy up ours.
      await startPlugin();

      final ours = FlutterError.onError;
      void theirs(FlutterErrorDetails details) => ours?.call(details);
      FlutterError.onError = theirs;
      addTearDown(() => FlutterError.onError = null);

      Edot.resetForTesting();

      expect(FlutterError.onError, theirs);
    });
  });

  group('the error boundary', () {
    testWidgets('shows the fallback, and does not report the failure again', (
      tester,
    ) async {
      await startPlugin();

      // The framework reports a build failure through its own handler, which the
      // Plugin has taken over — so the record comes from there, and the boundary is
      // what changes the pixels. Reporting again in the boundary would double-count.
      // The count below is the assertion that it does not; the test that follows shows
      // the same count without a boundary, which is what makes this one mean something.
      await tester.pumpWidget(
        MaterialApp(
          home: EdotErrorBoundary(
            fallback: (error) => const Text('unavailable'),
            child: Builder(builder: (_) => throw StateError('subtree failed')),
          ),
        ),
      );

      expect(find.text('unavailable'), findsOneWidget);
      expect(callsTo('emitLog'), hasLength(1));
      expect(errorAttributes()['error.source'], 'flutter_framework');

      // The framework records the exception it caught; the test asserted the fallback,
      // so the failure is accounted for.
      expect(tester.takeException(), isStateError);

      // Settles the fire-and-forget channel calls the captured error left behind, which
      // a widget test refuses to end with outstanding.
      await tester.idle();
    });

    testWidgets('leaves an unguarded failure looking as it always did', (
      tester,
    ) async {
      // No boundary above the failure, so the previous error widget builder renders —
      // the Plugin must not change what an app without a boundary shows.
      await startPlugin();

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (_) => throw StateError('subtree failed')),
        ),
      );

      expect(find.byType(ErrorWidget), findsOneWidget);
      expect(tester.takeException(), isStateError);
      // The same count the boundary test asserts. Reporting is the framework handler's
      // job either way, so a boundary must not change it in either direction.
      expect(callsTo('emitLog'), hasLength(1));

      await tester.idle();
    });

    testWidgets('leaves the error display alone until a boundary needs it', (
      tester,
    ) async {
      // The hook is global, and `flutter_test` fails any test that ends with
      // `ErrorWidget.builder` changed. Claiming it at start would therefore break every
      // widget test an integrator writes that starts the Plugin — including this
      // Plugin's own Seam 2 suites, none of which have a boundary.
      final before = ErrorWidget.builder;

      await startPlugin();
      expect(ErrorWidget.builder, before);

      await tester.pumpWidget(
        MaterialApp(
          home: EdotErrorBoundary(
            fallback: (error) => const Text('unavailable'),
            child: const Text('fine'),
          ),
        ),
      );
      expect(ErrorWidget.builder, isNot(before));

      // Released when the boundary goes, so the app it was mounted in ends up exactly
      // where it started.
      await tester.pumpWidget(const MaterialApp(home: Text('fine')));
      expect(ErrorWidget.builder, before);
    });

    testWidgets('keeps the hook while an outer boundary still needs it', (
      tester,
    ) async {
      // Nested boundaries share one global hook. Releasing it when the inner one goes
      // would leave the outer one silently unable to catch anything.
      final before = ErrorWidget.builder;
      await startPlugin();

      await tester.pumpWidget(
        MaterialApp(
          home: EdotErrorBoundary(
            fallback: (error) => const Text('outer'),
            child: EdotErrorBoundary(
              fallback: (error) => const Text('inner'),
              child: const Text('fine'),
            ),
          ),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: EdotErrorBoundary(
            fallback: (error) => const Text('outer'),
            child: const Text('fine'),
          ),
        ),
      );
      expect(ErrorWidget.builder, isNot(before));

      await tester.pumpWidget(const MaterialApp(home: Text('fine')));
      expect(ErrorWidget.builder, before);
    });

    testWidgets('the inner boundary is the one that answers', (tester) async {
      // Nearest-enclosing, not outermost: a boundary exists to keep a failure local, and
      // an outer fallback replacing more of the screen than the failure occupied would
      // defeat the point.
      await startPlugin();

      await tester.pumpWidget(
        MaterialApp(
          home: EdotErrorBoundary(
            fallback: (error) => const Text('outer'),
            child: EdotErrorBoundary(
              fallback: (error) => const Text('inner'),
              child: Builder(
                builder: (_) => throw StateError('subtree failed'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('inner'), findsOneWidget);
      expect(find.text('outer'), findsNothing);
      expect(tester.takeException(), isStateError);

      await tester.idle();
    });
  });

  group('before start', () {
    test('an error is not captured, and nothing throws', () async {
      // The handlers are not installed yet, so this is the direct call. It must not
      // throw: a telemetry fault during error handling would replace the error the app
      // was trying to report.
      expect(() => Edot.reportError(StateError('early')), returnsNormally);

      // Drained before asserting: a channel call is dispatched asynchronously, so an
      // assertion made in the same turn would find `calls` empty whether or not
      // anything was sent.
      await Future<void>.delayed(Duration.zero);

      expect(calls, isEmpty);
    });

    test('says why, in terms a developer can act on', () async {
      // The only observable difference the pre-start check makes. Emitting the record
      // would fail anyway — Edot.log refuses before start — so what the check is for is
      // the diagnostic: "not captured, because the Plugin had not started" rather than a
      // generic report of a caught StateError. An error before start is exactly the kind
      // that goes missing and is never explained.
      final printed = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      addTearDown(() => debugPrint = previous);

      debugLoggingEnabled = true;
      addTearDown(() => debugLoggingEnabled = false);

      Edot.reportError(StateError('early'));

      expect(printed, hasLength(1));
      expect(printed.single, contains('error before Edot.start'));
      expect(printed.single, contains('not captured'));
    });
  });
}

/// Entry point for the spawned isolate in the isolate-error test.
void _failInAnIsolate(void _) => throw StateError('the isolate went wrong');
