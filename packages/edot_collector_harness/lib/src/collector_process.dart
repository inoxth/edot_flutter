import 'dart:io';

import 'collector_output.dart';

/// Runs the Seam 2 collector via Docker Compose and reads back what the Plugin
/// exported to it.
///
/// Integration tests should skip when [isAvailable] is false rather than fail,
/// so the Dart tier stays runnable on a machine without Docker. Skipping must be
/// visible in the test output — a silently skipped Seam 2 tier reads as passing
/// coverage it does not have.
class CollectorProcess {
  CollectorProcess({
    required this.composeDirectory,
    required this.outputDirectory,
  });

  /// Directory holding `docker-compose.yaml` and the collector config.
  final Directory composeDirectory;

  /// Host directory the collector writes telemetry into.
  final Directory outputDirectory;

  static const String _outputFileName = 'telemetry.jsonl';

  /// OTLP/HTTP endpoint as seen from the host and from an iOS simulator.
  static const String hostEndpoint = 'http://localhost:4318';

  /// OTLP/HTTP endpoint as seen from an Android emulator, which reaches the host
  /// through a fixed alias rather than localhost.
  static const String androidEmulatorEndpoint = 'http://10.0.2.2:4318';

  File get outputFile => File('${outputDirectory.path}/$_outputFileName');

  /// Whether Docker is installed *and* running. Both are required, and an
  /// installed-but-stopped daemon is the common case worth distinguishing.
  static Future<bool> get isAvailable async {
    try {
      final result = await Process.run('docker', const ['info']);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// Starts the collector and waits until it accepts connections.
  Future<void> start({Duration timeout = const Duration(seconds: 60)}) async {
    if (!outputDirectory.existsSync()) {
      outputDirectory.createSync(recursive: true);
    }
    // Start from a clean slate so assertions cannot see a previous run's spans.
    await reset();

    await _compose(['up', '--detach', '--wait']);
    await _awaitReady(timeout);
  }

  Future<void> stop() => _compose(['down', '--volumes']);

  /// Truncates collected telemetry, so one collector can serve several tests.
  Future<void> reset() async {
    if (outputFile.existsSync()) await outputFile.delete();
  }

  /// Reads everything exported so far.
  ///
  /// Only whole lines. The collector appends while this reads, so the last line
  /// can be half-written — and [CollectorOutput.parse] throws on a malformed line
  /// by design, which would otherwise turn a mid-write read into a spurious
  /// failure. An unterminated final line has not finished being written, so it is
  /// not yet a line; the next poll will see it complete.
  CollectorOutput read() {
    if (!outputFile.existsSync()) return CollectorOutput.parse(const []);

    final content = outputFile.readAsStringSync();
    final lines = content.split('\n');
    if (!content.endsWith('\n') && lines.isNotEmpty) lines.removeLast();

    return CollectorOutput.parse(lines);
  }

  /// Waits until [predicate] is satisfied by the exported telemetry.
  ///
  /// Tests should call the Plugin's flush first; this only absorbs the
  /// collector's own write latency, not a batch timer.
  Future<CollectorOutput> waitFor(
    bool Function(CollectorOutput) predicate, {
    Duration timeout = const Duration(seconds: 15),
    Duration pollInterval = const Duration(milliseconds: 200),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var latest = read();

    while (!predicate(latest)) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          'Collector output did not satisfy the predicate within $timeout. '
          'Saw ${latest.spans.length} span(s), ${latest.logs.length} log(s) and '
          '${latest.metrics.length} metric(s).\n'
          '  spans: ${latest.spans.map((s) => s.name).toList()}\n'
          '  metrics: ${latest.metrics.map((m) => m.name).toSet().toList()}',
        );
      }
      await Future<void>.delayed(pollInterval);
      latest = read();
    }

    return latest;
  }

  Future<void> _awaitReady(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      try {
        final socket = await Socket.connect(
          'localhost',
          4318,
          timeout: const Duration(seconds: 1),
        );
        socket.destroy();
        return;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }

    throw TimeoutException('Collector did not become ready within $timeout');
  }

  Future<void> _compose(List<String> args) async {
    final result = await Process.run(
      'docker',
      ['compose', ...args],
      workingDirectory: composeDirectory.path,
      environment: {'EDOT_COLLECTOR_OUTPUT_DIR': outputDirectory.absolute.path},
    );

    if (result.exitCode != 0) {
      throw StateError(
        'docker compose ${args.join(' ')} failed (${result.exitCode}):\n'
        '${result.stdout}\n${result.stderr}',
      );
    }
  }
}

/// Raised when the collector does not produce expected telemetry in time.
class TimeoutException implements Exception {
  TimeoutException(this.message);

  final String message;

  @override
  String toString() => 'TimeoutException: $message';
}
