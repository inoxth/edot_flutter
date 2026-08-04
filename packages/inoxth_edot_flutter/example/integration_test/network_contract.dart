/// Shared contract between the two halves of the network tracing test.
///
/// Deliberately free of Flutter imports: the host half runs under plain
/// `dart run`, where `dart:ui` does not exist.
library;

/// Requested with a query string the sanitiser must remove, and a path segment the
/// configured sanitiser hook must collapse.
const String tracedPath = '/orders/42';

/// What `http.target` must read after both stages of sanitising.
const String sanitizedTarget = '/orders/{id}';

/// Must never appear in exported telemetry. Sent as a query parameter, which is
/// where tokens actually leak from.
const String secretQueryValue = 'must-not-be-exported';

/// Answered with 500 — a failure the server reported, not a transport failure.
const String failingPath = '/boom';

/// Configured as excluded, so it must produce no span at all.
const String excludedPath = '/health';

/// Nothing listens here, so the request fails in transport rather than answering.
/// That is what separates a timeout or refusal from a server error.
const String unreachablePath = '/unreachable';

/// Requested inside an ambient parent span.
///
/// The Agent only manufactures a parent for a *root* HTTP span, so this one must
/// come back parented under [ambientParentSpanName] on both platforms — which is
/// what makes the workaround documented on `EdotHttpClient` a tested claim rather
/// than an assertion in a doc comment.
/// Deliberately not under `/orders/`: the configured hook collapses that to
/// [sanitizedTarget], and two requests sharing a target could not be told apart.
const String parentedPath = '/parented';
const String ambientParentSpanName = 'network-ambient-parent';

/// Requested against the Collector Host, which must produce no span at any path.
const String collectorPath = '/v1/traces';

const String screenName = 'Orders';

/// Carries the platform, so the host half can assert the iOS-only synthetic parent
/// span (ADR-0001). Deliberately not an HTTP span, so it gets no parent itself.
const String controlSpanName = 'network-control';
const String platformAttribute = 'test.platform';

/// Wire names, per ADR-0003. Restated here rather than imported: a contract that
/// read them from the code it checks could only prove the code equals itself.
const String methodAttribute = 'http.method';
const String urlAttribute = 'http.url';
const String targetAttribute = 'http.target';
const String schemeAttribute = 'http.scheme';
const String statusAttribute = 'http.status_code';
const String requestSizeAttribute = 'http.request_body.size';
const String responseSizeAttribute = 'http.response_body.size';
const String clientAttribute = 'http.client';
const String peerNameAttribute = 'net.peer.name';
const String peerPortAttribute = 'net.peer.port';
const String exceptionTypeAttribute = 'exception.type';
const String screenNameAttribute = 'screen.name';

/// Event name OpenTelemetry gives a recorded exception.
const String exceptionEventName = 'exception';
