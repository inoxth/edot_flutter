import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter/src/edot_channel.dart'
    show debugLoggingEnabled;

/// Seam 1 — the Trace Context a traced request carries.
///
/// The header values are the Agent's to produce; what is asserted here is which
/// requests ask for one, that the answer reaches the wire unchanged, and that a
/// request the Agent cannot answer for still goes out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  /// What the Agent replies to `spanTraceContext`. A real Agent answers with
  /// whatever its W3C propagator wrote, so the tests set this per case rather than
  /// hardcoding one shape.
  var context = <String, String>{
    'traceparent': '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
  };

  /// Set to make the channel call fail instead of answering.
  var contextFails = false;

  setUp(() {
    calls.clear();
    contextFails = false;
    context = <String, String>{
      'traceparent': '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
    };

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(edotChannelName), (
          call,
        ) async {
          calls.add(call);

          if (call.method != 'spanTraceContext') return null;
          if (contextFails) {
            throw PlatformException(code: 'no_agent', message: 'not running');
          }
          return context;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(edotChannelName), null);
    Edot.resetForTesting();
  });

  Future<void> startPlugin({
    List<Pattern>? tracePropagationTargets,
    List<Pattern> excludedUrls = const [],
    bool debug = false,
  }) async {
    await Edot.start(
      EdotConfig(
        serviceName: 'example-app',
        serviceVersion: '1.2.3',
        deploymentEnvironment: 'test',
        serverUrl: 'https://apm.example.com:4318',
        excludedUrls: excludedUrls,
        tracePropagationTargets: tracePropagationTargets,
        debug: debug,
      ),
    );
    calls.clear();
  }

  List<MethodCall> callsTo(String method) =>
      calls.where((c) => c.method == method).toList();

  Map<Object?, Object?> argumentsOf(MethodCall call) =>
      call.arguments as Map<Object?, Object?>;

  /// The client span of the two a traced request starts, the other being its
  /// Request Transaction (ADR-0016). Trace Context names this one.
  ///
  /// Found by its attributes: the pair matches what the iOS Agent manufactures, so
  /// name, kind and timestamps are identical on both.
  MethodCall requestSpan() => callsTo('spanStart').singleWhere(
    (c) => (argumentsOf(c)['attributes']! as Map<Object?, Object?>).containsKey(
      'http.url',
    ),
  );

  /// A client recording the requests that reached the transport, headers and all.
  ({EdotHttpClient client, List<http.BaseRequest> sent}) recordingClient() {
    final sent = <http.BaseRequest>[];
    final inner = MockClient((request) async {
      sent.add(request);
      return http.Response('{}', 200);
    });
    return (client: EdotHttpClient(inner), sent: sent);
  }

  group('the header', () {
    test('carries the traceparent the Agent returned', () async {
      await startPlugin();
      final probe = recordingClient();

      await probe.client.get(Uri.parse('https://api.example.com/orders'));

      expect(
        probe.sent.single.headers['traceparent'],
        '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
      );
    });

    test('names the span this request created', () async {
      // The link is only worth anything if it points at this request's span. A
      // header built from some other span would look perfectly valid in Kibana and
      // join the wrong trace.
      await startPlugin();

      await recordingClient().client.get(
        Uri.parse('https://api.example.com/orders'),
      );

      expect(
        argumentsOf(callsTo('spanTraceContext').single)['shadowId'],
        argumentsOf(requestSpan())['shadowId'],
        reason:
            'the header names the request span, not its Request Transaction',
      );
    });

    test('carries tracestate too, when the span has one', () async {
      // Not the Plugin's to interpret — a sampling decision from an upstream
      // system, which W3C requires be passed along untouched.
      context = {
        'traceparent':
            '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
        'tracestate': 'es=s:0.5',
      };
      await startPlugin();
      final probe = recordingClient();

      await probe.client.get(Uri.parse('https://api.example.com/orders'));

      expect(probe.sent.single.headers['tracestate'], 'es=s:0.5');
    });

    test('is set before the request leaves', () async {
      // Reading it off the recorded request is the assertion: `MockClient` sees the
      // request only once the transport has it.
      await startPlugin();
      final probe = recordingClient();

      await probe.client.get(Uri.parse('https://api.example.com/orders'));

      expect(probe.sent.single.headers, contains('traceparent'));
    });

    test('does not include the deprecated Elastic header', () async {
      // Elastic's own `elastic-apm-traceparent` is deprecated, and the Plugin adds
      // nothing of its own to what the propagator wrote.
      await startPlugin();
      final probe = recordingClient();

      await probe.client.get(Uri.parse('https://api.example.com/orders'));

      expect(
        probe.sent.single.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('elastic-apm-traceparent')),
      );
    });

    test('replaces a traceparent the caller had set', () async {
      // This span is the immediate parent of the request now. Leaving an outer
      // context in place would parent the receiving service's work to something
      // that did not make the call.
      await startPlugin();
      final probe = recordingClient();

      await probe.client.get(
        Uri.parse('https://api.example.com/orders'),
        headers: {
          'traceparent':
              '00-11111111111111111111111111111111-2222222222222222-01',
        },
      );

      expect(
        probe.sent.single.headers['traceparent'],
        '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
      );
    });
  });

  group('which requests carry it', () {
    test('every traced host, when no targets are configured', () async {
      // The same reach as the Agents' own instrumentation. A narrower default would
      // mean two rules to document for one app.
      await startPlugin();
      final probe = recordingClient();

      await probe.client.get(Uri.parse('https://api.example.com/orders'));
      await probe.client.get(Uri.parse('https://other.test/things'));

      expect(callsTo('spanTraceContext'), hasLength(2));
      expect(probe.sent[0].headers, contains('traceparent'));
      expect(probe.sent[1].headers, contains('traceparent'));
    });

    test('only a matching host, when targets are configured', () async {
      await startPlugin(tracePropagationTargets: ['api.example.com']);
      final probe = recordingClient();

      await probe.client.get(Uri.parse('https://api.example.com/orders'));
      await probe.client.get(Uri.parse('https://third-party.test/things'));

      // Not requested at all for the host left out — the point of the list is that
      // no trace identifier is fetched for it, not that one is fetched and dropped.
      expect(callsTo('spanTraceContext'), hasLength(1));
      expect(probe.sent[0].headers, contains('traceparent'));
      expect(probe.sent[1].headers, isNot(contains('traceparent')));
    });

    test('a host left out is still traced', () async {
      // Narrowing propagation costs the link, not the span.
      await startPlugin(tracePropagationTargets: ['api.example.com']);

      await recordingClient().client.get(
        Uri.parse('https://third-party.test/things'),
      );

      expect(callsTo('spanStart'), hasLength(2));
      expect(callsTo('spanEnd'), hasLength(2));
      expect(callsTo('spanTraceContext'), isEmpty);
    });

    test('nothing, when the target list is empty', () async {
      // An empty list is the only way to say "propagate to nothing", and is not the
      // same configuration as leaving it unset.
      await startPlugin(tracePropagationTargets: const []);
      final probe = recordingClient();

      await probe.client.get(Uri.parse('https://api.example.com/orders'));

      expect(callsTo('spanTraceContext'), isEmpty);
      expect(callsTo('spanStart'), hasLength(2));
      expect(probe.sent.single.headers, isNot(contains('traceparent')));
    });

    test('matches a target against the URL as given', () async {
      // Query string included, like the exclusion rules — matching a URL is not
      // recording it.
      await startPlugin(tracePropagationTargets: ['probe=1']);
      final probe = recordingClient();

      await probe.client.get(Uri.parse('https://api.example.com/x?probe=1'));
      await probe.client.get(Uri.parse('https://api.example.com/x?probe=0'));

      expect(probe.sent[0].headers, contains('traceparent'));
      expect(probe.sent[1].headers, isNot(contains('traceparent')));
    });

    test('matches a target as a regular expression', () async {
      await startPlugin(
        tracePropagationTargets: [RegExp(r'^https://[a-z]+\.internal\.test/')],
      );
      final probe = recordingClient();

      await probe.client.get(Uri.parse('https://orders.internal.test/x'));
      await probe.client.get(Uri.parse('https://orders.public.test/x'));

      expect(probe.sent[0].headers, contains('traceparent'));
      expect(probe.sent[1].headers, isNot(contains('traceparent')));
    });

    test('no request that produced no span', () async {
      // The Collector Host and an excluded URL are not traced, so there is no span
      // to name — and a header referencing a span nothing exported would be a link
      // to nowhere.
      await startPlugin(excludedUrls: ['/health']);
      final probe = recordingClient();

      await probe.client.post(
        Uri.parse('https://apm.example.com:4318/v1/traces'),
      );
      await probe.client.get(Uri.parse('https://api.example.com/health'));

      expect(calls, isEmpty);
      expect(probe.sent[0].headers, isNot(contains('traceparent')));
      expect(probe.sent[1].headers, isNot(contains('traceparent')));
    });

    test('none at all before the Plugin has started', () async {
      final probe = recordingClient();

      await probe.client.get(Uri.parse('https://api.example.com/orders'));

      expect(calls, isEmpty);
      expect(probe.sent.single.headers, isNot(contains('traceparent')));
    });
  });

  group('when the Agent has no context to give', () {
    test('sends the request uncorrelated rather than failing it', () async {
      // An Agent that has dropped the span, or was never started, answers with
      // nothing. A request must not fail because its telemetry could not be linked.
      context = {};
      await startPlugin();
      final probe = recordingClient();

      final response = await probe.client.get(
        Uri.parse('https://api.example.com/orders'),
      );

      expect(response.statusCode, 200);
      expect(probe.sent.single.headers, isNot(contains('traceparent')));
    });

    test('sends the request uncorrelated when the call itself fails', () async {
      contextFails = true;
      await startPlugin();
      final probe = recordingClient();

      final response = await probe.client.get(
        Uri.parse('https://api.example.com/orders'),
      );

      expect(response.statusCode, 200);
      expect(probe.sent.single.headers, isNot(contains('traceparent')));
    });

    test('says so in the debug log rather than dropping it silently', () async {
      // Correlation that stops working is otherwise invisible: the requests still
      // succeed and the spans still arrive, only the traces stop joining up.
      final printed = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');

      addTearDown(() {
        debugPrint = previous;
        debugLoggingEnabled = false;
      });

      contextFails = true;
      // Through the configuration, as an integrator would: `Edot.start` is what
      // turns the Plugin's logging on.
      await startPlugin(debug: true);

      await recordingClient().client.get(
        Uri.parse('https://api.example.com/orders'),
      );

      expect(printed.join(' '), contains('spanTraceContext'));
    });

    test('still ends the span', () async {
      contextFails = true;
      await startPlugin();

      await recordingClient().client.get(
        Uri.parse('https://api.example.com/orders'),
      );

      expect(callsTo('spanEnd'), hasLength(2));
    });
  });
}
