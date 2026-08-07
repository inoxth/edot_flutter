import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

import 'agent_export.dart';
import 'inpage_view_contract.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final endpoint = Platform.isAndroid
      ? CollectorProcess.androidEmulatorEndpoint
      : CollectorProcess.hostEndpoint;

  testWidgets('an in-page view span survives export', (tester) async {
    // Before the app is built, so the initial tab is entered against a running Agent
    // rather than held.
    await Edot.start(
      EdotConfig(
        serviceName: 'edot-flutter-seam2',
        serviceVersion: '0.0.1',
        deploymentEnvironment: 'integration-test',
        serverUrl: endpoint,
        debug: true,
        android: const EdotAndroidConfig(diskBufferingEnabled: false),
      ),
    );

    // A tabbed app whose only instrumentation is the one EdotViewObserver - the claim the
    // ticket makes: in-page view tracking with no per-switch annotation.
    await tester.pumpWidget(const _TabbedApp());
    await tester.pumpAndSettle();

    // The switch under test. Tapping the tab drives it exactly as a user would; the
    // observer turns it into a Screen Span with no code on this side.
    await tester.tap(find.text(secondView));
    await tester.pumpAndSettle();

    // While the second tab is the Active View, so the export can be checked against the
    // switch that opened it.
    Edot.tracer.startSpan(spanOnTheSecondView).end();

    await flushUntilAssertable();
  });
}

/// A minimal tabbed app: a `TabBar`/`TabBarView` wrapped in `EdotViewObserver.tabs`.
class _TabbedApp extends StatefulWidget {
  const _TabbedApp();

  @override
  State<_TabbedApp> createState() => _TabbedAppState();
}

class _TabbedAppState extends State<_TabbedApp>
    with SingleTickerProviderStateMixin {
  static const _views = [firstView, secondView];

  late final TabController _controller = TabController(
    length: _views.length,
    vsync: this,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(
        bottom: TabBar(
          controller: _controller,
          tabs: [for (final view in _views) Tab(text: view)],
        ),
      ),
      body: EdotViewObserver.tabs(
        controller: _controller,
        names: _views,
        child: TabBarView(
          controller: _controller,
          children: [
            for (final view in _views) Center(child: Text('the $view tab')),
          ],
        ),
      ),
    ),
  );
}
