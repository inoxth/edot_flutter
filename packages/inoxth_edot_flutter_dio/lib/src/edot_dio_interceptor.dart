import 'dart:convert';

import 'package:dio/dio.dart';
// The integration surface, not the app-facing one — see its own library doc.
import 'package:inoxth_edot_flutter/instrumentation.dart';

/// Traces the requests a `Dio` instance makes.
///
/// Add it to the instance the app already uses:
///
/// ```dart
/// dio.interceptors.add(EdotDioInterceptor());
/// ```
///
/// Every request becomes one client span carrying the Elastic Mobile Attribute Set
/// (ADR-0003) and the Active View's screen attributes, and a traced request carries
/// W3C Trace Context. All of that comes from [EdotRequestTrace], the same object
/// `EdotHttpClient` drives, so the two integrations cannot drift apart: the
/// sanitiser, both exclusion rules and the propagation decision are applied in one
/// place for both.
///
/// Add it last if the app has other interceptors that change the request. An
/// interceptor added after this one runs after it, so a URL it rewrites is recorded
/// as it was before the rewrite.
class EdotDioInterceptor extends Interceptor {
  /// Creates the interceptor. It holds no state; one instance can serve several
  /// `Dio` instances, because a request's own span travels with the request.
  EdotDioInterceptor();

  /// Value of `http.client`, naming the transport that produced the span.
  static const String _clientName = 'dio';

  /// Where a request's span is kept between the callbacks.
  ///
  /// Dio hands `onRequest`, `onResponse` and `onError` no shared state but the
  /// request itself, and a field here could not work: several requests are in flight
  /// at once and would overwrite each other's span.
  static const String _traceKey = 'inoxth_edot_flutter_dio.trace';

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final trace = EdotRequestTrace.begin(
      method: options.method,
      url: options.uri.toString(),
      client: _clientName,
      requestSize: _requestSize(options),
    );

    // Not traced: the Collector Host, an excluded URL, or before the Plugin started.
    if (trace == null) {
      handler.next(options);
      return;
    }

    // Stored before the await, so a request cancelled while the Trace Context is in
    // flight still reaches `onError` with a span to end.
    options.extra[_traceKey] = trace;

    // Awaiting here is safe: Dio waits on the handler rather than on this method
    // returning, so the request does not proceed until `next` is called.
    //
    // Overwrites a `traceparent` header the caller set, for the reason
    // `EdotHttpClient` does — it names the immediate parent of the request, and that
    // is now this span.
    options.headers.addAll(await trace.traceContextHeaders());

    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _finish(response.requestOptions, (trace) {
      trace.recordResponse(
        statusCode: response.statusCode,
        responseSize: _responseSize(response.headers),
      );
    });

    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _finish(err.requestOptions, (trace) {
      final response = err.response;

      // A status code Dio rejected is still an answer. Dio raises 4xx and 5xx as
      // exceptions where `EdotHttpClient` returns them as responses, and recording
      // that difference would put an exception event on one integration's 500 spans
      // and not the other's — so it is recorded as the answer it is.
      if (response != null) {
        trace.recordResponse(
          statusCode: response.statusCode,
          responseSize: _responseSize(response.headers),
        );
        return;
      }

      // Nothing answered. The type is Dio's own, because `DioException` alone covers
      // a cancellation, four kinds of timeout and a refused connection alike, and
      // telling those apart is most of what `exception.type` is read for.
      trace.recordFailure(
        err,
        stackTrace: err.stackTrace,
        type: err.type.toString(),
      );
    });

    handler.next(err);
  }

  /// Runs [record] against the request's span, then ends it.
  ///
  /// Absent for an untraced request, and for one whose span another interceptor
  /// already ended by resolving the request without running the rest of the chain.
  void _finish(
    RequestOptions options,
    void Function(EdotRequestTrace trace) record,
  ) {
    final trace = options.extra.remove(_traceKey);
    if (trace is! EdotRequestTrace) return;

    record(trace);
    trace.end();
  }

  /// Size of the request body, when it can be known before the request is sent.
  ///
  /// [FormData] is included because `EdotHttpClient` reports a size for a multipart
  /// upload — `http.MultipartRequest` computes its own content length — and an
  /// attribute one integration can produce and the other cannot is exactly the drift
  /// this Plugin is meant not to have.
  ///
  /// Null for anything else, including a `Map`: Dio's transformers turn that into
  /// JSON after this interceptor runs, so its encoded size does not exist yet. Absent
  /// rather than guessed — a wrong body size is worse than none.
  static int? _requestSize(RequestOptions options) {
    final data = options.data;

    if (data is String) return utf8.encode(data).length;
    if (data is List<int>) return data.length;
    if (data is FormData) return data.length;

    return null;
  }

  /// Size the response announced, or null when it announced none — a chunked
  /// response has no length to report.
  static int? _responseSize(Headers headers) {
    final declared = headers.value(Headers.contentLengthHeader);
    if (declared == null) return null;

    return int.tryParse(declared);
  }
}
