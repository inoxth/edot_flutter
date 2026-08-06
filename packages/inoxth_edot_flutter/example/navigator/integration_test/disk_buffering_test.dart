import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

import 'disk_buffering_contract.dart';

/// Seam 2, device half — emits with the collector unreachable, then stays alive across its
/// return so the Agent has a chance to deliver what it buffered.
///
/// Which case comes from `--dart-define=EDOT_BUFFERING=...`. The host half runs this once per
/// case and owns the collector's disappearance and return:
/// `tool/verify_disk_buffering.dart`, where the assertions live.
const _case = String.fromEnvironment(caseVariable);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The emulator reaches the host through a fixed alias rather than localhost, and that applies
  // to the signal endpoint exactly as it does to the collector.
  final host = Platform.isAndroid ? '10.0.2.2' : 'localhost';
  final endpoint = Platform.isAndroid
      ? CollectorProcess.androidEmulatorEndpoint
      : CollectorProcess.hostEndpoint;

  testWidgets('the Agent delivers what it buffered while offline', (
    tester,
  ) async {
    if (!Platform.isAndroid) {
      fail(
        'This suite runs on Android only. On iOS delivery from the on-disk buffer is '
        'driven entirely by the Agent\'s own persistence worker, whose export delay grows '
        'on every failure up to a 20-second ceiling and which flush() cannot drive '
        '(ADR-0011) — so an iOS run asserts on that timer rather than on the Plugin, and '
        'does so unreliably. Measured: the same case delivered everything in one run and '
        'nothing in the next.',
      );
    }

    final bufferingCase = BufferingCase.values.firstWhere(
      (c) => c.define == _case,
      orElse: () => throw StateError(
        'Pass --dart-define=$caseVariable=<${BufferingCase.values.map((c) => c.define).join('|')}>; '
        'got "$_case". The host half does this; running this file directly will not.',
      ),
    );

    await Edot.start(
      EdotConfig(
        serviceName: bufferingCase.serviceName,
        serviceVersion: '0.0.1',
        deploymentEnvironment: 'integration-test',
        serverUrl: endpoint,
        debug: true,

        // The one option under test. On iOS persistence cannot be switched off at all, so this
        // reaches only the Android Agent — which is why the loss assertion is Android's.
        android: EdotAndroidConfig(
          diskBufferingEnabled: bufferingCase == BufferingCase.buffered,
        ),
      ),
    );

    // Offline. With buffering on this reaches the on-disk buffer rather than the wire
    // (ADR-0011), which is the point; with it off it attempts the wire, where nothing is
    // listening.
    Edot.tracer.startSpan(probeSpanName)
      ..setString(platformAttribute, Platform.operatingSystem)
      ..end();
    await Edot.flush();

    // Long enough that the exporter's in-memory retry has given up, so anything that arrives
    // later did so because it was on disk — see [offlineWindow].
    await Future<void>.delayed(offlineWindow);

    await _signalTheHost(host);
    await Future<void>.delayed(collectorReturnWindow);

    // Online again. Deliberately after the wait, so its arrival says the collector really was
    // reachable by this point in the run.
    Edot.tracer.startSpan(reachableMarkerSpanName)
      ..setString(platformAttribute, Platform.operatingSystem)
      ..end();
    await Edot.flush();

    await Future<void>.delayed(drainWindow);
  });
}

/// Tells the host half the offline telemetry has been produced, so it can bring the collector
/// back.
///
/// Plain `HttpClient` rather than anything the Plugin traces: this call is scaffolding, and a
/// span for it would arrive as noise under the case's own service name.
///
/// A failure here is fatal to the run rather than logged. The host is waiting on this signal,
/// so swallowing it would strand both halves — the device would wait out its windows against a
/// collector that never returned, and report a buffering fault that never happened.
Future<void> _signalTheHost(String host) async {
  final client = HttpClient();
  try {
    final request = await client.post(host, signalPort, '/emitted');
    final response = await request.close();
    await response.drain<void>();
  } finally {
    client.close();
  }
}
