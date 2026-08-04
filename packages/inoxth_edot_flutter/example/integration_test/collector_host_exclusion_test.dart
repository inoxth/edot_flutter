import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

import 'exclusion_contract.dart';

/// Seam 2, device half — exercises the Collector Host exclusion (ADR-0006).
///
/// iOS only. The exclusion exists because `apm-agent-ios` exports through
/// `URLSession.shared`, which its own instrumentation traces, so every export
/// would produce another span to export, and so on.
///
/// Assertions live in the host half: `tool/verify_collector_host_exclusion.dart`.
const _probeChannel = MethodChannel(
  'inoxth_edot_flutter_example/native_request',
);

/// Long enough to cover two of the Agent's central-configuration polls, whose
/// default interval is 60s.
///
/// The Collector Host exclusion has to hold for that polling as much as for
/// signal export, and a shorter window would assert its absence without the
/// polling ever having been attempted (ADR-0006).
const _iosPersistenceUploadWindow = Duration(seconds: 80);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native requests to the Collector Host are not traced', (
    tester,
  ) async {
    await Edot.start(
      EdotConfig(
        serviceName: 'edot-flutter-seam2',
        serviceVersion: '0.0.1',
        deploymentEnvironment: 'integration-test',
        serverUrl: serverUrl,
        debug: true,
      ),
    );

    Edot.tracer.startSpan(controlSpanName).end();

    for (final url in probeRequests.keys) {
      await _probeChannel.invokeMethod<void>('get', <String, Object?>{
        'url': url,
      });
    }

    await Edot.flush();

    if (Platform.isIOS) {
      // ADR-0011: flush cannot force the iOS persistence worker to upload.
      await Future<void>.delayed(_iosPersistenceUploadWindow);
    }
  });
}
