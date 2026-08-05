import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

import 'agent_export.dart';
import 'parenting_contract.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final endpoint = Platform.isAndroid
      ? CollectorProcess.androidEmulatorEndpoint
      : CollectorProcess.hostEndpoint;

  testWidgets('parent-child structure survives export', (tester) async {
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

    // A parent with two children, one of them created after awaits.
    final parent = Edot.tracer.startSpan(parentSpanName);
    await Edot.tracer.runWithParent(parent, () async {
      Edot.tracer.startSpan(childSpanName).end();

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      Edot.tracer.startSpan(awaitedChildSpanName).end();
    });
    parent.end();

    // No ambient scope, no explicit parent: a root in its own trace.
    Edot.tracer.startSpan(rootSpanName).end();

    // Two flows interleaved so their children are created in the opposite order
    // to their parents. This is the arrangement that crosses the wires if
    // parenting is "whichever span started most recently".
    final flowOne = Edot.tracer.startSpan(flowOneParentName);
    final flowTwo = Edot.tracer.startSpan(flowTwoParentName);

    Future<void> flow(EdotSpan parent, String child, Duration delay) =>
        Edot.tracer.runWithParent(parent, () async {
          await Future<void>.delayed(delay);
          Edot.tracer.startSpan(child).end();
        });

    await Future.wait([
      flow(flowOne, flowOneChildName, const Duration(milliseconds: 20)),
      flow(flowTwo, flowTwoChildName, const Duration(milliseconds: 5)),
    ]);
    flowOne.end();
    flowTwo.end();

    // An explicit parent must win over the ambient one. The ambient scope here is
    // `parent`, which is already ended — so if the explicit argument were ignored
    // this child would export as a root, not merely under the wrong parent.
    final explicitParent = Edot.tracer.startSpan(explicitParentName);
    Edot.tracer.runWithParent(parent, () {
      Edot.tracer.startSpan(explicitChildName, parent: explicitParent).end();
    });
    explicitParent.end();

    // Naming a parent that has already ended. The Agent no longer holds it, so
    // the child must become a root rather than silently attaching to something.
    final endedParent = Edot.tracer.startSpan(endedParentName);
    endedParent.end();
    Edot.tracer.startSpan(orphanedChildName, parent: endedParent).end();

    await flushUntilAssertable();
  });
}
