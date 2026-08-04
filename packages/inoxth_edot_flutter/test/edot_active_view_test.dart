import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

/// Seam 1 — screen attribution on every emission path.
///
/// The attribute names are `screen.name` and `screen.id` per ADR-0003, and both
/// are attached together or not at all, matching how the React Native SDK guards
/// its own enrichment. Enriching in Dart rather than through the Android Agent's
/// native interceptor is ADR-0004.
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

  Map<Object?, Object?> argumentsOf(MethodCall call) =>
      call.arguments as Map<Object?, Object?>;

  MethodCall callTo(String method) =>
      calls.firstWhere((c) => c.method == method);

  /// Creation-time attributes of the last started span.
  Map<Object?, Object?> spanAttributes() =>
      (argumentsOf(callTo('spanStart'))['attributes']
          as Map<Object?, Object?>?) ??
      const {};

  /// Log attributes, flattened from the type-tagged wire list.
  Map<Object?, Object?> logAttributes() {
    final tagged =
        argumentsOf(callTo('emitLog'))['attributes']! as List<Object?>;
    return {
      for (final entry in tagged.cast<Map<Object?, Object?>>())
        entry['key']: entry['value'],
    };
  }

  group('the Active View', () {
    test('is unset until something sets it', () {
      expect(Edot.activeView, isNull);
    });

    test('reports the name it was set with, and an identifier', () {
      Edot.setActiveView('Cart');

      expect(Edot.activeView?.name, 'Cart');
      expect(Edot.activeView?.id, isNotEmpty);
    });

    test('is settable before start, because navigation does not wait', () {
      // The first screen is often on screen before the Agent finishes starting.
      // Requiring start first would force apps to sequence navigation behind it.
      Edot.setActiveView('Splash');

      expect(Edot.activeView?.name, 'Splash');
    });

    test('gets a fresh identifier on each entry to the same screen', () {
      // The identifier distinguishes *this entry*, which is what makes it
      // useful for grouping the telemetry of one screen entry together.
      Edot.setActiveView('Cart');
      final first = Edot.activeView!.id;

      Edot.setActiveView('Cart');

      expect(Edot.activeView!.id, isNot(first));
    });

    test('can be cleared, for leaving all screens', () {
      Edot.setActiveView('Cart');

      Edot.clearActiveView();

      expect(Edot.activeView, isNull);
    });

    test('rejects a blank name rather than reporting an empty screen', () {
      expect(() => Edot.setActiveView('  '), throwsArgumentError);
    });
  });

  group('spans', () {
    test('carry the Active View name and identifier at creation', () async {
      await startPlugin();
      Edot.setActiveView('Checkout');

      Edot.tracer.startSpan('pay').end();

      expect(spanAttributes(), {
        'screen.name': 'Checkout',
        'screen.id': Edot.activeView!.id,
      });
    });

    test(
      'report the view current when they started, not when they end',
      () async {
        // A request that outlives a navigation belongs to the screen it began on.
        await startPlugin();
        Edot.setActiveView('Checkout');

        final span = Edot.tracer.startSpan('pay');
        Edot.setActiveView('Receipt');
        span.end();

        expect(spanAttributes()['screen.name'], 'Checkout');
      },
    );

    test('omit both attributes when no view is set', () async {
      await startPlugin();

      Edot.tracer.startSpan('pay').end();

      expect(spanAttributes(), isEmpty);
    });

    test('omit both attributes once the view is cleared', () async {
      await startPlugin();
      Edot.setActiveView('Checkout');
      Edot.clearActiveView();

      Edot.tracer.startSpan('pay').end();

      expect(spanAttributes(), isEmpty);
    });
  });

  group('log records', () {
    test('carry the Active View name and identifier', () async {
      await startPlugin();
      Edot.setActiveView('Checkout');

      Edot.log(EdotSeverity.info, 'card declined');

      expect(logAttributes(), {
        'screen.name': 'Checkout',
        'screen.id': Edot.activeView!.id,
      });
    });

    test('keep the caller\'s own attributes alongside', () async {
      await startPlugin();
      Edot.setActiveView('Checkout');

      Edot.log(EdotSeverity.info, 'card declined', attributes: {'attempt': 2});

      expect(logAttributes()['attempt'], 2);
      expect(logAttributes()['screen.name'], 'Checkout');
    });

    test('let the caller override the screen attributes deliberately', () async {
      // A caller who sets the key by hand means it; silently winning over them
      // would make the explicit call a no-op.
      await startPlugin();
      Edot.setActiveView('Checkout');

      Edot.log(
        EdotSeverity.info,
        'replayed',
        attributes: {'screen.name': 'Cart'},
      );

      expect(logAttributes()['screen.name'], 'Cart');
    });

    test('omit both attributes when no view is set', () async {
      await startPlugin();

      Edot.log(EdotSeverity.info, 'started');

      expect(logAttributes(), isEmpty);
    });
  });

  group('metrics', () {
    test('are not enriched, because the identifier is per-entry', () async {
      // A dimension that changes on every screen entry creates a new time series
      // per entry. Metrics are aggregates, so that is a cardinality problem rather
      // than useful attribution — and the React Native SDK does not enrich them
      // either.
      await startPlugin();
      Edot.setActiveView('Checkout');

      Edot.recordMetric('checkout.attempts', 1);

      expect(argumentsOf(callTo('recordMetric'))['attributes'], isEmpty);
    });
  });
}
