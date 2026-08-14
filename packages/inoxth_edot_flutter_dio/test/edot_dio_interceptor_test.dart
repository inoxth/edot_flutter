import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter_dio/inoxth_edot_flutter_dio.dart';

/// Seam 1 — the client span a Dio request produces.
///
/// Deliberately independent of the `EdotHttpClient` suite: the two integrations share
/// their recording, and a test that assumed so could not tell a Dio request that
/// records nothing from one that records the same as `package:http`. The attribute
/// names are the Elastic Mobile Attribute Set (ADR-0003), the older Elastic
/// vocabulary rather than stable OpenTelemetry semantic conventions. Do not
/// "correct" them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  /// What the Agent replies to `spanTraceContext`.
  const traceparent = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01';

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(edotChannelName), (
          call,
        ) async {
          calls.add(call);

          if (call.method == 'spanTraceContext') {
            return <String, String>{'traceparent': traceparent};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(edotChannelName), null);
    Edot.resetForTesting();
  });

  Future<void> startPlugin({
    String Function(String)? urlSanitizer,
    List<Pattern> excludedUrls = const [],
    List<Pattern>? tracePropagationTargets,
  }) async {
    await Edot.start(
      EdotConfig(
        serviceName: 'example-app',
        serviceVersion: '1.2.3',
        deploymentEnvironment: 'test',
        serverUrl: 'https://apm.example.com:4318',
        urlSanitizer: urlSanitizer,
        excludedUrls: excludedUrls,
        tracePropagationTargets: tracePropagationTargets,
      ),
    );
    calls.clear();
  }

  List<MethodCall> callsTo(String method) =>
      calls.where((c) => c.method == method).toList();

  Map<Object?, Object?> argumentsOf(MethodCall call) =>
      call.arguments as Map<Object?, Object?>;

  /// The client span of the two a traced request starts.
  ///
  /// The other is its Request Transaction (ADR-0016), which the interceptor gets
  /// from `EdotRequestTrace` exactly as the other transports do — the Agent keys
  /// nothing off which transport produced a span.
  MethodCall requestSpan() => callsTo('spanStart').singleWhere(
    (c) => (argumentsOf(c)['attributes']! as Map<Object?, Object?>).containsKey(
      'http.url',
    ),
  );

  MethodCall requestTransaction() => callsTo('spanStart').singleWhere(
    (c) => !(argumentsOf(c)['attributes']! as Map<Object?, Object?>)
        .containsKey('http.url'),
  );

  /// Attributes applied when the client span was created.
  Map<Object?, Object?> creationAttributes() =>
      argumentsOf(requestSpan())['attributes']! as Map<Object?, Object?>;

  /// Attributes set after creation, by key. Integers arrive on their own method.
  Map<Object?, Object?> intAttributes() => {
    for (final call in callsTo('spanSetInt'))
      argumentsOf(call)['key']: argumentsOf(call)['value'],
  };

  /// Every exception event recorded, as (`exception.type`, `exception.message`).
  List<(Object?, Object?)> exceptionEvents() => [
    for (final call in callsTo('spanRecordException'))
      (argumentsOf(call)['type'], argumentsOf(call)['message']),
  ];

  /// A `Dio` whose transport is [respond], with the interceptor installed.
  ({Dio dio, _StubAdapter adapter}) dioReturning(
    Future<ResponseBody> Function(RequestOptions options) respond,
  ) {
    final adapter = _StubAdapter(respond);
    final dio = Dio()
      ..httpClientAdapter = adapter
      ..interceptors.add(EdotDioInterceptor());

    return (dio: dio, adapter: adapter);
  }

  ({Dio dio, _StubAdapter adapter}) okDio({
    int status = 200,
    String body = '{"id":42}',
    Map<String, List<String>>? headers,
  }) => dioReturning(
    (_) async => ResponseBody.fromString(body, status, headers: headers ?? {}),
  );

  group('the client span', () {
    test(
      'hangs beneath a Request Transaction, as the other transports do',
      () async {
        await startPlugin();

        await okDio().dio.get<dynamic>('https://api.example.com/orders');

        expect(callsTo('spanStart'), hasLength(2));
        expect(callsTo('spanEnd'), hasLength(2));
        expect(
          argumentsOf(requestSpan())['parentShadowId'],
          argumentsOf(requestTransaction())['shadowId'],
        );
        expect(
          (argumentsOf(requestTransaction())['attributes']!
                  as Map<Object?, Object?>)
              .keys,
          isNot(contains('http.url')),
        );
      },
    );

    test('is named for the method and host, not the path', () async {
      await startPlugin();

      await okDio().dio.get<dynamic>('https://api.example.com/orders/42');

      expect(argumentsOf(requestSpan())['name'], 'GET api.example.com');
    });

    test('carries method, URL, target, scheme and peer name', () async {
      await startPlugin();

      await okDio().dio.get<dynamic>('https://api.example.com/v1/orders');

      expect(creationAttributes(), {
        'http.method': 'GET',
        'http.url': 'https://api.example.com/v1/orders',
        'http.client': 'dio',
        'http.target': '/v1/orders',
        'http.scheme': 'https',
        'net.peer.name': 'api.example.com',
      });
    });

    test('records the status code and the peer port', () async {
      await startPlugin();

      await okDio().dio.get<dynamic>('https://api.example.com/orders');

      expect(intAttributes()['http.status_code'], 200);
      // Resolved from the scheme, which the URL does not write.
      expect(intAttributes()['net.peer.port'], 443);
    });

    test('records the size the response announced', () async {
      await startPlugin();

      await okDio().dio.get<dynamic>(
        'https://api.example.com/orders',
        options: Options(headers: const {}),
      );

      // `ResponseBody.fromString` declares no length, so there is none to record.
      expect(intAttributes().containsKey('http.response_body.size'), isFalse);

      calls.clear();
      await dioReturning(
        (_) async => ResponseBody.fromString(
          '{"id":42}',
          200,
          headers: {
            Headers.contentLengthHeader: const ['9'],
          },
        ),
      ).dio.get<dynamic>('https://api.example.com/orders');

      expect(intAttributes()['http.response_body.size'], 9);
    });

    test('records an encoded request body size', () async {
      await startPlugin();

      await okDio().dio.post<dynamic>(
        'https://api.example.com/orders',
        data: '{"quantity":2}',
      );

      expect(intAttributes()['http.request_body.size'], 14);
    });

    test('records a multipart body size, as the http integration does', () async {
      // `http.MultipartRequest` computes its own content length, so the other
      // integration reports a size for an upload. An attribute one can produce and
      // the other cannot is exactly the drift this Plugin is meant not to have.
      await startPlugin();

      final body = FormData.fromMap({'note': 'hello'});
      await okDio().dio.post<dynamic>(
        'https://api.example.com/uploads',
        data: body,
      );

      // Dio's own computed length is the only stable expectation — a multipart body
      // carries a randomly generated boundary, so its size cannot be hardcoded.
      expect(intAttributes()['http.request_body.size'], body.length);
    });

    test('records no request size for a body Dio has not encoded yet', () async {
      // A Map becomes JSON in a transformer that runs after the interceptor, so its
      // encoded size does not exist yet. Absent beats guessed.
      await startPlugin();

      await okDio().dio.post<dynamic>(
        'https://api.example.com/orders',
        data: const {'quantity': 2},
      );

      expect(intAttributes().containsKey('http.request_body.size'), isFalse);
    });
  });

  group('sanitising', () {
    test('drops the query string from the recorded URL', () async {
      await startPlugin();

      await okDio().dio.get<dynamic>(
        'https://api.example.com/orders?token=secret',
      );

      expect(
        creationAttributes(),
        containsPair('http.url', 'https://api.example.com/orders'),
      );
      expect(creationAttributes().values.join(' '), isNot(contains('secret')));
    });

    test('applies the configured hook to the URL and target', () async {
      await startPlugin(
        urlSanitizer: (url) =>
            url.replaceAll(RegExp(r'/orders/\d+'), '/orders/{id}'),
      );

      await okDio().dio.get<dynamic>('https://api.example.com/orders/12345');

      expect(
        creationAttributes(),
        containsPair('http.url', 'https://api.example.com/orders/{id}'),
      );
      expect(creationAttributes(), containsPair('http.target', '/orders/{id}'));
    });

    test('reaches the span name too, when the hook rewrites the host', () async {
      // The span name carries the host, which makes it one more place the URL is
      // recorded — and the easiest one to forget.
      await startPlugin(
        urlSanitizer: (url) => url.replaceAll('internal.api', 'api'),
      );

      await okDio().dio.get<dynamic>('https://internal.api.example.com/x');

      expect(argumentsOf(requestSpan())['name'], 'GET api.example.com');
      expect(
        creationAttributes(),
        containsPair('net.peer.name', 'api.example.com'),
      );
    });

    test('does not send the request to a different URL', () async {
      // Sanitising is about what is recorded. Rewriting the request itself would make
      // telemetry change application behaviour.
      await startPlugin(urlSanitizer: (_) => 'https://elsewhere.test/');

      final probe = okDio();
      await probe.dio.get<dynamic>('https://api.example.com/orders');

      expect(
        probe.adapter.seen.single.uri.toString(),
        'https://api.example.com/orders',
      );
    });
  });

  group('exclusion', () {
    test('produces no span for the Collector Host, at any path', () async {
      await startPlugin();

      await okDio().dio.post<dynamic>('https://apm.example.com:4318/v1/traces');
      await okDio().dio.get<dynamic>(
        'https://apm.example.com/config/v1/agents',
      );

      expect(calls, isEmpty);
    });

    test('produces no span for an excluded URL', () async {
      await startPlugin(excludedUrls: ['/health']);

      await okDio().dio.get<dynamic>('https://api.example.com/health');

      expect(calls, isEmpty);
    });

    test('still performs an excluded request', () async {
      await startPlugin(excludedUrls: ['/health']);

      final probe = okDio();
      final response = await probe.dio.get<dynamic>(
        'https://api.example.com/health',
      );

      expect(response.statusCode, 200);
      expect(probe.adapter.seen, hasLength(1));
    });

    test('traces a lookalike host rather than dropping it', () async {
      await startPlugin();

      await okDio().dio.get<dynamic>('https://apm.example.com.evil.test/x');

      expect(callsTo('spanStart'), hasLength(2));
    });
  });

  group('Trace Context', () {
    test('carries the header the Agent returned', () async {
      await startPlugin();

      final probe = okDio();
      await probe.dio.get<dynamic>('https://api.example.com/orders');

      expect(probe.adapter.seen.single.headers['traceparent'], traceparent);
    });

    test('names the span this request created', () async {
      await startPlugin();

      await okDio().dio.get<dynamic>('https://api.example.com/orders');

      expect(
        argumentsOf(callsTo('spanTraceContext').single)['shadowId'],
        argumentsOf(requestSpan())['shadowId'],
        reason:
            'the header names the request span, not its Request Transaction',
      );
    });

    test('is not requested for a host outside the target list', () async {
      await startPlugin(tracePropagationTargets: ['api.example.com']);

      final probe = okDio();
      await probe.dio.get<dynamic>('https://third-party.test/things');

      expect(callsTo('spanTraceContext'), isEmpty);
      expect(
        probe.adapter.seen.single.headers.containsKey('traceparent'),
        isFalse,
      );
      // Narrowing propagation costs the link, not the span.
      expect(callsTo('spanStart'), hasLength(2));
    });

    test('is absent from an untraced request', () async {
      await startPlugin(excludedUrls: ['/health']);

      final probe = okDio();
      await probe.dio.get<dynamic>('https://api.example.com/health');

      expect(
        probe.adapter.seen.single.headers.containsKey('traceparent'),
        isFalse,
      );
    });
  });

  group('failure', () {
    test('records a rejected status code as the answer it is', () async {
      // The difference this integration has to absorb: Dio raises a 500 as a
      // `DioException` where `package:http` returns it as a response. Recording it as
      // a transport failure would describe one integration's 500 as unreachable and
      // the other's as answered, for the same server behaviour.
      await startPlugin();

      await expectLater(
        okDio(
          status: 500,
          body: '{"error":"boom"}',
        ).dio.get<dynamic>('https://api.example.com/orders'),
        throwsA(isA<DioException>()),
      );

      expect(intAttributes()['http.status_code'], 500);
      // The same event `EdotHttpClient` records for an unrejected 500: the status
      // code as the type, and no status on either span (ADR-0016).
      expect(exceptionEvents(), [('500', 'HTTP 500')]);
      expect(callsTo('spanMarkFailed'), isEmpty);
      // Both spans: the request and its Request Transaction (ADR-0016).
      expect(callsTo('spanEnd'), hasLength(2));
    });

    test('records a transport failure with Dio\'s own type', () async {
      // `DioException` alone covers a cancellation, four kinds of timeout and a
      // refused connection alike, so the class name cannot tell them apart — and that
      // is most of what `exception.type` is read for.
      await startPlugin();

      await expectLater(
        dioReturning(
          (options) async => throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionTimeout,
          ),
        ).dio.get<dynamic>('https://api.example.com/orders'),
        throwsA(isA<DioException>()),
      );

      expect(
        argumentsOf(callsTo('spanRecordException').single)['type'],
        'DioExceptionType.connectionTimeout',
      );
      expect(callsTo('spanMarkFailed'), isEmpty);
      // No status code: nothing answered.
      expect(intAttributes().containsKey('http.status_code'), isFalse);
      expect(callsTo('spanEnd'), hasLength(2));
    });

    test('records a cancellation as a cancellation', () async {
      await startPlugin();

      final token = CancelToken();
      await expectLater(
        dioReturning((options) async {
          token.cancel();
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return ResponseBody.fromString('{}', 200);
        }).dio.get<dynamic>(
          'https://api.example.com/orders',
          cancelToken: token,
        ),
        throwsA(isA<DioException>()),
      );

      expect(
        argumentsOf(callsTo('spanRecordException').single)['type'],
        'DioExceptionType.cancel',
      );
      expect(callsTo('spanEnd'), hasLength(2));
    });

    test('ends the span even when the transport throws', () async {
      await startPlugin();

      await expectLater(
        dioReturning(
          (_) async => throw const _TransportStub(),
        ).dio.get<dynamic>('https://api.example.com/orders'),
        throwsA(isA<DioException>()),
      );

      expect(callsTo('spanEnd'), hasLength(2));
    });
  });

  group('with app-wide tracing also enabled', () {
    // The combination that double-counts if the Traced Marker is not honoured: Dio
    // dispatches through `dart:io`, so both layers see the same request. A real client
    // and a real loopback server, because the stub adapter above bypasses `dart:io`
    // entirely and so could never show the two layers meeting.
    late HttpServer server;
    late String origin;
    HttpOverrides? previousOverrides;

    setUp(() async {
      // `flutter_test`'s own override answers every request without a socket.
      // Captured so the sibling groups, which do want it, get it back.
      previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = 200;
        request.response.headers.contentLength = 2;
        request.response.write('{}');
        await request.response.close();
      });
      origin = 'http://${InternetAddress.loopbackIPv4.address}:${server.port}';
    });

    tearDown(() async {
      HttpOverrides.global = previousOverrides;
      await server.close(force: true);
    });

    test('a Dio request produces exactly one span', () async {
      await Edot.start(
        EdotConfig(
          serviceName: 'example-app',
          serviceVersion: '1.2.3',
          deploymentEnvironment: 'test',
          serverUrl: 'https://apm.example.com:4318',
          traceAllHttpTraffic: true,
        ),
      );
      calls.clear();

      final dio = Dio()..interceptors.add(EdotDioInterceptor());
      await dio.get<dynamic>('$origin/orders');

      expect(callsTo('spanStart'), hasLength(2));
      expect(callsTo('spanEnd'), hasLength(2));
      // Dio's own span, not the app-wide layer's: the interceptor marked the request,
      // and the marker is what the inner layer stands down for.
      expect(creationAttributes(), containsPair('http.client', 'dio'));
    });

    test('one span per request with every layer enabled at once', () async {
      // The combination the ticket asks for literally: all three transports in one
      // session. Each request must be claimed by exactly one layer, and the innermost
      // must stand down for the two that marked their own.
      await Edot.start(
        EdotConfig(
          serviceName: 'example-app',
          serviceVersion: '1.2.3',
          deploymentEnvironment: 'test',
          serverUrl: 'https://apm.example.com:4318',
          traceAllHttpTraffic: true,
        ),
      );
      calls.clear();

      final wrapped = EdotHttpClient(http.Client());
      final dio = Dio()..interceptors.add(EdotDioInterceptor());
      final bare = HttpClient();

      await wrapped.get(Uri.parse('$origin/via-http'));
      await dio.get<dynamic>('$origin/via-dio');
      await (await bare.getUrl(
        Uri.parse('$origin/via-dart-io'),
      )).close().then((r) => r.drain<void>());

      wrapped.close();
      bare.close();

      // Three requests, three client spans — not five, which is what two unmarked
      // layers would produce. Six spans in all, each request also starting its own
      // Request Transaction (ADR-0016); the marker de-duplicates requests, and a
      // request that was never traced twice cannot have two transactions either.
      final requestSpans = callsTo('spanStart')
          .where(
            (c) => (argumentsOf(c)['attributes']! as Map<Object?, Object?>)
                .containsKey('http.url'),
          )
          .toList();

      expect(requestSpans, hasLength(3));
      expect(callsTo('spanStart'), hasLength(6));
      expect(callsTo('spanEnd'), hasLength(6));

      final owners = requestSpans
          .map(
            (call) =>
                (argumentsOf(call)['attributes']
                    as Map<Object?, Object?>)['http.client'],
          )
          .toList();
      expect(owners, containsAll(<String>['http', 'dio', 'dart:io']));
    });
  });

  group('the package boundary', () {
    test('depends on the core package and on Dio', () async {
      // The other half of ADR-0010, asserted in the core package: that core does not
      // depend on Dio. Both directions matter — this package is the only place the
      // two are allowed to meet.
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final imposed = pubspec.split('dev_dependencies:').first;

      expect(RegExp(r'^\s+dio\s*:', multiLine: true).hasMatch(imposed), isTrue);
      expect(
        RegExp(
          r'^\s+inoxth_edot_flutter\s*:',
          multiLine: true,
        ).hasMatch(imposed),
        isTrue,
      );
    });
  });

  group('before start', () {
    test('performs the request without tracing it', () async {
      final probe = okDio();

      final response = await probe.dio.get<dynamic>(
        'https://api.example.com/x',
      );

      expect(response.statusCode, 200);
      expect(calls, isEmpty);
      expect(probe.adapter.seen, hasLength(1));
    });
  });
}

/// A transport that answers from [_respond] and records what it was asked for.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this._respond);

  final Future<ResponseBody> Function(RequestOptions options) _respond;

  /// The requests that reached the transport, headers and all.
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    seen.add(options);
    return _respond(options);
  }

  @override
  void close({bool force = false}) {}
}

/// Stands in for a transport failure that is not already a [DioException].
class _TransportStub implements Exception {
  const _TransportStub();
}
