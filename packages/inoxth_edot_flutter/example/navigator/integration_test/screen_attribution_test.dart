import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

import 'agent_export.dart';
import 'screen_attribution_contract.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final endpoint = Platform.isAndroid
      ? CollectorProcess.androidEmulatorEndpoint
      : CollectorProcess.hostEndpoint;

  testWidgets('screen attributes survive export', (tester) async {
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

    Edot.setActiveView(firstScreenName);

    Edot.tracer.startSpan(spanOnFirstScreen)
      ..setString(platformAttribute, Platform.operatingSystem)
      ..end();

    // Same screen entry as the span above, so the two must agree on the identifier.
    Edot.log(EdotSeverity.info, logOnFirstScreen);

    Edot.setActiveView(secondScreenName);
    Edot.tracer.startSpan(spanOnSecondScreen).end();

    Edot.clearActiveView();
    Edot.tracer.startSpan(spanWithNoScreen).end();

    await flushUntilAssertable();
  });
}
