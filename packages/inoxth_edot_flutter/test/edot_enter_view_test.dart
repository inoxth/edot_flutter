import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

/// Seam 1 — the shared "enter a view" primitive.
///
/// `Edot.enterView` is the deep module a route navigation and an in-page switch both
/// run through (ADR-0004): it moves the Active View and emits the transition Screen
/// Span. Proven here through the public API against the mocked channel — the same way
/// the navigation observer's own Seam 1 tests are — never against the singleton's
/// internal state.
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

  List<Object?> startedSpanNames() =>
      callsTo('spanStart').map((c) => argumentsOf(c)['name']).toList();

  Map<Object?, Object?> attributesOf(MethodCall spanStart) =>
      argumentsOf(spanStart)['attributes']! as Map<Object?, Object?>;

  Set<Object?> endedShadowIds() =>
      callsTo('spanEnd').map((c) => argumentsOf(c)['shadowId']).toSet();

  group('entering a view', () {
    testWidgets('moves the Active View and emits one Screen Span', (
      tester,
    ) async {
      await startPlugin();
      await tester.pumpWidget(const SizedBox());
      calls.clear();

      Edot.enterView('Dashboard');

      expect(Edot.activeView?.name, 'Dashboard');
      expect(startedSpanNames(), ['Dashboard - view appearing']);
    });

    testWidgets('carries the screen it is entering', (tester) async {
      await startPlugin();
      await tester.pumpWidget(const SizedBox());
      calls.clear();

      Edot.enterView('Dashboard');

      final attributes = attributesOf(callsTo('spanStart').single);
      expect(attributes['screen.name'], 'Dashboard');
      // Established before the span starts, so it carries the same identifier every
      // later span on this screen will.
      expect(attributes['screen.id'], Edot.activeView!.id);
    });

    testWidgets('ends the transition on the next frame', (tester) async {
      await startPlugin();
      await tester.pumpWidget(const SizedBox());
      calls.clear();

      Edot.enterView('Dashboard');
      final started = callsTo('spanStart').single;
      expect(callsTo('spanEnd'), isEmpty, reason: 'no frame has rendered yet');

      // enterView does not schedule a frame; in real use the switch that triggered it
      // does (a navigation, a setState). Standing in for that here so the post-frame
      // callback has a frame to run at.
      tester.binding.scheduleFrame();
      await tester.pump();

      expect(endedShadowIds(), {argumentsOf(started)['shadowId']});
    });

    testWidgets('names the screen it came from, once there is one', (
      tester,
    ) async {
      await startPlugin();
      await tester.pumpWidget(const SizedBox());
      calls.clear();

      Edot.enterView('Home');
      expect(
        attributesOf(
          callsTo('spanStart').single,
        ).containsKey('last.screen.name'),
        isFalse,
        reason: 'nothing preceded the first view',
      );

      calls.clear();
      Edot.enterView('Orders');

      expect(
        attributesOf(callsTo('spanStart').single)['last.screen.name'],
        'Home',
      );
    });
  });

  group('the same view, entered again', () {
    testWidgets('is a fresh entry with a second span, not a no-op', (
      tester,
    ) async {
      // De-duplicating a no-op switch is the caller's job, not the primitive's: two
      // entries can legitimately share a Screen Name (`/orders/1` and `/orders/2`),
      // and collapsing them here would attribute the second entry's telemetry to the
      // first. The navigation observer relies on this, de-duplicating by route.
      await startPlugin();
      await tester.pumpWidget(const SizedBox());
      calls.clear();

      Edot.enterView('Orders');
      final firstEntry = Edot.activeView!.id;

      Edot.enterView('Orders');

      expect(Edot.activeView!.id, isNot(firstEntry));
      expect(startedSpanNames(), [
        'Orders - view appearing',
        'Orders - view appearing',
      ]);
      // The second omits `last.screen.name`: naming the screen the user is already on
      // answers nothing.
      expect(
        attributesOf(callsTo('spanStart').last).containsKey('last.screen.name'),
        isFalse,
      );
    });
  });

  group('a switch faster than a frame', () {
    testWidgets('ends the transition it overtook, and only that one', (
      tester,
    ) async {
      await startPlugin();
      await tester.pumpWidget(const SizedBox());
      calls.clear();

      Edot.enterView('A');
      Edot.enterView('B');
      tester.binding.scheduleFrame();
      await tester.pump();

      final started = callsTo('spanStart');
      expect(started, hasLength(2));
      expect(
        endedShadowIds(),
        started.map((c) => argumentsOf(c)['shadowId']).toSet(),
        reason: 'both transitions have to be over',
      );
    });
  });

  group('setActiveView stays attribute-only', () {
    testWidgets('moves the Active View without a Screen Span', (tester) async {
      await startPlugin();
      await tester.pumpWidget(const SizedBox());
      calls.clear();

      Edot.setActiveView('Settings');

      expect(Edot.activeView?.name, 'Settings');
      expect(callsTo('spanStart'), isEmpty);
    });
  });

  group('a blank name', () {
    testWidgets('is rejected without touching state', (tester) async {
      await startPlugin();
      await tester.pumpWidget(const SizedBox());
      Edot.setActiveView('Home');
      calls.clear();

      expect(() => Edot.enterView('  '), throwsArgumentError);

      // The rejection is total: no span, and the previous view is left intact.
      expect(callsTo('spanStart'), isEmpty);
      expect(Edot.activeView?.name, 'Home');
    });
  });
}
