import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:test/test.dart';

/// Reading is exercised without Docker: `read` only touches the output file, and
/// the case that matters is what it does while the collector is still writing it.
void main() {
  late Directory output;
  late CollectorProcess collector;

  setUp(() {
    output = Directory.systemTemp.createTempSync('edot-harness-test-');
    collector = CollectorProcess(
      composeDirectory: Directory('unused'),
      outputDirectory: output,
    );
  });

  tearDown(() => output.deleteSync(recursive: true));

  const span =
      '{"resourceSpans":[{"scopeSpans":[{"spans":[{"name":"complete"}]}]}]}';

  test('reads nothing before the collector has written anything', () {
    expect(collector.read().spans, isEmpty);
  });

  test('reads whole lines', () {
    collector.outputFile.writeAsStringSync('$span\n');

    expect(collector.read().spanNamed('complete').name, 'complete');
  });

  test('ignores a final line the collector is still writing', () {
    // The collector appends while tests poll, so a read can land mid-write.
    // Parsing a half-written line would throw — CollectorOutput.parse rejects
    // malformed lines deliberately — turning a timing artefact into a failure.
    collector.outputFile.writeAsStringSync('$span\n{"resourceSpans":[{"scope');

    final read = collector.read();

    expect(read.spans, hasLength(1));
    expect(read.spanNamed('complete').name, 'complete');
  });

  test('reads that line once it is terminated', () {
    collector.outputFile.writeAsStringSync('$span\n');
    expect(collector.read().spans, hasLength(1));

    collector.outputFile.writeAsStringSync(
      '${span.replaceFirst('complete', 'second')}\n',
      mode: FileMode.append,
    );

    expect(collector.read().spans, hasLength(2));
  });

  test('still refuses a malformed line that is terminated', () {
    // Only an *unterminated* line is treated as unfinished. A complete line that
    // does not parse is a real problem and must not be swallowed.
    collector.outputFile.writeAsStringSync('{not json\n');

    expect(() => collector.read(), throwsA(isA<FormatException>()));
  });
}
