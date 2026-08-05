import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

import 'agent_export.dart';
import 'enrichment_contract.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final endpoint = Platform.isAndroid
      ? CollectorProcess.androidEmulatorEndpoint
      : CollectorProcess.hostEndpoint;

  testWidgets('typed attributes, exceptions and status reach the collector', (
    tester,
  ) async {
    await Edot.start(
      EdotConfig(
        serviceName: 'edot-flutter-seam2',
        serviceVersion: '0.0.1',
        deploymentEnvironment: 'integration-test',
        serverUrl: endpoint,
        debug: true,
        // See the tracer bullet test: with disk buffering on, flush() only moves
        // spans into the Agent's on-disk buffer and the upload never happens
        // before the harness kills the app.
        android: const EdotAndroidConfig(diskBufferingEnabled: false),
      ),
    );

    Edot.tracer.startSpan(enrichedSpanName)
      ..setString(stringKey, stringValue)
      ..setInt(intKey, intValue)
      ..setDouble(doubleKey, doubleValue)
      ..setBool(boolKey, boolValue)
      // Recorded, but the span is left succeeding — the host half asserts this
      // span is *not* in error, which is what keeps recordException and
      // markFailed honestly separate.
      ..recordException(
        StateError(exceptionMessageFragment),
        stackTrace: StackTrace.current,
      )
      ..end();

    Edot.tracer.startSpan(failedSpanName)
      ..markFailed(failureDescription)
      ..end();

    await flushUntilAssertable();
  });
}
