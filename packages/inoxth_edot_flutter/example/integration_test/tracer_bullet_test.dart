import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

import 'agent_export.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // An Android emulator reaches the host through a fixed alias; an iOS simulator
  // uses localhost.
  final endpoint = Platform.isAndroid
      ? CollectorProcess.androidEmulatorEndpoint
      : CollectorProcess.hostEndpoint;

  testWidgets('agent starts, spans export, flush returns', (tester) async {
    await Edot.start(
      EdotConfig(
        serviceName: 'edot-flutter-seam2',
        serviceVersion: '0.0.1',
        deploymentEnvironment: 'integration-test',
        serverUrl: endpoint,
        debug: true,
        // Seam 2 asserts the export path, not the durability path. With disk
        // buffering on, flush() only moves spans into the Agent's on-disk buffer
        // and a separate periodic job uploads them — which never runs, because
        // the test harness kills the app as soon as the test body returns.
        android: const EdotAndroidConfig(diskBufferingEnabled: false),
      ),
    );

    expect(Edot.isStarted, isTrue);

    // A span whose duration is dominated by a real wait, so the host step can
    // check the duration reflects the operation rather than channel latency.
    final span = Edot.tracer.startSpan('tracer-bullet-span');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    span.end();

    // A second, deliberately short span. Channel jitter would show up here as a
    // duration far larger than the near-zero work performed.
    Edot.tracer.startSpan('tracer-bullet-fast').end();

    // The point of shipping flush() in this ticket: without it the host step
    // would have to wait out a batch timer.
    await flushUntilAssertable();
  });
}
