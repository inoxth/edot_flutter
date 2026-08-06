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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(edotChannelName),
          (call) async => null,
        );
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
    await runDemo('Logs', 'Log record');

    expect(tester.takeException(), isNull);
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
}
