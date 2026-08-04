// Seam 2, host half — asserts the exported parent-child structure.
//
//   dart run tool/verify_span_parenting.dart -d <device>
//
// Exits non-zero with a report listing every failed assertion.
import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';

import '../integration_test/parenting_contract.dart';

final _failures = <String>[];

Future<void> main(List<String> args) async {
  final collector = CollectorProcess(
    composeDirectory: Directory('../../../tool/collector'),
    outputDirectory: Directory.systemTemp.createTempSync('edot-collector-'),
  );

  if (!await CollectorProcess.isAvailable) {
    stderr.writeln(
      'Docker is not available, so there is no collector to assert against.\n'
      'Seam 2 cannot run. Start Docker and try again.',
    );
    exit(2);
  }

  stdout.writeln('==> starting collector');
  await collector.start();

  try {
    stdout.writeln('==> running the device half');
    final device = await _runDeviceHalf(args);
    if (device != 0) {
      stderr.writeln(
        'The device half failed; not asserting on partial output.',
      );
      exit(device);
    }

    stdout.writeln('==> reading exported telemetry');
    final output = await collector.waitFor(
      (o) => _allNames.every((name) => o.spansNamed(name).isNotEmpty),
    );

    _report(output);
    _assertNesting(output);
  } finally {
    await collector.stop();
  }

  if (_failures.isEmpty) {
    stdout.writeln('\nParent-child structure survived export.');
    return;
  }

  stderr.writeln('\nSpan parenting failed:');
  for (final failure in _failures) {
    stderr.writeln('  - $failure');
  }
  exit(1);
}

const _allNames = <String>[
  parentSpanName,
  childSpanName,
  awaitedChildSpanName,
  rootSpanName,
  flowOneParentName,
  flowTwoParentName,
  flowOneChildName,
  flowTwoChildName,
  explicitParentName,
  explicitChildName,
];

Future<int> _runDeviceHalf(List<String> args) async {
  final process = await Process.start('flutter', [
    'test',
    'integration_test/span_parenting_test.dart',
    ...args,
  ], mode: ProcessStartMode.inheritStdio);

  return process.exitCode;
}

void _report(CollectorOutput output) {
  for (final name in _allNames) {
    final span = output.spanNamed(name);
    final parent = span.parentSpanId == null
        ? 'root'
        : 'parent=${span.parentSpanId}';
    stdout.writeln('    $name  span=${span.spanId}  $parent');
  }
}

void _assertNesting(CollectorOutput output) {
  final parent = output.spanNamed(parentSpanName);

  _expectChildOf(output.spanNamed(childSpanName), parent, 'direct child');
  _expectChildOf(
    output.spanNamed(awaitedChildSpanName),
    parent,
    'child created after awaits',
  );

  // No ambient and no explicit parent. Asserted as a genuine root rather than
  // merely "not a child of parent", and in a trace of its own — otherwise a stray
  // ambient parent leaking in would still pass.
  final root = output.spanNamed(rootSpanName);
  if (root.parentSpanId != null) {
    _failures.add(
      '$rootSpanName has parent ${root.parentSpanId}, expected to be a root',
    );
  }
  if (root.traceId == parent.traceId) {
    _failures.add(
      '$rootSpanName shares trace ${root.traceId} with $parentSpanName, so an '
      'ambient parent leaked into a span that should have started a new trace',
    );
  }

  // The interleaving case. Each child must belong to its own flow; a crossed pair
  // is the specific failure this design exists to prevent.
  _expectChildOf(
    output.spanNamed(flowOneChildName),
    output.spanNamed(flowOneParentName),
    'first interleaved flow',
  );
  _expectChildOf(
    output.spanNamed(flowTwoChildName),
    output.spanNamed(flowTwoParentName),
    'second interleaved flow',
  );

  // Explicit parent beats the ambient one.
  _expectChildOf(
    output.spanNamed(explicitChildName),
    output.spanNamed(explicitParentName),
    'explicit parent overriding the ambient one',
  );
}

void _expectChildOf(ExportedSpan child, ExportedSpan parent, String what) {
  if (child.parentSpanId != parent.spanId) {
    _failures.add(
      '$what: ${child.name} has parent ${child.parentSpanId ?? 'none'}, '
      'expected ${parent.name} (${parent.spanId})',
    );
    return;
  }

  // A parent link with a different trace id would not form a usable tree.
  if (child.traceId != parent.traceId) {
    _failures.add(
      '$what: ${child.name} is in trace ${child.traceId} but its parent '
      '${parent.name} is in ${parent.traceId}',
    );
  }
}
