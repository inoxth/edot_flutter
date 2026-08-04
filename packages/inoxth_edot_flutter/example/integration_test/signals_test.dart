import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

import 'signals_contract.dart';

/// Seam 2, device half — emits the log record and metrics the host half checks.
///
/// Assertions live in the host half: `tool/verify_signals.dart`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('log records and metrics reach the collector', (tester) async {
    if (!Platform.isAndroid) {
      fail(
        'This suite runs on Android only. flush() drains neither log records nor '
        'metrics on iOS (ADR-0011), so an iOS run would be asserting on the '
        "Agent's own export timers rather than on the Plugin.",
      );
    }

    await Edot.start(
      EdotConfig(
        serviceName: 'edot-flutter-seam2',
        serviceVersion: '0.0.1',
        deploymentEnvironment: 'integration-test',
        serverUrl: CollectorProcess.androidEmulatorEndpoint,
        debug: true,
        android: const EdotAndroidConfig(diskBufferingEnabled: false),
      ),
    );

    Edot.log(EdotSeverity.warn, logMessage, attributes: logAttributes);

    const dimensions = <String, String>{
      metricDimensionKey: metricDimensionValue,
    };

    Edot.recordMetric(
      counterMetricName,
      counterMetricValue,
      attributes: dimensions,
    );
    Edot.recordMetric(
      upDownCounterMetricName,
      upDownCounterMetricValue,
      kind: EdotMetricKind.upDownCounter,
      attributes: dimensions,
    );
    Edot.recordMetric(
      histogramMetricName,
      histogramMetricValue,
      kind: EdotMetricKind.histogram,
      attributes: dimensions,
    );

    await Edot.flush();
  });
}
