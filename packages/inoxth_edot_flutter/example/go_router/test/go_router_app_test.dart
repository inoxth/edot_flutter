import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter_example_go_router/main.dart';

/// Seam 1 smoke test for the go_router flavor.
///
/// The point of the router-agnostic shared screens is that this flavor gets the same
/// Screen Span / Active View behaviour as the navigator flavor with different routing,
/// so this walks a push and asserts the Active View followed. No Agent is started -
/// telemetry is held (ADR-0005) and the channel is mocked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final config = EdotConfig(
    serviceName: 'edot-flutter-example-go-router-test',
    serviceVersion: '0.0.0',
    deploymentEnvironment: 'test',
    serverUrl: 'http://localhost:4318',
  );

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(GoRouterExampleApp(config: config));
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

  testWidgets('the three top-level tabs render under go_router', (
    tester,
  ) async {
    await pumpApp(tester);

    for (final tab in ['Demos', 'Settings', 'Home']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      expect(
        find.text(tab),
        findsWidgets,
        reason: 'the $tab tab did not render',
      );
    }

    expect(tester.takeException(), isNull);
  });

  testWidgets('go_router pushes move the Active View, screen after screen', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.text('Demos'));
    await tester.pumpAndSettle();

    // context.push goes through go_router's Navigator with the EdotNavigatorObserver
    // attached; the shared extractor names each page from its route. Two different
    // pushes must each move the Active View - the point of the router-agnostic screens.
    await tester.tap(find.text('Network'));
    await tester.pumpAndSettle();
    expect(find.text('EdotHttpClient'), findsOneWidget);
    expect(Edot.activeView?.name, 'Network');

    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Tracing'));
    await tester.pumpAndSettle();
    expect(find.text('Span with a nested child'), findsOneWidget);
    expect(Edot.activeView?.name, 'Tracing');

    expect(tester.takeException(), isNull);
  });
}
