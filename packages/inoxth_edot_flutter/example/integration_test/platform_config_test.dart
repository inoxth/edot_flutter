import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

import 'agent_export.dart';
import 'platform_config_contract.dart';

const _case = String.fromEnvironment(caseVariable);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final endpoint = Platform.isAndroid
      ? CollectorProcess.androidEmulatorEndpoint
      : CollectorProcess.hostEndpoint;

  testWidgets('a configured Agent exports what it should', (tester) async {
    final configCase = ConfigCase.values.firstWhere(
      (c) => c.define == _case,
      orElse: () => throw StateError(
        'Pass --dart-define=$caseVariable=<${ConfigCase.values.map((c) => c.define).join('|')}>; '
        'got "$_case". The host half does this; running this file directly will not.',
      ),
    );

    await Edot.start(_configFor(configCase, endpoint));

    // The Session identifier is read before anything is emitted, so the value on the probe
    // span is one the app could genuinely have shown on a support screen at that moment.
    final reported = await Edot.currentSessionId();

    Edot.tracer.startSpan(probeSpanName)
      ..setString(platformAttribute, Platform.operatingSystem)
      ..setString(
        reportedSessionIdAttribute,
        reported.isEmpty ? noSessionId : reported,
      )
      ..end();

    // Skipped for the disabled case only: both native sides answer `flush` with a
    // `not_initialized` error when no Agent is running, which Dart raises. There is nothing
    // buffered to drain there anyway, which is the whole point of that case.
    if (configCase != ConfigCase.disabled) {
      await flushUntilAssertable();
    }
  });
}

EdotConfig _configFor(ConfigCase configCase, String endpoint) => EdotConfig(
  serviceName: configCase.serviceName,
  serviceVersion: '0.0.1',
  deploymentEnvironment: 'integration-test',
  serverUrl: endpoint,
  debug: true,
  disableAgent: configCase == ConfigCase.disabled,
  sessionSamplingRate: configCase == ConfigCase.sampledOut ? 0.0 : 1.0,

  // Off in **every** case, including the ones that must export nothing. With it on,
  // `flush` fills the Agent's on-disk buffer and the upload happens on its own schedule
  // (ADR-0011) — so nothing arrives within the window whatever else is configured, and
  // "nothing arrived" would stop meaning anything. Every Seam 2 device half does this.
  android: const EdotAndroidConfig(diskBufferingEnabled: false),

  // The only thing the instrumentation case changes. Android's crash reporting has no
  // toggle at all (ADR-0009), and its disk buffering is fixed above for the reason there.
  ios: EdotIosConfig(
    crashReportingEnabled: configCase != ConfigCase.instrumentationOff,
    systemMetricsEnabled: configCase != ConfigCase.instrumentationOff,
    appMetricsEnabled: configCase != ConfigCase.instrumentationOff,
    lifecycleEventsEnabled: configCase != ConfigCase.instrumentationOff,
  ),
);
