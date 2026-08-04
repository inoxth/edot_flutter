import 'edot.dart';
import 'edot_channel.dart';
import 'edot_tracer.dart';
import 'edot_tracing_rules.dart';
import 'edot_url.dart';

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
class EdotRequestTrace {
  EdotRequestTrace._(this._span, this._propagate);

  final EdotSpan _span;
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
      // Before start there is no tracer to hold a span. Carrying on beats throwing:
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

    final span = Edot.tracer.startSpan(
      spanNameFor(method, sanitizedUrl),
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
      shouldPropagate(url, rules.tracePropagationTargets),
    );
  }

  /// W3C Trace Context headers for this request, or empty when it carries none.
  ///
  /// Empty rather than null so a transport can add it unconditionally. Awaits the
  /// Agent, which is the one place the Plugin does (ADR-0002) — the span is already
  /// running when this happens, because the ids do not exist until it is.
  Future<Map<String, String>> traceContextHeaders() =>
      _propagate ? _span.traceContextHeaders() : Future.value(const {});

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

      if (statusCode >= 400) _span.markFailed('HTTP $statusCode');
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
    // timeout or a DNS failure from a service that answered with a 500.
    _span.recordException(error, stackTrace: stackTrace, type: type);
    _span.markFailed(type ?? error.runtimeType.toString());
  }

  /// Ends the span. Ignored if already called.
  ///
  /// Ends when the response head arrives, not when the body finishes streaming. The
  /// alternative is holding the span open for as long as the caller takes to read,
  /// which measures the caller rather than the request.
  void end() => _span.end();
}
