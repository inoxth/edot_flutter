import 'edot.dart';
import 'edot_channel.dart';
import 'edot_tracer.dart';
import 'edot_tracing_rules.dart';
import 'edot_url.dart';

/// Traced Marker: says a span already exists for this request.
///
/// Named after this organisation's React Native SDK's `X-Edot-RN-Traced`, which
/// solves the same problem one layer up.
///
/// It travels on the wire rather than being stripped before dispatch. The layer that
/// would strip it is the app-wide one, which only runs when app-wide tracing is
/// enabled — so stripping would make the request the service receives depend on which
/// layers happen to be on. A boolean marker is not worth that inconsistency.
const String tracedMarkerHeader = 'x-edot-flutter-traced';

/// Value of [tracedMarkerHeader]. Only its presence is ever read.
const String tracedMarkerValue = '1';

/// One outbound request being traced, whatever transport made it.
///
/// Integrations drive this rather than building spans of their own. The Elastic
/// Mobile Attribute Set (ADR-0003), the sanitiser, both exclusion rules and the
/// Trace Context decision are the same for every transport, and a second copy of
/// them is a second thing to keep in step — the two would drift the first time one
/// of them gained an attribute.
///
/// A transport is left with only what is genuinely transport-specific: reading the
/// method, URL and sizes out of its own request type, putting the returned headers
/// on it, and saying how the request finished.
///
/// A traced request is normally **two** spans: the client span, and the Request
/// Transaction it hangs under (ADR-0016). Requests started inside
/// [EdotTracer.runWithParent] are one, the ambient span being the transaction
/// already.
class EdotRequestTrace {
  EdotRequestTrace._(this._span, this._transaction, this._propagate);

  final EdotSpan _span;

  /// The Request Transaction, or null when an ambient parent already provides
  /// one (ADR-0016).
  final EdotSpan? _transaction;

  final bool _propagate;

  /// Starts tracing a request, or returns null when it must not be traced.
  ///
  /// Null means the transport should carry the request out untouched: the Plugin has
  /// not started, the request is to the Collector Host (ADR-0006), or it matches
  /// [EdotConfig.excludedUrls]. There is no span, so nothing to end and no Trace
  /// Context to send — an untraced request has no span for a header to name.
  ///
  /// [client] names the transport and reaches `http.client`, which is what tells two
  /// integrations apart in a dashboard.
  ///
  /// [requestSize] is the request body's size when the transport knows it. Absent
  /// rather than zero when it does not: a stream of unknown length has no size to
  /// report, and zero would read as an empty body.
  static EdotRequestTrace? begin({
    required String method,
    required String url,
    required String client,
    int? requestSize,
  }) {
    final rules = tracingRules;

    if (rules == null) {
      // Deliberately not buffered like other pre-start telemetry: without rules this
      // cannot tell the Collector Host from any other host, and tracing the Agent's own
      // export traffic is what ADR-0006 exists to prevent. Carrying on beats throwing —
      // a transport is usually wired up during startup, and failing the app's first
      // request over telemetry would be a poor trade.
      //
      // Sanitised even here, and even though no custom hook is configured yet: a
      // debug log is somewhere the URL is recorded, and the query string it would
      // otherwise carry is the reason the sanitiser exists.
      edotLog('request before Edot.start; not traced: ${sanitizeUrl(url)}');
      return null;
    }

    // Both exclusions match the URL as given, before sanitising — a pattern written
    // against a query parameter has to be able to see it, and an excluded request
    // produces no span, so nothing is recorded either way.
    if (isCollectorHost(url, rules.collectorHost)) return null;
    if (isExcluded(url, rules.excludedUrls)) return null;

    // Everything downstream reads the sanitised URL, never the original — including
    // the span name, which carries the host. A sanitiser that rewrites the authority
    // has to be reflected there too, or the URL would be recorded in the one place
    // nobody thought to sanitise.
    final sanitizedUrl = sanitizeUrl(url, rules.urlSanitizer);

    final attributes = <String, String>{
      'http.method': method,
      'http.url': sanitizedUrl,
      'http.client': client,
    };

    // Each of these is absent rather than empty when the URL does not yield it. An
    // attribute present with a meaningless value is worse than none.
    final derived = <String, String?>{
      'http.target': httpTarget(sanitizedUrl),
      'http.scheme': httpScheme(sanitizedUrl),
      'net.peer.name': peerName(sanitizedUrl),
    };
    derived.forEach((key, value) {
      if (value != null) attributes[key] = value;
    });

    final name = spanNameFor(method, sanitizedUrl);

    // The Request Transaction (ADR-0016). A request span with no parent is
    // classified as a *transaction* at intake, and a transaction never carries a
    // destination service — so Kibana has no exit span to draw a service map edge
    // from, and no dependency to aggregate. This gives the request one to belong to.
    //
    // Only when nothing else would: an ambient parent is already the transaction
    // this request belongs to, and wrapping it again would say the request caused
    // itself.
    //
    // Deliberately attribute-free — above all no `http.url`. The iOS Agent treats a
    // parentless span carrying that key as an HTTP span needing a parent, so a
    // Request Transaction carrying it would be wrapped in turn and one request would
    // export three spans.
    final transaction = Edot.tracer.ambientParent == null
        ? Edot.tracer.startSpan(name)
        : null;

    final span = Edot.tracer.startSpan(
      name,
      // Null falls back to the ambient parent, which is the case the Request
      // Transaction was not created for.
      parent: transaction,
      kind: EdotSpanKind.client,
      attributes: attributes,
    );

    // Integers cannot travel with the creation attributes, which are strings only,
    // so they follow immediately after.
    final port = peerPort(sanitizedUrl);
    if (port != null) span.setInt('net.peer.port', port);
    if (requestSize != null) span.setInt('http.request_body.size', requestSize);

    // Decided on the URL as given, for the same reason the exclusions are.
    return EdotRequestTrace._(
      span,
      transaction,
      shouldPropagate(url, rules.tracePropagationTargets),
    );
  }

