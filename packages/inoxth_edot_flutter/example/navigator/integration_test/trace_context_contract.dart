/// Shared contract between the two halves of the Trace Context test.
///
/// Deliberately free of Flutter imports: the host half runs under plain
/// `dart run`, where `dart:ui` does not exist.
///
/// **What this suite can and cannot prove.** There is no separate service in the
/// harness, so the service that receives the request is stood in for by the device's
/// own loopback server, which records the headers it saw onto a span of its own. The
/// assertion is therefore that the `traceparent` the service received names the
/// exported client span exactly — same trace id, same span id. That is precisely the
/// context a real service would parent its own span to, so a mismatch here is a
/// broken link there. Extracting a remote parent is not this Plugin's job and is not
/// implemented.
library;

/// Matched by [propagationTarget], so this request must carry Trace Context.
const String propagatedPath = '/propagated';

/// Traced, but not matched by the target list — so a span, and no Trace Context.
const String plainPath = '/plain';

/// Excluded by configuration: performed, never traced, and therefore never
/// propagated. The service still sees the request, which is what lets the host half
/// assert the absence of the header rather than infer it from the absent span.
const String excludedPath = '/health';

/// Configured as the only propagation target. A substring pattern, which is the
/// form an integrator reaches for first.
const String propagationTarget = propagatedPath;

/// Requested against the Collector Host, which produces no span at any path
/// (ADR-0006) and so has no context to send. Its absence is asserted as a missing
/// span: the request goes to the collector rather than to the loopback server, so
/// the headers it carried are not observable here. Seam 1 asserts the header
/// directly.
const String collectorPath = '/v1/traces';

/// A span standing in for the service that received a request.
///
/// Started by the loopback server's own handler, outside any ambient parent, so it
/// is a root of its own trace — the point being what it *recorded*, not where it sat.
const String downstreamSpanName = 'downstream-service';

/// Which request a [downstreamSpanName] span answered.
const String requestedPathAttribute = 'test.request.path';

/// The `traceparent` the service received, or [absentHeader].
const String receivedTraceparentAttribute = 'test.received.traceparent';

/// Every header name the service received, lowercased and comma-joined.
///
/// Recorded as a list rather than as one flag per header so the deprecated
/// `elastic-apm-traceparent` is asserted absent from what actually arrived, rather
/// than from what the test thought to look for.
const String receivedHeadersAttribute = 'test.received.headers';

/// Stands in for a header that did not arrive. An attribute that is simply missing
/// cannot be told apart from one the Plugin failed to record.
const String absentHeader = 'none';

/// Elastic's own header, deprecated, which must never be sent.
const String legacyHeaderName = 'elastic-apm-traceparent';

/// The Request Transaction each request hangs under (ADR-0016) needs no allowance
/// here, unlike in the network suite. It carries none of the attributes either lookup
/// keys on — no `http.target`, and not [downstreamSpanName] — so it cannot be mistaken
/// for either span this suite reads.
///
/// Wire names, per ADR-0003. Restated here rather than imported: a contract that
/// read them from the code it checks could only prove the code equals itself.
const String urlAttribute = 'http.url';
const String targetAttribute = 'http.target';
