import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter_example_basic/main.dart';

/// Seam 1 smoke test: keeps the basic flavor building and its actions callable.
///
/// Does not start the Agent - telemetry produced before `Edot.start` is held (ADR-0005),
/// which is what lets the app be driven here without a collector. The channel is mocked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const BasicExampleApp());
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

  testWidgets('the basic actions run without throwing', (tester) async {
    await pumpApp(tester);

    for (final action in [
      'Span with a nested child',
      'Record a metric',
      'Write a log record',
      'Report an error',
    ]) {
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
    }

    expect(tester.takeException(), isNull);
  });

  testWidgets('the error boundary shows a fallback instead of the subtree', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('This subtree builds fine.'), findsOneWidget);

    await tester.tap(find.text('Break a widget subtree'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isStateError);
    expect(find.textContaining('This subtree failed to build'), findsOneWidget);
  });
}