  /// Every header a transport must put on this request.
  ///
  /// The Traced Marker always, so app-wide `dart:io` tracing knows a span already
  /// exists for this request and does not create a second one. Trace Context as well
  /// when this request propagates.
  ///
  /// One call rather than two, because a transport that added the Trace Context and
  /// forgot the marker would double-count every request it traced — and nothing about
  /// its own span would look wrong.
  ///
  /// Awaits the Agent, which is the one place the Plugin does (ADR-0002) — the span is
  /// already running when this happens, because the ids do not exist until it is.
  Future<Map<String, String>> outgoingHeaders() async => <String, String>{
    tracedMarkerHeader: tracedMarkerValue,
    // Not gated on propagation: a request left out of the target list still has a
    // span, so it still has to be recognised as already traced.
    if (_propagate) ...await _span.traceContextHeaders(),
  };

  /// Records the request body's size, for a transport that learns it only once the
  /// request has been dispatched.
  ///
  /// `dart:io` is one: its `contentLength` is set by the caller after the request
  /// object exists. Without this the app-wide path would be the one integration that
  /// never reports `http.request_body.size`.
  void recordRequestSize(int size) =>
      _span.setInt('http.request_body.size', size);

  /// Records a request the service answered.
  ///
  /// A 4xx or 5xx is a failure, and only the span status makes it visible as one
  /// without reading every attribute. It is deliberately *not* an exception: the
  /// service answered, and OpenTelemetry keeps the two apart.
  ///
  /// A null [statusCode] records no status attribute. Some transports type it
  /// nullable, and a code the Plugin did not receive is not one it can invent.
  void recordResponse({int? statusCode, int? responseSize}) {
    if (statusCode != null) {
      _span.setInt('http.status_code', statusCode);

      if (statusCode >= 400) _markFailed('HTTP $statusCode');
    }

    if (responseSize != null) {
      _span.setInt('http.response_body.size', responseSize);
    }
  }

  /// Records a request that failed before any answer arrived.
  ///
  /// [type] overrides what reaches `exception.type`, for transports whose exceptions
  /// are one class covering many causes. Left alone it is the error's runtime type.
  void recordFailure(Object error, {StackTrace? stackTrace, String? type}) {
    // The exception event carries `exception.type`, which is what separates a
    // timeout or a DNS failure from a service that answered with a 500. It stays on
    // the request span alone: duplicating it onto the Request Transaction would
    // double every error this Plugin reports.
    _span.recordException(error, stackTrace: stackTrace, type: type);
    _markFailed(type ?? error.runtimeType.toString());
  }

  /// Fails the request span, and the Request Transaction with it.
  ///
  /// Both, because the transaction is the only thing Kibana's error rate reads for
  /// this request. A transaction reporting success over an exit span that failed is
  /// worse than one reporting nothing: it is confidently wrong.
  void _markFailed(String description) {
    _span.markFailed(description);
    _transaction?.markFailed(description);
  }

  /// Ends the span, and the Request Transaction after it. Ignored if already called.
  ///
  /// Ends when the response head arrives, not when the body finishes streaming. The
  /// alternative is holding the span open for as long as the caller takes to read,
  /// which measures the caller rather than the request.
  ///
  /// The transaction ends second so that it encloses the request rather than
  /// finishing inside it — it started first, and a parent outliving its child is what
  /// makes the pair readable as one operation.
  void end() {
    _span.end();
    _transaction?.end();
  }
}
