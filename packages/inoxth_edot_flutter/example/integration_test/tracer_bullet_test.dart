import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

/// Seam 2, device half — emits telemetry through the real Agent.
///
/// This code runs **on the device**, which cannot read the collector's output
/// file on the host. So the assertions live in a host-side step that runs after
/// this one: see `tool/verify_tracer_bullet.dart`.
///
/// What this half proves on its own: the Agent initialises against a real
/// endpoint, spans can be created and ended, and `flush()` returns without
/// error. What arrived is the host step's job.
/// How long iOS needs after `flush()` before the persistence worker has
/// uploaded.
///
/// The default `PersistencePerformancePreset` keeps a file writable for up to
/// 4.75s, refuses to read one younger than 5.25s, and re-schedules exports on a
/// ~5s delay. Worst case is therefore around 11s; 15s leaves margin without
/// making the tier slow enough to skip.
const _iosPersistenceUploadWindow = Duration(seconds: 15);

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
    await Edot.flush();

    // On Android flush() is sufficient: the span is on the wire before this
    // returns, and the host half asserts immediately.
    //
    // On iOS it is not. apm-agent-ios wraps its OTLP exporter in
    // PersistenceSpanExporterDecorator, and the batch processor's forceFlush
    // calls the exporter's `export` but never its `flush` — so flush() leaves
    // spans in the on-disk buffer and only the persistence worker's own timer
    // uploads them. See ADR-0011. The wait covers that timer; without it the app
    // is killed with the spans still on disk.
    if (Platform.isIOS) {
      await Future<void>.delayed(_iosPersistenceUploadWindow);
    }
  });
}
