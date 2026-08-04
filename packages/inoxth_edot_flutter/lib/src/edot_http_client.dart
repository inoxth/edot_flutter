import 'package:http/http.dart' as http;

import 'edot.dart';
import 'edot_channel.dart';
import 'edot_tracer.dart';
import 'edot_tracing_rules.dart';
import 'edot_url.dart';

/// An `http.Client` that traces what passes through it.
///
/// Wrap the client the app already uses:
///
/// ```dart
/// final client = EdotHttpClient(http.Client());
/// ```
///
/// Each request becomes one client span carrying the Elastic Mobile Attribute Set
/// (ADR-0003) and the Active View's screen attributes. Requests to the Collector
/// Host (ADR-0006) and to any URL matched by [EdotConfig.excludedUrls] pass through
/// untraced.
///
/// Only requests made through this client are traced. `dart:io` reaches the network
/// through its own sockets, so a request made with a bare `HttpClient` is invisible
/// here — and to the Agent's native instrumentation too.
///
/// **One request shows up as two spans on iOS.** The Agent treats any span carrying
/// `http.url` as an HTTP span, and gives one with no parent a synthetic parent span
/// so it belongs to a transaction, as Elastic APM's data model expects. The extra
/// span shares this one's name and timing and carries no attributes of its own.
/// Android does not do this, so request counts differ between the platforms. See
/// ADR-0001. Starting the request inside [EdotTracer.runWithParent] avoids it,
/// because the Agent only adds a parent to a span that has none.
class EdotHttpClient extends http.BaseClient {
  EdotHttpClient(this._inner);

  final http.Client _inner;

  /// Value of `http.client`, naming the transport that produced the span.
  static const String _clientName = 'http';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final rules = tracingRules;
    final url = request.url.toString();

    if (rules == null) {
      // Before start there is no tracer to hold a span. Passing the request
      // through beats throwing: a client is usually wired up during startup, and
      // failing the app's first request over telemetry would be a poor trade.
      //
      // Sanitised even here, and even though no custom hook is configured yet: a
      // debug log is somewhere the URL is recorded, and the query string it would
      // otherwise carry is the reason the sanitiser exists.
      edotLog('request before Edot.start; not traced: ${sanitizeUrl(url)}');
      return _inner.send(request);
    }

    // Both exclusions match the URL as given, before sanitising — a pattern
    // written against a query parameter has to be able to see it, and an excluded
    // request produces no span, so nothing is recorded either way.
    if (isCollectorHost(url, rules.collectorHost)) return _inner.send(request);
    if (isExcluded(url, rules.excludedUrls)) return _inner.send(request);

    return _traced(request, sanitizeUrl(url, rules.urlSanitizer));
  }

  /// Everything downstream reads [sanitizedUrl], never the original.
  ///
  /// Including the span name, which carries the host: a sanitiser that rewrites the
  /// authority has to be reflected there too, or the URL would be recorded in the
  /// one place nobody thought to sanitise.
  Future<http.StreamedResponse> _traced(
    http.BaseRequest request,
    String sanitizedUrl,
  ) async {
    final attributes = <String, String>{
      'http.method': request.method,
      'http.url': sanitizedUrl,
      'http.client': _clientName,
    };

    // Each of these is absent rather than empty when the URL does not yield it.
    // An attribute present with a meaningless value is worse than none.
    final derived = <String, String?>{
      'http.target': httpTarget(sanitizedUrl),
      'http.scheme': httpScheme(sanitizedUrl),
      'net.peer.name': peerName(sanitizedUrl),
    };
    derived.forEach((key, value) {
      if (value != null) attributes[key] = value;
    });

    final span = Edot.tracer.startSpan(
      spanNameFor(request.method, sanitizedUrl),
      kind: EdotSpanKind.client,
      attributes: attributes,
    );

    final port = peerPort(sanitizedUrl);
    if (port != null) span.setInt('net.peer.port', port);

    // Null whenever the body is a stream of unknown length, which is not an error
    // — there is simply no size to report yet.
    final requestSize = request.contentLength;
    if (requestSize != null) span.setInt('http.request_body.size', requestSize);

    try {
      final response = await _inner.send(request);

      span.setInt('http.status_code', response.statusCode);

      final responseSize = response.contentLength;
      if (responseSize != null) {
        span.setInt('http.response_body.size', responseSize);
      }

      // A response arrived, so this is not an exception — but 4xx and 5xx are
      // still failures, and only the span status makes them visible as such
      // without reading every attribute.
      if (response.statusCode >= 400) {
        span.markFailed('HTTP ${response.statusCode}');
      }

      return response;
    } catch (error, stackTrace) {
      // The exception event carries `exception.type`, which is what separates a
      // timeout or a DNS failure from a server that answered with a 500.
      span.recordException(error, stackTrace: stackTrace);
      span.markFailed(error.runtimeType.toString());
      rethrow;
    } finally {
      // Ends when the response head arrives, not when the body finishes streaming.
      // The alternative is holding the span open for as long as the caller takes to
      // read, which measures the caller rather than the request.
      span.end();
    }
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
