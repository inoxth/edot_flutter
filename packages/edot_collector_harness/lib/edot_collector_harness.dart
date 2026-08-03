/// Seam 2 test harness: runs an OpenTelemetry Collector and reads back the
/// telemetry the Plugin exported to it.
///
/// Test infrastructure only. Never published, never depended on by the Plugin.
library;

export 'src/collector_output.dart';
export 'src/collector_process.dart';
