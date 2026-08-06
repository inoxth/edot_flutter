import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

import 'consent_contract.dart';

/// Seam 2, device half — produces telemetry either side of a consent change, and one
/// record before the Agent was ready at all.
///
/// The host half owns the assertions: `tool/verify_consent.dart`.
///
/// Android only, because two of the three records are log records and `flush` does not
/// drain those on iOS (ADR-0011) — an iOS run would be asserting on the Agent's own
/// batch timer rather than on the Plugin.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('consent gates what is exported', (tester) async {
    if (!Platform.isAndroid) {
      fail(
        'This suite runs on Android only. Log records are not drained by flush() on '
        'iOS (ADR-0011), and two of the three records here are log records, so an iOS '
        "run would be asserting on the Agent's own timers.",
      );
    }

    // Before `Edot.start`, so this is held by the queue rather than emitted.
    Edot.log(EdotSeverity.info, heldRecordBody);

    // The gap the host half reads. A record dated when the queue replayed it rather than
    // when it was produced would close this gap to nearly nothing.
    await Future<void>.delayed(heldRecordDelay);

    await Edot.start(
      EdotConfig(
        serviceName: serviceName,
        serviceVersion: '0.0.1',
        deploymentEnvironment: 'integration-test',
        serverUrl: CollectorProcess.androidEmulatorEndpoint,
        debug: true,

        // Off so `flush` puts telemetry on the wire rather than in the Agent's own
        // buffer, which is what lets this suite assert within its window (ADR-0011).
        android: const EdotAndroidConfig(diskBufferingEnabled: false),
      ),
    );

    Edot.setTrackingConsent(EdotTrackingConsent.notGranted);
    Edot.log(EdotSeverity.warn, withheldRecordBody);

    // Held withdrawn for a while, not switched straight back. The Agent's own
    // instrumentation is outside this gate (ADR-0015), and a refusal lasting microseconds
    // would give it no chance to show that.
    await Future<void>.delayed(withdrawnWindow);

    Edot.setTrackingConsent(EdotTrackingConsent.granted);
    Edot.log(EdotSeverity.info, permittedRecordBody);

    await Edot.flush();
  });
}
