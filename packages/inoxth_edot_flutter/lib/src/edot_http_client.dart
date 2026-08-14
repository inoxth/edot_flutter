import 'package:http/http.dart' as http;

import 'edot_request_trace.dart';
import 'edot_tracer.dart';

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
/// A traced request also carries W3C Trace Context, so the spans it causes in the
/// services it reaches join this trace. [EdotConfig.tracePropagationTargets]
/// narrows which requests do; an untraced request never does, having no span to
/// name.
///
/// What is recorded and what is excluded lives in [EdotRequestTrace], shared with
/// the Dio integration so the two transports cannot drift apart. Only reading a
/// request and a response is this class's own work.
///
/// Only requests made through this client are traced. `dart:io` reaches the network
/// through its own sockets, so a request made with a bare `HttpClient` is invisible
/// here — and to the Agent's native instrumentation too.
///
/// **One request shows up as two spans, on both platforms.** Elastic's data model
/// expects a span to belong to a transaction, and a parentless one is recorded as a
/// transaction itself — carrying no destination, so nothing links the app to what it
/// called. The Plugin therefore gives each request a Request Transaction to hang
/// under: same name and timing, no attributes of its own (ADR-0016). Starting the
/// request inside [EdotTracer.runWithParent] produces one span instead, the ambient
/// span being the transaction already.
class EdotHttpClient extends http.BaseClient {
  /// Wraps the client that actually performs the requests. Pass an existing
  /// configured client, or a plain `http.Client()` to trace directly.
  EdotHttpClient(this._inner);

  final http.Client _inner;

  /// Value of `http.client`, naming the transport that produced the span.
  static const String _clientName = 'http';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final trace = EdotRequestTrace.begin(
      method: request.method,
      url: request.url.toString(),
      client: _clientName,
      // Null whenever the body is a stream of unknown length, which is not an error
      // — there is simply no size to report yet.
      requestSize: request.contentLength,
    );

    // Not traced: the Collector Host, an excluded URL, or before the Plugin started.
    if (trace == null) return _inner.send(request);

    try {
      // Inside the try so the span still ends if this throws — a request that has
      // already been sent once rejects new headers, and a span left unended would
      // sit in the Agent's registry for the life of the process.
      //
      // Overwrites a `traceparent` header the caller set. It names the immediate
      // parent of the request, and once this client has wrapped it that is this
      // span; leaving an outer context in place would parent the receiving
      // service's work to something that did not make the call.
      request.headers.addAll(await trace.outgoingHeaders());

      final response = await _inner.send(request);

      trace.recordResponse(
        statusCode: response.statusCode,
        responseSize: response.contentLength,
        // Reaches `exception.message` on a 4xx or 5xx. Nullable on this transport,
        // and absent rather than invented when the service sent none.
        reasonPhrase: response.reasonPhrase,
      );

      return response;
    } catch (error, stackTrace) {
      trace.recordFailure(error, stackTrace: stackTrace);
      rethrow;
    } finally {
      trace.end();
    }
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
