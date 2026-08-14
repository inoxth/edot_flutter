import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter/src/edot_http_overrides.dart'
    show tracedByAnOuterLayer;
import 'package:inoxth_edot_flutter/src/edot_request_trace.dart'
    show tracedMarkerHeader;

/// Seam 1 — tracing every `dart:io` request, and never tracing one twice.
///
/// Against a real `HttpClient` and a real loopback server rather than a stubbed
/// transport. `flutter_test` installs an override of its own that answers every request
/// with a canned 400 without touching a socket, so it is dropped in [setUp]: this suite
/// exists to exercise the delegation `dart:io` actually performs, and a fake client
/// would be asserting against the fake.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  late HttpServer server;
  late String origin;

  /// Headers the server saw, by request path.
  final received = <String, HttpHeaders>{};

  setUp(() async {
    calls.clear();
    received.clear();

    // `flutter_test`'s own override short-circuits every request. Dropped so a real
    // client reaches the server below; each test file is its own process, so this
    // affects nothing else.
    HttpOverrides.global = null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(edotChannelName), (
          call,
        ) async {
          calls.add(call);

          if (call.method == 'spanTraceContext') {
            return <String, String>{
              'traceparent':
                  '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
            };
          }
          return null;
        });

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      received[request.uri.path] = request.headers;

      if (request.uri.path == '/redirect') {
        await request.response.redirect(Uri.parse('$origin/orders'));
        return;
      }

      const body = '{"id":42}';
      request.response.statusCode = request.uri.path == '/boom' ? 500 : 200;
      request.response.headers.contentLength = body.length;
      request.response.write(body);
      await request.response.close();
    });
    origin = 'http://${InternetAddress.loopbackIPv4.address}:${server.port}';
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(edotChannelName), null);
    Edot.resetForTesting();
    await server.close(force: true);
  });

  Future<void> startPlugin({
    bool traceAllHttpTraffic = true,
    List<Pattern> excludedUrls = const [],
  }) async {
    await Edot.start(
      EdotConfig(
        serviceName: 'example-app',
        serviceVersion: '1.2.3',
        deploymentEnvironment: 'test',
        // A host that is not the loopback server, so the two are told apart.
        serverUrl: 'https://apm.example.com:4318',
        excludedUrls: excludedUrls,
        traceAllHttpTraffic: traceAllHttpTraffic,
      ),
    );
    calls.clear();
  }

  List<MethodCall> callsTo(String method) =>
      calls.where((c) => c.method == method).toList();

  Map<Object?, Object?> argumentsOf(MethodCall call) =>
      call.arguments as Map<Object?, Object?>;

  /// The client spans started, one per traced request.
  ///
  /// Not every `spanStart`: each request also starts a Request Transaction for its
  /// client span to hang under (ADR-0016). De-duplication is a claim about how many
  /// *requests* were traced, so it is counted here rather than over both spans.
  List<MethodCall> requestSpans() => callsTo(
    'spanStart',
  ).where((c) => argumentsOf(c)['kind'] == 'client').toList();

  Map<Object?, Object?> creationAttributes() =>
      argumentsOf(requestSpans().single)['attributes']!
          as Map<Object?, Object?>;

  Map<Object?, Object?> intAttributes() => {
    for (final call in callsTo('spanSetInt'))
      argumentsOf(call)['key']: argumentsOf(call)['value'],
  };

  /// A request made the way a third-party package makes one: its own client, which
  /// nothing at the app's call sites can wrap.
  Future<HttpClientResponse> requestFromOwnClient(
    String path, {
    Map<String, String> headers = const {},
    String method = 'GET',
  }) async {
    final client = HttpClient();
    final request = await client.openUrl(method, Uri.parse('$origin$path'));
    headers.forEach(request.headers.set);

    final response = await request.close();
    await response.drain<void>();
    client.close();

    return response;
  }

  group('a request from a package that builds its own client', () {
    test('is traced', () async {
      await startPlugin();

      await requestFromOwnClient('/orders');

      expect(requestSpans(), hasLength(1));
      expect(callsTo('spanStart'), hasLength(2));
      expect(callsTo('spanEnd'), hasLength(2));
      expect(creationAttributes(), containsPair('http.client', 'dart:io'));
      expect(creationAttributes(), containsPair('http.method', 'GET'));
      expect(creationAttributes(), containsPair('http.target', '/orders'));
      expect(intAttributes()['http.status_code'], 200);
      expect(intAttributes()['http.response_body.size'], 9);
    });

    test('is not traced when app-wide tracing is off', () async {
      // The default. Enabling it installs a process-wide override, which is not
      // something to do to an app that did not ask.
      await startPlugin(traceAllHttpTraffic: false);

      await requestFromOwnClient('/orders');

      expect(calls, isEmpty);
    });

    test(
      'records the request body size, which is known only at dispatch',
      () async {
        await startPlugin();

        final client = HttpClient();
        final request = await client.postUrl(Uri.parse('$origin/orders'));
        request.contentLength = 5;
        request.write('hello');
        await (await request.close()).drain<void>();
        client.close();

        expect(intAttributes()['http.request_body.size'], 5);
      },
    );

    test(
      'is still traced when it already carries a foreign trace context',
      () async {
        // A `traceparent` this Plugin did not create — from another library, or a header
        // the app set itself. It is not the Traced Marker and must not be read as one.
        await startPlugin();

        await requestFromOwnClient(
          '/orders',
          headers: const {
            'traceparent':
                '00-11111111111111111111111111111111-2222222222222222-01',
          },
        );

        expect(requestSpans(), hasLength(1));
      },
    );
  });

  group('never twice', () {
    test('a request through EdotHttpClient produces exactly one span', () async {
      await startPlugin();

      final client = EdotHttpClient(http.Client());
      await client.get(Uri.parse('$origin/orders'));
      client.close();

      expect(requestSpans(), hasLength(1));
      expect(callsTo('spanStart'), hasLength(2));
      expect(callsTo('spanEnd'), hasLength(2));
      // The outer layer's span, not this layer's: it knows more, including the Trace
      // Context it propagated.
      expect(creationAttributes(), containsPair('http.client', 'http'));
    });

    test(
      'the outer layer marks the request, which is what suppresses this one',
      () async {
        // The mechanism, asserted where it is observable: on the request itself. Nothing
        // ambient is involved, because a Dio interceptor returns before dispatch and so
        // could not have established a scope around it.
        await startPlugin();

        final client = EdotHttpClient(http.Client());
        await client.get(Uri.parse('$origin/marked'));
        client.close();

        expect(received['/marked']?.value(tracedMarkerHeader), isNotNull);
      },
    );

    test('an unmarked request is traced by this layer', () async {
      // The other half of the previous assertion: suppression follows the marker, not
      // the mere fact that app-wide tracing is on.
      await startPlugin();

      await requestFromOwnClient('/unmarked');

      expect(received['/unmarked']?.value(tracedMarkerHeader), isNull);
      expect(requestSpans(), hasLength(1));
    });

    test('a followed redirect is one span, not one per hop', () async {
      // `dart:io` follows a redirect inside the real client, using the request object
      // it already holds — so the second hop never passes through this layer's
      // `openUrl` and cannot start a span of its own. Asserted rather than assumed:
      // a redirect chain counted per hop would inflate request counts silently, and
      // nothing about the individual spans would look wrong.
      await startPlugin();

      await requestFromOwnClient('/redirect');

      expect(received.keys, containsAll(<String>['/redirect', '/orders']));
      expect(requestSpans(), hasLength(1));
      expect(callsTo('spanEnd'), hasLength(2));
      // The span names the URL that was asked for, which is the one the app knows.
      expect(creationAttributes(), containsPair('http.target', '/redirect'));
    });

    test('the de-duplication check does no asynchronous work', () async {
      // It has to decide in the moment: the only point where the marker is readable and
      // the request has not yet been sent is synchronous, so a check that awaited
      // anything would be making its decision after dispatch.
      await startPlugin();

      final client = HttpClient();
      final request = await client.getUrl(Uri.parse('$origin/sync'));
      request.headers.set(tracedMarkerHeader, '1');

      runZoned(
        () => expect(tracedByAnOuterLayer(request.headers), isTrue),
        zoneSpecification: ZoneSpecification(
          scheduleMicrotask: (self, parent, zone, f) =>
              fail('the check scheduled a microtask'),
          createTimer: (self, parent, zone, duration, f) =>
              fail('the check created a timer'),
          createPeriodicTimer: (self, parent, zone, period, f) =>
              fail('the check created a periodic timer'),
        ),
      );

      await (await request.close()).drain<void>();
      client.close();
    });
  });

  group('exclusion applies to this path too', () {
    test('produces no span for the Collector Host', () async {
      await startPlugin();

      // Nothing listens there, and it must not be traced either way (ADR-0006).
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('https://apm.example.com:4318/v1/traces'),
        );
        await request.close();
      } on Exception {
        // Whether it connects is beside the point; the absent span is the assertion.
      }
      client.close();

      expect(calls, isEmpty);
    });

    test('produces no span for an excluded URL', () async {
      await startPlugin(excludedUrls: ['/health']);

      await requestFromOwnClient('/health');

      expect(calls, isEmpty);
    });
  });

  group('failure', () {
    test('records a status the service rejected with', () async {
      await startPlugin();

      await requestFromOwnClient('/boom');

      expect(intAttributes()['http.status_code'], 500);
      // Twice: the request span and its Request Transaction, so a failed request
      // does not read as a successful transaction (ADR-0016).
      expect(callsTo('spanMarkFailed'), hasLength(2));
      expect(
        callsTo(
          'spanMarkFailed',
        ).map((c) => argumentsOf(c)['description']).toSet(),
        {'HTTP 500'},
      );
      // A status code is an answer, not an exception — the same rule both other
      // integrations follow.
      expect(callsTo('spanRecordException'), isEmpty);
    });

    test('produces no span when the connection never opens', () async {
      // The blind spot this path has and the explicit integrations do not: `openUrl`
      // establishes the connection, and it is only after it returns that the Traced
      // Marker can be read — so a connection that fails outright is never dispatched
      // and there is nothing to attach a span to. Asserted rather than left unsaid.
      await startPlugin();

      final client = HttpClient();
      try {
        // Nothing is listening on port 1.
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:1/unreachable'),
        );
        await request.close();
      } on Exception {
        // Expected. The span records why.
      }
      client.close();

      // The connection fails inside openUrl, before there is a request to dispatch, so
      // no span exists to record it — the same blind spot the wrapped path does not
      // have, and the reason its spans are the better measurement.
      expect(callsTo('spanStart'), isEmpty);
    });
  });
}
