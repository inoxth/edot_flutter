import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'edot_request_trace.dart';

/// Whether an outer layer has already created a span for this request.
///
/// Synchronous, and reads nothing but the request in hand. Remembering elsewhere which
/// request is being traced cannot work: a Dio interceptor returns before the request is
/// dispatched, so the dispatch happens outside any scope it could have established, and
/// several requests are in flight at once. The marker travels with the request instead,
/// which is the only thing all the layers demonstrably share.
bool tracedByAnOuterLayer(HttpHeaders headers) =>
    headers.value(tracedMarkerHeader) != null;

/// Traces every request `dart:io` makes, whoever made it.
///
/// Installed by `Edot.start` when [EdotConfig.traceAllHttpTraffic] is set. It reaches
/// what wrapping a client cannot: a third-party pure-Dart package builds its own
/// `HttpClient`, and no amount of wrapping at the app's own call sites will see it.
///
/// Delegates to whatever override was already in place, so installing this does not
/// silently disable another package's.
///
/// **A span here begins at dispatch, not at connection.** `HttpClient.openUrl`
/// establishes the connection, and the Traced Marker cannot be read until the layer
/// that opened the request has finished setting its headers — which is after `openUrl`
/// has returned. So connection setup falls outside this span, where the two explicit
/// integrations include it. Their spans are the more accurate measurement of the same
/// request; this path exists to see requests they cannot.
///
/// **Trace Context is not injected here.** Adding it needs the Agent's reply, and the
/// only moment this layer may act is a synchronous one. Requests made through
/// `EdotHttpClient` or the Dio interceptor still propagate; requests from a third-party
/// package are traced but do not join the trace downstream.
class EdotHttpOverrides extends HttpOverrides {
  /// Wraps the previously-installed overrides, so their client is still used and
  /// this layer only adds tracing on top.
  EdotHttpOverrides(this._previous);

  /// The override in place before this one, if any.
  final HttpOverrides? _previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _TracedHttpClient(
    _previous?.createHttpClient(context) ?? super.createHttpClient(context),
  );

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      _previous?.findProxyFromEnvironment(url, environment) ??
      super.findProxyFromEnvironment(url, environment);
}

/// Installs [EdotHttpOverrides], remembering what it replaced.
///
/// Idempotent: installing twice would nest one traced client inside another and count
/// every request twice at the same layer, which no marker can detect because both
/// halves would be this same layer.
void installHttpOverrides() {
  if (HttpOverrides.current is EdotHttpOverrides) return;

  _installed = EdotHttpOverrides(HttpOverrides.current);
  HttpOverrides.global = _installed;
}

/// Removes the override this Plugin installed, restoring the previous one.
void uninstallHttpOverrides() {
  final installed = _installed;
  if (installed == null) return;

  // Only if ours is still the one in force. An app that installed its own afterwards
  // owns the global now, and taking it away would break its tracing to tidy up ours.
  if (HttpOverrides.current == installed) {
    HttpOverrides.global = installed._previous;
  }

  _installed = null;
}

EdotHttpOverrides? _installed;

/// A client whose requests are traced, delegating everything else.
///
/// Every method that opens a request returns a wrapped one; nothing here needs to know
/// how a URL was spelled, because the request itself reports its method and URL.
class _TracedHttpClient implements HttpClient {
  _TracedHttpClient(this._inner);

  final HttpClient _inner;

  Future<HttpClientRequest> _wrap(Future<HttpClientRequest> pending) async =>
      _TracedHttpClientRequest(await pending);

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) => _wrap(_inner.open(method, host, port, path));

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _wrap(_inner.openUrl(method, url));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _wrap(_inner.get(host, port, path));

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _wrap(_inner.getUrl(url));

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _wrap(_inner.post(host, port, path));

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _wrap(_inner.postUrl(url));

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _wrap(_inner.put(host, port, path));

  @override
  Future<HttpClientRequest> putUrl(Uri url) => _wrap(_inner.putUrl(url));

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _wrap(_inner.delete(host, port, path));

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => _wrap(_inner.deleteUrl(url));

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _wrap(_inner.patch(host, port, path));

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => _wrap(_inner.patchUrl(url));

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _wrap(_inner.head(host, port, path));

  @override
  Future<HttpClientRequest> headUrl(Uri url) => _wrap(_inner.headUrl(url));

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) => _inner.authenticate = f;

  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
    f,
  ) => _inner.authenticateProxy = f;

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) => _inner.badCertificateCallback = callback;

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )?
    f,
  ) => _inner.connectionFactory = f;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  // The return type is spelled out where `dart:io` leaves `keyLog` raw, to
  // satisfy strict-inference; `dynamic` keeps it the same type the base declares.
  set keyLog(dynamic Function(String line)? callback) =>
      _inner.keyLog = callback;

  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addCredentials(url, realm, credentials);

  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

/// A request that starts a span the moment it is dispatched.
///
/// Everything else is delegated. The interesting part is [_beginIfNeeded], which runs
/// on the first act that sends anything — by then the layer that opened this request
/// has set its headers, so the Traced Marker is visible and the decision can be made
/// without waiting for anything.
class _TracedHttpClientRequest implements HttpClientRequest {
  _TracedHttpClientRequest(this._inner);

  final HttpClientRequest _inner;
  bool _decided = false;

  /// Value of `http.client`, naming the transport that produced the span.
  static const String _clientName = 'dart:io';

  void _beginIfNeeded() {
    if (_decided) return;
    _decided = true;

    if (tracedByAnOuterLayer(_inner.headers)) return;

    final trace = EdotRequestTrace.begin(
      method: _inner.method,
      url: _inner.uri.toString(),
      client: _clientName,
    );
    if (trace == null) return;

    // Known by now, where it was not when the request was opened. -1 means the caller
    // never said, which is not the same as an empty body.
    if (_inner.contentLength >= 0) {
      trace.recordRequestSize(_inner.contentLength);
    }

    // `done` completes with the response once the request has been sent and the
    // response received, and errors if either half fails — so it covers both endings
    // without wrapping what `close` returns. Attaching a handler also means a failure
    // nobody else awaited is handled here rather than surfacing as an unhandled error.
    unawaited(
      _inner.done.then(
        (response) {
          trace.recordResponse(
            statusCode: response.statusCode,
            responseSize: response.contentLength >= 0
                ? response.contentLength
                : null,
            reasonPhrase: response.reasonPhrase,
          );
          trace.end();
        },
        onError: (Object error, StackTrace stackTrace) {
          trace.recordFailure(error, stackTrace: stackTrace);
          trace.end();
        },
      ),
    );
  }

  @override
  Future<HttpClientResponse> close() {
    _beginIfNeeded();
    return _inner.close();
  }

  @override
  void add(List<int> data) {
    _beginIfNeeded();
    _inner.add(data);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    _beginIfNeeded();
    return _inner.addStream(stream);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _beginIfNeeded();
    _inner.addError(error, stackTrace);
  }

  @override
  void write(Object? object) {
    _beginIfNeeded();
    _inner.write(object);
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    _beginIfNeeded();
    _inner.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) {
    _beginIfNeeded();
    _inner.writeCharCode(charCode);
  }

  @override
  void writeln([Object? object = '']) {
    _beginIfNeeded();
    _inner.writeln(object);
  }

  @override
  Future<void> flush() {
    _beginIfNeeded();
    return _inner.flush();
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);

  @override
  Future<HttpClientResponse> get done => _inner.done;

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;

  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;

  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) => _inner.followRedirects = value;

  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;

  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  String get method => _inner.method;

  @override
  Uri get uri => _inner.uri;
}
