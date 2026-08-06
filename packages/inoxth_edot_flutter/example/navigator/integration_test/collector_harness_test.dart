import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Seam 2 — telemetry as it arrives at a real collector.
///
/// This ticket only proves the harness can start a collector and read its output.
/// Assertions about actual Plugin telemetry begin with the tracer-bullet ticket,
/// once the Agent is initialised and spans exist to export.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late CollectorProcess collector;
  var dockerAvailable = false;

  setUpAll(() async {
    dockerAvailable = await CollectorProcess.isAvailable;
    if (!dockerAvailable) return;

    collector = CollectorProcess(
      composeDirectory: Directory('../../../tool/collector'),
      outputDirectory: Directory.systemTemp.createTempSync('edot-collector-'),
    );
    await collector.start();
  });

  tearDownAll(() async {
    if (dockerAvailable) await collector.stop();
  });

  test('collector starts and its output is readable', () async {
    // Skipping is deliberate rather than a silent pass: a Seam 2 tier that
    // quietly does nothing reads as coverage it does not have.
    if (!dockerAvailable) {
      markTestSkipped('Docker is not running — Seam 2 skipped, NOT passed.');
      return;
    }

    // No telemetry has been sent, so an empty read is the correct result. What is
    // being verified is that the harness reads the collector without error.
    final output = collector.read();

    expect(output.spans, isEmpty);
    expect(output.logs, isEmpty);
  });
}
