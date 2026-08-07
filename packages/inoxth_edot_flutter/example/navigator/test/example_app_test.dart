import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter_example/main.dart';

/// Keeps the example app honest.
///
/// The README points integrators at this flavor as the place every documented feature is
/// demonstrated, so an example that no longer builds or has lost a feature is worse than
/// none - it is a promise the repository breaks on first contact. These tests walk it the
/// way a reader would: switch tabs, open a demo, toggle consent, break a subtree.
///
/// Deliberately does **not** start the Agent: telemetry produced before `Edot.start` is
/// held rather than refused (ADR-0005), which is what lets the app be driven here without
/// a collector. The channel is mocked so nothing reaches a platform that does not exist
/// under `flutter test`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final config = EdotConfig(
    serviceName: 'edot-flutter-example-test',
    serviceVersion: '0.0.0',
    deploymentEnvironment: 'test',
    serverUrl: 'http://localhost:4318',
  );

  final calls = <MethodCall>[];

  /// Names of the Screen Spans emitted so far. Empty unless the Agent was started,
  /// since telemetry is otherwise held rather than sent (ADR-0005).
  List<Object?> viewSpanNames() => calls
      .where((c) => c.method == 'spanStart')
      .map((c) => (c.arguments as Map<Object?, Object?>)['name'])
      .toList();

  /// Pumps the app on a surface tall enough for every action to be built.
  ///
  /// The lists are lazy, so on a phone-sized surface the last card in each is never built
  /// and cannot be found. A taller window keeps the tests about the app rather than about
  /// scrolling.
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ExampleApp(config: config));
    await tester.pumpAndSettle();
  }

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

  testWidgets('the three top-level tabs are reachable', (tester) async {
    await pumpApp(tester);

    for (final tab in ['Demos', 'Settings', 'Home']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      expect(find.text(tab), findsWidgets, reason: 'the $tab tab did not open');
    }
  });

  testWidgets('opening a demo pushes its screen and moves the Active View', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.text('Demos'));
    await tester.pumpAndSettle();

    // Tap the Network entry in the Demos list; the pushed screen is what carries the
    // unique 'EdotHttpClient' action.
    await tester.tap(find.text('Network'));
    await tester.pumpAndSettle();

    expect(find.text('EdotHttpClient'), findsOneWidget);
    // The failure and sequential-request demos live here too. They make real requests, so
    // tapping them belongs to Seam 2; at Seam 1 it is enough that the app offers them.
    expect(find.text('Failed request'), findsOneWidget);
    expect(find.text('Three sequential requests'), findsOneWidget);
    // The push produced a Screen Span and moved the Active View to the pushed route,
    // named by the shared extractor rather than by its raw path.
    expect(Edot.activeView?.name, 'Network');
  });

  testWidgets('the telemetry demos run without throwing', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('Demos'));
    await tester.pumpAndSettle();

    // Each of these is a documented feature that would throw here if the app were
    // calling the API wrongly. They are held, not refused, with no Agent started.
    Future<void> runDemo(String demo, String action) async {
      await tester.tap(find.text(demo));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
    }

    await runDemo('Tracing', 'Span with a nested child');
    await runDemo('Metrics', 'Counter');

    // Every severity, in one visit to the Logs screen.
    await tester.tap(find.text('Logs'));
    await tester.pumpAndSettle();
    for (final severity in ['Debug', 'Info', 'Warn', 'Error']) {
      await tester.tap(find.text(severity));
      await tester.pumpAndSettle();
    }
    await tester.pageBack();
    await tester.pumpAndSettle();

    await runDemo('Interaction', 'Track a tap');

    expect(tester.takeException(), isNull);
  });

  testWidgets('a parameterised order route collapses to one Screen Name', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.text('Demos'));
    await tester.pumpAndSettle();

    // The raw route is /orders/1, but the shared extractor names every /orders/...
    // route 'Order detail', so different ids do not multiply Screen Names.
    await tester.tap(find.text('Open order #1'));
    await tester.pumpAndSettle();

    expect(find.textContaining('order #1'), findsOneWidget);
    expect(Edot.activeView?.name, 'Order detail');
  });

  testWidgets('all three consent states are offered and take effect', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    // The README says the example covers all three states; this checks the wire values a
    // reader would compare against the React Native SDK.
    for (final consent in EdotTrackingConsent.values) {
      expect(find.text(consent.wireValue), findsOneWidget);
    }

    // Starts granted, so switching to notGranted proves the toggle takes effect.
    await tester.tap(find.text(EdotTrackingConsent.notGranted.wireValue));
    await tester.pumpAndSettle();

    expect(Edot.trackingConsent, EdotTrackingConsent.notGranted);
  });

  testWidgets('the error boundary shows a fallback instead of the subtree', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.text('Demos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Errors'));
    await tester.pumpAndSettle();

    expect(find.text('This subtree builds fine.'), findsOneWidget);

    await tester.tap(find.text('Break a widget subtree'));
    await tester.pumpAndSettle();

    // The build failure is the point, so it is consumed rather than left to fail the test.
    expect(tester.takeException(), isStateError);
    expect(find.textContaining('This subtree failed to build'), findsOneWidget);
  });

  group('automatic in-page tracking', () {
    // These start the Agent, unlike the rest of the file: a Screen Span is held rather
    // than sent before start, so the channel only sees one once the Agent is running.
    testWidgets('switching a tab emits a view span and moves the view', (
      tester,
    ) async {
      await Edot.start(config);
      await pumpApp(tester);
      calls.clear();

      await tester.tap(find.text('Demos'));
      await tester.pumpAndSettle();

      expect(viewSpanNames(), contains('Demos - view appearing'));
      expect(Edot.activeView?.name, 'Demos');
    });

    testWidgets('returning from a demo lands back on the tab, one span', (
      tester,
    ) async {
      await Edot.start(config);
      await pumpApp(tester);

      await tester.tap(find.text('Demos'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Network'));
      await tester.pumpAndSettle();

      calls.clear();
      await tester.pageBack();
      await tester.pumpAndSettle();

      // The route observer defers the claimed root route to the shell's EdotViewObserver,
      // so the pop re-asserts the Demos tab with exactly one span, not a container span.
      expect(viewSpanNames(), ['Demos - view appearing']);
      expect(Edot.activeView?.name, 'Demos');
    });

    testWidgets('the in-page views demo tracks its own tab switches', (
      tester,
    ) async {
      await Edot.start(config);
      await pumpApp(tester);

      await tester.tap(find.text('Demos'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('In-page views'));
      await tester.pumpAndSettle();

      calls.clear();
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();

      // The tab pushes no route, yet the wrapped EdotViewObserver.tabs turns the switch
      // into a Screen Span and moves the Active View to the sub-view.
      expect(viewSpanNames(), contains('Details - view appearing'));
      expect(Edot.activeView?.name, 'Details');
    });
  });
}
