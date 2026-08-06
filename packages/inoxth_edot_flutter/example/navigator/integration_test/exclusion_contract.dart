/// Shared contract between the two halves of the Collector Host exclusion test.
///
/// The device half emits, the host half asserts, and they run in different
/// processes — so anything both must agree on lives here. Deliberately free of
/// Flutter imports, because the host half runs under plain `dart run` where
/// `dart:ui` does not exist.
library;

import 'package:edot_collector_harness/edot_collector_harness.dart';

/// Where the device exports to. Its host is the Collector Host (ADR-0006).
const String serverUrl = CollectorProcess.hostEndpoint;

/// Host component of [serverUrl] — the only thing the exclusion compares.
const String collectorHost = 'localhost';

/// A host that resolves to the same machine but is a different host *string*.
///
/// ADR-0006 compares hosts, so this is genuinely a different host as far as the
/// exclusion is concerned, and traffic to it must still be traced.
const String aliasHost = '127.0.0.1';

/// Requests the device makes from native code, mapped to whether a span should
/// result.
///
/// The interesting cases are the near misses. Same host on a different port must
/// still be excluded, because ADR-0006 compares no port; a different host on the
/// configured port must still be traced, because the host is all that is
/// compared.
const Map<String, bool> probeRequests = <String, bool>{
  // Collector Host, a path the Agent never uses — exclusion must not depend on a
  // known-path allowlist, which is what leaked twice in the React Native SDK.
  'http://$collectorHost:4318/definitely/not/an/otlp/path': false,
  // Collector Host, different port — exclusion must not compare ports.
  'http://$collectorHost:4317/': false,
  // The Agent's central-configuration path, reproduced exactly.
  //
  // Probed rather than waited for. The Agent polls this itself, but on a 60s
  // timer whose first tick lands before the replacement instrumentation is
  // installed — so asserting on the Agent's own poll would pass whether or not
  // the exclusion works, and would keep passing if a future Agent changed the
  // interval. Issuing the same request from the probe makes the assertion
  // deterministic: this request definitely happened, and no span may result.
  //
  // Note the path is not under `/v1/`, which is why ADR-0006 rejects a path
  // allowlist — this is the request that leaked when one was tried.
  'http://$collectorHost:4318/config/v1/agents?service.name=edot-flutter-seam2':
      false,
  // Different host, configured port — must still be traced.
  'http://$aliasHost:4318/': true,
};

/// Span the device creates itself, as a positive control.
///
/// Without it a run proves nothing: an absence of feedback spans would be
/// indistinguishable from nothing having been exported at all.
const String controlSpanName = 'exclusion-control-span';
