import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter_example/main.dart';

/// Keeps the example app honest.
///
/// The README points integrators at `example/` as the place every documented feature is
/// demonstrated, so an example that no longer builds or has lost a feature is worse than
/// none — it is a promise the repository breaks on first contact. These tests walk it the
/// way a reader would.
///
/// Deliberately does **not** start the Agent: telemetry produced before `Edot.start` is
/// held rather than refused (ADR-0005), which is exactly what lets the app be driven here
/// without a collector. The channel is mocked so nothing reaches a platform that does not
/// exist under `flutter test`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Pumps the app on a surface tall enough for every action to be built.
  ///
  /// The tabs are lazy `ListView`s, so on a phone-sized surface the last card in each —
  /// the error boundary, the screen push — is never built and cannot be found. Scrolling
  /// to each would work too; a taller window keeps the tests about the app rather than
  /// about scrolling.
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ExampleApp());
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

  testWidgets('every tab the README promises is reachable', (tester) async {
    await pumpApp(tester);

    for (final tab in ['Network', 'Errors', 'Consent', 'Telemetry']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(tab),
        findsWidgets,
        reason: 'the $tab tab did not open',
      );
    }
  });

  testWidgets('the telemetry actions run without throwing', (tester) async {
    await pumpApp(tester);

    // The three that need neither a network nor a platform: a span with a child, a log
    // record and a metric. Each is a documented feature, and each would throw here if the
    // app were calling the API wrongly.
    for (final action in ['Span with a nested child', 'Log record', 'Metric']) {
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
    }

    expect(tester.takeException(), isNull);
  });

  testWidgets('all three consent states are offered and take effect', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.text('Consent'));
    await tester.pumpAndSettle();

    // The README says the example covers all three states; this is what makes that true
    // rather than a claim, and it checks the wire values a reader would compare against
    // the React Native SDK.
    for (final consent in EdotTrackingConsent.values) {
      expect(find.text(consent.wireValue), findsOneWidget);
    }

    await tester.tap(find.text(EdotTrackingConsent.granted.wireValue));
    await tester.pumpAndSettle();

    expect(Edot.trackingConsent, EdotTrackingConsent.granted);
  });

  testWidgets('the error boundary shows a fallback instead of the subtree', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.text('Errors'));
    await tester.pumpAndSettle();

    expect(find.text('This subtree builds fine.'), findsOneWidget);

    await tester.tap(find.text('Break a widget subtree'));
    await tester.pumpAndSettle();

    // The build failure is the point, so it is consumed rather than left to fail the test.
    expect(tester.takeException(), isStateError);
    expect(find.textContaining('This subtree failed to build'), findsOneWidget);
  });

  testWidgets('pushing a screen reaches the detail route', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('Push a screen'));
    await tester.pumpAndSettle();

    expect(find.text('Order detail'), findsWidgets);

    // The extractor named it, not the route: the observer set the Active View from the
    // name the app supplied for `/detail`, which is what the README's recipe promises.
    expect(Edot.activeView?.name, 'Order detail');
  });
}
