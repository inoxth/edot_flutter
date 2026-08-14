import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter/src/edot_channel.dart'
    show debugLoggingEnabled;

/// Seam 1 — the client span a wrapped request produces.
///
/// The attribute names are the Elastic Mobile Attribute Set (ADR-0003), which is
/// deliberately the older Elastic vocabulary rather than stable OpenTelemetry
/// semantic conventions. Do not "correct" them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(edotChannelName), (
          call,
        ) async {
          calls.add(call);
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
  }) async {
    await Edot.start(
      EdotConfig(
        serviceName: 'example-app',
        serviceVersion: '1.2.3',
        deploymentEnvironment: 'test',
        serverUrl: 'https://apm.example.com:4318',
        urlSanitizer: urlSanitizer,
        excludedUrls: excludedUrls,
      ),
    );
    calls.clear();
  }

  Map<Object?, Object?> argumentsOf(MethodCall call) =>
      call.arguments as Map<Object?, Object?>;

  List<MethodCall> callsTo(String method) =>
      calls.where((c) => c.method == method).toList();

  /// One of the two spans a traced request starts, by kind.
  ///
  /// A request produces a Request Transaction and, beneath it, the client span
  /// (ADR-0016). Selected by kind rather than by position, so a helper reading the
  /// wrong one of the two fails here rather than asserting against the other span.
  MethodCall spanStartOfKind(String kind) =>
      callsTo('spanStart').singleWhere((c) => argumentsOf(c)['kind'] == kind);

  /// The client span: the one carrying the request's attributes.
  MethodCall requestSpan() => spanStartOfKind('client');

  /// The Request Transaction the client span hangs under.
  MethodCall requestTransaction() => spanStartOfKind('internal');

  /// Attributes applied when the client span was created.
  Map<Object?, Object?> creationAttributes() =>
      argumentsOf(requestSpan())['attributes']! as Map<Object?, Object?>;

  /// Every description a `spanMarkFailed` carried, in call order.
  List<Object?> failureDescriptions() => [
    for (final call in callsTo('spanMarkFailed'))
      argumentsOf(call)['description'],
  ];

  /// Attributes set after creation, by key. Integers arrive on their own method.
  Map<Object?, Object?> intAttributes() => {
    for (final call in callsTo('spanSetInt'))
      argumentsOf(call)['key']: argumentsOf(call)['value'],
  };

  /// A client answering every request with [response], recording what it saw.
  ({EdotHttpClient client, List<http.BaseRequest> seen}) clientReturning(
    http.Response Function(http.Request request) response,
  ) {
    final seen = <http.BaseRequest>[];
    final inner = MockClient((request) async {
      seen.add(request);
      return response(request);
    });
    return (client: EdotHttpClient(inner), seen: seen);
  }

  EdotHttpClient okClient({int status = 200, Map<String, String>? headers}) =>
      clientReturning(
        (_) => http.Response('{}', status, headers: headers ?? const {}),
      ).client;

  group('the client span', () {
    test('hangs beneath a Request Transaction it starts itself', () async {
      // ADR-0016. A parentless client span is recorded as a transaction at intake,
      // and a transaction carries no destination — so nothing links this app to what
      // it called. The transaction is minted here rather than left to the Agent,
      // which only manufactures one on iOS.
      await startPlugin();

      await okClient().get(Uri.parse('https://api.example.com/orders'));

      expect(callsTo('spanStart'), hasLength(2));
      expect(callsTo('spanEnd'), hasLength(2));
      expect(
        argumentsOf(requestSpan())['parentShadowId'],
        argumentsOf(requestTransaction())['shadowId'],
        reason: 'the client span must name the transaction as its parent',
      );
      expect(argumentsOf(requestTransaction())['parentShadowId'], isNull);
    });

    test('leaves the Request Transaction free of HTTP attributes', () async {
      // Above all `http.url`: the iOS Agent wraps any parentless span carrying it,
      // so a transaction with that key would itself be wrapped and one request would
      // export three spans (ADR-0001).
      await startPlugin();

      await okClient().get(Uri.parse('https://api.example.com/orders'));

      final attributes =
          argumentsOf(requestTransaction())['attributes']!
              as Map<Object?, Object?>;

      expect(attributes.keys, isNot(contains('http.url')));
      expect(attributes.keys.where((k) => '$k'.startsWith('http.')), isEmpty);
      expect(attributes.keys, isNot(contains('net.peer.name')));
    });

    test('is one span inside runWithParent, not two', () async {
      // The ambient span is the transaction this request belongs to already, so
      // wrapping it again would say the request caused itself. This is also the
      // documented escape hatch from the extra span, and it has to keep working.
      await startPlugin();
      final checkout = Edot.tracer.startSpan('checkout');
      calls.clear();

      await Edot.tracer.runWithParent(checkout, () async {
        await okClient().get(Uri.parse('https://api.example.com/orders'));
      });

      expect(callsTo('spanStart'), hasLength(1));
      expect(argumentsOf(requestSpan())['parentShadowId'], checkout.shadowId);
    });

    test('gives the Request Transaction the request span name', () async {
      await startPlugin();

      await okClient().get(Uri.parse('https://api.example.com/orders/42'));

      expect(argumentsOf(requestTransaction())['name'], 'GET api.example.com');
    });

    test('is named for the method and host, not the path', () async {
      await startPlugin();

      await okClient().get(Uri.parse('https://api.example.com/orders/42'));

      expect(argumentsOf(requestSpan())['name'], 'GET api.example.com');
    });

    test('carries method, URL, target, scheme and client', () async {
      await startPlugin();

      await okClient().get(Uri.parse('https://api.example.com/v1/orders'));

      expect(creationAttributes(), containsPair('http.method', 'GET'));
      expect(
        creationAttributes(),
        containsPair('http.url', 'https://api.example.com/v1/orders'),
      );
      expect(creationAttributes(), containsPair('http.target', '/v1/orders'));
      expect(creationAttributes(), containsPair('http.scheme', 'https'));
      expect(creationAttributes(), containsPair('http.client', 'http'));
    });

    test('carries the peer host and port', () async {
      await startPlugin();

      await okClient().get(Uri.parse('https://api.example.com:8443/x'));

      expect(
        creationAttributes(),
        containsPair('net.peer.name', 'api.example.com'),
      );
      expect(intAttributes(), containsPair('net.peer.port', 8443));
    });

    test('carries the status code', () async {
      await startPlugin();

      await okClient(status: 201).get(Uri.parse('https://api.example.com/x'));

      expect(intAttributes(), containsPair('http.status_code', 201));
    });

    test('carries request and response body sizes', () async {
      await startPlugin();

      final body = jsonEncode({'sku': 'A-1'});
      final probe = clientReturning((_) => http.Response('{"id":1}', 200));

      await probe.client.post(
        Uri.parse('https://api.example.com/orders'),
        body: body,
      );

      expect(
        intAttributes(),
        containsPair('http.request_body.size', body.length),
      );
      expect(intAttributes(), containsPair('http.response_body.size', 8));
    });

    test('carries the Active View attributes', () async {
      await startPlugin();
      Edot.setActiveView('Cart');

      await okClient().get(Uri.parse('https://api.example.com/x'));

      expect(creationAttributes(), containsPair('screen.name', 'Cart'));
      expect(
        creationAttributes(),
        containsPair('screen.id', Edot.activeView!.id),
      );
    });
  });

  group('failure', () {
    test('marks a server error failed, keeping the status code', () async {
      await startPlugin();

      await okClient(status: 500).get(Uri.parse('https://api.example.com/x'));

      expect(intAttributes(), containsPair('http.status_code', 500));
      // Both spans: a transaction reporting success over an exit span that failed
      // would make Kibana's error rate confidently wrong (ADR-0016).
      expect(failureDescriptions(), ['HTTP 500', 'HTTP 500']);
      expect(
        callsTo('spanRecordException'),
        isEmpty,
        reason: 'a 500 is an answer, not an exception',
      );
    });

    test('marks a 404 failed too', () async {
      await startPlugin();

      await okClient(status: 404).get(Uri.parse('https://api.example.com/x'));

      expect(failureDescriptions(), ['HTTP 404', 'HTTP 404']);
    });

    test('leaves a 2xx and a 3xx unmarked', () async {
      await startPlugin();

      await okClient(status: 204).get(Uri.parse('https://api.example.com/x'));
      await okClient(status: 301).get(Uri.parse('https://api.example.com/y'));

      expect(callsTo('spanMarkFailed'), isEmpty);
    });

    test(
      'records the exception type, so a timeout is not a server error',
      () async {
        // This is what tells the two apart: a timeout produces an exception event
        // with its type, a 500 produces a status code and no event.
        await startPlugin();

        final client = EdotHttpClient(
          MockClient((_) async => throw TimeoutException('too slow')),
        );

        await expectLater(
          client.get(Uri.parse('https://api.example.com/x')),
          throwsA(isA<TimeoutException>()),
        );

        expect(
          argumentsOf(callsTo('spanRecordException').single)['type'],
          'TimeoutException',
          reason:
              'the event belongs to the request span alone, never duplicated '
              'onto the Request Transaction',
        );
        expect(failureDescriptions(), ['TimeoutException', 'TimeoutException']);
        expect(intAttributes(), isNot(contains('http.status_code')));
      },
    );

    test('still ends the span when the request throws', () async {
      await startPlugin();

      final client = EdotHttpClient(
        MockClient((_) async => throw const SocketExceptionStub()),
      );

      await expectLater(
        client.get(Uri.parse('https://api.example.com/x')),
        throwsA(isA<SocketExceptionStub>()),
      );

      expect(callsTo('spanEnd'), hasLength(2));
    });

    test('rethrows, so tracing never changes what the caller sees', () async {
      await startPlugin();

      final client = EdotHttpClient(
        MockClient((_) async => throw const SocketExceptionStub()),
      );

      expect(
        client.get(Uri.parse('https://api.example.com/x')),
        throwsA(isA<SocketExceptionStub>()),
      );
    });
  });

  group('the URL sanitiser', () {
    test('runs before the URL is recorded', () async {
      await startPlugin();

      await okClient().get(
        Uri.parse('https://api.example.com/orders?token=secret'),
      );

      expect(
        creationAttributes(),
        containsPair('http.url', 'https://api.example.com/orders'),
      );
      expect(creationAttributes().values.join(' '), isNot(contains('secret')));
    });

    test('reaches the target attribute as well as the URL', () async {
      // http.target is derived from the URL, so a sanitiser that missed it would
      // leave the query string sitting in a second attribute.
      await startPlugin();

      await okClient().get(
        Uri.parse('https://api.example.com/orders?token=secret'),
      );

      expect(creationAttributes(), containsPair('http.target', '/orders'));
    });

    test('applies the custom hook to the recorded URL and target', () async {
      await startPlugin(
        urlSanitizer: (url) =>
            url.replaceAll(RegExp(r'/orders/\d+'), '/orders/{id}'),
      );

      await okClient().get(Uri.parse('https://api.example.com/orders/12345'));

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

      await okClient().get(Uri.parse('https://internal.api.example.com/x'));

      expect(argumentsOf(requestSpan())['name'], 'GET api.example.com');
      expect(
        creationAttributes(),
        containsPair('net.peer.name', 'api.example.com'),
      );
    });

    test('does not send the request to a different URL', () async {
      // Sanitising is about what is recorded. Rewriting the request itself would
      // make telemetry change application behaviour.
      await startPlugin(urlSanitizer: (_) => 'https://elsewhere.test/');

      final probe = clientReturning((_) => http.Response('{}', 200));
      await probe.client.get(Uri.parse('https://api.example.com/orders'));

      expect(
        probe.seen.single.url.toString(),
        'https://api.example.com/orders',
      );
    });
  });

  group('exclusion', () {
    test('produces no span for the Collector Host, at any path', () async {
      await startPlugin();

      await okClient().post(
        Uri.parse('https://apm.example.com:4318/v1/traces'),
      );
      await okClient().get(
        Uri.parse('https://apm.example.com/config/v1/agents'),
      );

      expect(calls, isEmpty);
    });

    test('produces no span for an excluded URL', () async {
      await startPlugin(excludedUrls: ['/health']);

      await okClient().get(Uri.parse('https://api.example.com/health'));

      expect(calls, isEmpty);
    });

    test('still performs an excluded request', () async {
      // Excluding a URL suppresses the span, not the request.
      await startPlugin(excludedUrls: ['/health']);

      final probe = clientReturning((_) => http.Response('ok', 200));
      final response = await probe.client.get(
        Uri.parse('https://api.example.com/health'),
      );

      expect(response.statusCode, 200);
      expect(probe.seen, hasLength(1));
    });

    test('traces a lookalike host rather than dropping it', () async {
      // A URL-prefix guard would have excluded this silently.
      await startPlugin();

      await okClient().get(Uri.parse('https://apm.example.com.evil.test/x'));

      expect(callsTo('spanStart'), hasLength(2));
    });
  });

  group('before start', () {
    test('performs the request without tracing it', () async {
      final probe = clientReturning((_) => http.Response('ok', 200));

      final response = await probe.client.get(
        Uri.parse('https://api.example.com/x'),
      );

      expect(response.statusCode, 200);
      expect(calls, isEmpty);
    });

    test('does not put the query string in the debug log', () async {
      // A log is somewhere the URL is recorded, and this is the one path that
      // reaches a log with a URL before any sanitiser is configured.
      debugLoggingEnabled = true;
      final printed = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');

      addTearDown(() {
        debugPrint = previous;
        debugLoggingEnabled = false;
      });

      await clientReturning(
        (_) => http.Response('ok', 200),
      ).client.get(Uri.parse('https://api.example.com/x?token=secret'));

      expect(printed, isNotEmpty);
      expect(printed.join(' '), isNot(contains('secret')));
    });
  });

  group('closing', () {
    test('closes the wrapped client', () async {
      await startPlugin();

      var closed = false;
      final inner = MockClient((_) async => http.Response('{}', 200));
      final client = EdotHttpClient(_ClosingClient(inner, () => closed = true));

      client.close();

      expect(closed, isTrue);
    });
  });
}

/// Stands in for a transport failure without depending on `dart:io`.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}

class _ClosingClient extends http.BaseClient {
  _ClosingClient(this._inner, this._onClose);

  final http.Client _inner;
  final void Function() _onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    _onClose();
    _inner.close();
  }
}
