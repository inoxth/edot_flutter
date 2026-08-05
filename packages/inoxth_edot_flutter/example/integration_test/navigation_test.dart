import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

import 'agent_export.dart';
import 'navigation_contract.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final endpoint = Platform.isAndroid
      ? CollectorProcess.androidEmulatorEndpoint
      : CollectorProcess.hostEndpoint;

  testWidgets('Screen Spans survive export', (tester) async {
    // Before the app is built: the observer declines to trace a navigation that happens
    // before the Agent exists, and the initial route is a navigation.
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

    final navigator = GlobalKey<NavigatorState>();

    // Nothing about this app is instrumented beyond the one observer, which is the claim
    // the ticket makes: navigation tracing with no per-route annotation.
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [EdotNavigatorObserver()],
        initialRoute: homeRoute,
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) =>
              Scaffold(body: Center(child: Text('at ${settings.name}'))),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Not awaited: the future a push returns completes when the route is *popped*, so
    // awaiting it here would wait for the pop below and deadlock the test.
    navigator.currentState!.pushNamed<void>(orderRoute);
    await tester.pumpAndSettle();

    // While the order screen is the Active View, so the export can be checked against the
    // transition that opened it.
    Edot.tracer.startSpan(spanOnTheOrderScreen).end();

    navigator.currentState!.pop();
    await tester.pumpAndSettle();

    await flushUntilAssertable();
  });
}
