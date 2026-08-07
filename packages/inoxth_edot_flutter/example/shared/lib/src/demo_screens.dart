import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter_dio/inoxth_edot_flutter_dio.dart';

import 'demo_widgets.dart';

/// All three ways a request gets traced.
class NetworkScreen extends StatelessWidget {
  const NetworkScreen({super.key});

  static const _url = 'https://example.com/';
  static const _unreachableUrl = 'https://does-not-exist.invalid/';

  Future<void> _viaEdotHttpClient() async {
    final client = EdotHttpClient(http.Client());
    try {
      await client.get(Uri.parse(_url));
    } finally {
      client.close();
    }
    demoLog.add('Traced a request via EdotHttpClient');
  }

  Future<void> _viaDio() async {
    final dio = Dio()..interceptors.add(EdotDioInterceptor());
    await dio.get<void>(_url);
    demoLog.add('Traced a request via the Dio interceptor');
  }

  Future<void> _viaAppWideTracing() async {
    // Nothing here mentions the Plugin. It is traced because the app was started with
    // traceAllHttpTraffic, which is what covers requests inside dependencies.
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(_url));
      final response = await request.close();
      await response.drain<void>();
    } finally {
      client.close();
    }
    demoLog.add('Traced a bare dart:io request app-wide');
  }

  Future<void> _failedRequest() async {
    final client = EdotHttpClient(http.Client());
    try {
      await client.get(Uri.parse(_unreachableUrl));
    } catch (_) {
      // The span still reports - it records the failure rather than the response.
      demoLog.add('Traced a failed request (the span records the error)');
    } finally {
      client.close();
    }
  }

  Future<void> _sequentialRequests() async {
    final client = EdotHttpClient(http.Client());
    try {
      for (var n = 1; n <= 3; n++) {
        await client.get(Uri.parse('$_url?n=$n'));
      }
    } finally {
      client.close();
    }
    demoLog.add('Traced three sequential requests, one span each');
  }

  @override
  Widget build(BuildContext context) => DemoScreen(
    title: 'Network',
    children: [
      const DemoNote(
        'This app enables traceAllHttpTraffic, so all three produce exactly one span '
        'each - a request is never traced twice. One request also produces '
        'a synthetic parent span on iOS, so counts differ by platform.',
      ),
      DemoActionTile(
        'EdotHttpClient',
        'Wraps one package:http client explicitly.',
        _viaEdotHttpClient,
      ),
      DemoActionTile(
        'Dio interceptor',
        'From the companion package, which ships separately.',
        _viaDio,
      ),
      DemoActionTile(
        'Bare dart:io HttpClient',
        'Untouched by the app, traced by the override.',
        _viaAppWideTracing,
      ),
      DemoActionTile(
        'Failed request',
        'A request to an unreachable host; the span records the failure.',
        _failedRequest,
      ),
      DemoActionTile(
        'Three sequential requests',
        'Each produces its own span.',
        _sequentialRequests,
      ),
    ],
  );
}

/// Spans, and explicit parent/child nesting.
class TracingScreen extends StatelessWidget {
  const TracingScreen({super.key});

  Future<void> _spanWithChildren() async {
    final checkout = Edot.tracer.startSpan(
      'checkout',
      kind: EdotSpanKind.internal,
    )..setString('cart.currency', 'THB');

    // Nesting is explicit. Being the most recently started span does not make a span a
    // parent - that rule produces wrong trace trees as soon as two async flows overlap.
    await Edot.tracer.runWithParent(checkout, () async {
      final reserve = Edot.tracer.startSpan('reserve-stock');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      reserve.end();
    });

    checkout
      ..setInt('cart.items', 3)
      ..end();
    demoLog.add('Emitted a checkout span with a nested child');
  }

  @override
  Widget build(BuildContext context) => DemoScreen(
    title: 'Tracing',
    children: [
      const DemoNote(
        'The span carries the Active View of the screen you opened this demo from.',
      ),
      DemoActionTile(
        'Span with a nested child',
        'Two spans, the second a child of the first via runWithParent.',
        _spanWithChildren,
      ),
    ],
  );
}

/// Counter, up-down counter and histogram.
class MetricsScreen extends StatelessWidget {
  const MetricsScreen({super.key});

  @override
  Widget build(BuildContext context) => DemoScreen(
    title: 'Metrics',
    children: [
      const DemoNote(
        'Attributes are String-valued only - a limit of the pinned iOS meter.',
      ),
      DemoActionTile('Counter', 'A value that only ever increases.', () {
        Edot.recordMetric(
          'checkout.completed',
          1,
          attributes: {'tier': 'gold'},
        );
        demoLog.add('Recorded checkout.completed (counter)');
      }),
      DemoActionTile(
        'Up-down counter',
        'A value that can go both ways, such as items in a cart.',
        () {
          Edot.recordMetric(
            'cart.items',
            -1,
            kind: EdotMetricKind.upDownCounter,
            attributes: {'tier': 'gold'},
          );
          demoLog.add('Recorded cart.items (up-down counter)');
        },
      ),
      DemoActionTile(
        'Histogram',
        'A distribution, such as a request duration.',
        () {
          Edot.recordMetric(
            'checkout.duration_ms',
            182,
            kind: EdotMetricKind.histogram,
            attributes: {'tier': 'gold'},
          );
          demoLog.add('Recorded checkout.duration_ms (histogram)');
        },
      ),
    ],
  );
}

/// A structured event that is not an operation, at each severity.
class LogsScreen extends StatelessWidget {
  const LogsScreen({super.key});

  void _emit(EdotSeverity severity, String message) {
    Edot.log(
      severity,
      message,
      attributes: {'cart.items': 3, 'cart.value': 199.5, 'guest': true},
    );
    demoLog.add('Emitted a $message (${severity.name}) log record');
  }

  @override
  Widget build(BuildContext context) => DemoScreen(
    title: 'Logs',
    children: [
      const DemoNote(
        'A log record is an event you want to see, not an operation you time. '
        'The same record is emitted at each severity so you can see how the '
        'collector ranks them; every severity carries the same typed attributes.',
      ),
      DemoActionTile(
        'Debug',
        'Diagnostic detail useful while debugging.',
        () => _emit(EdotSeverity.debug, 'cart inspected'),
      ),
      DemoActionTile(
        'Info',
        'An ordinary informational record.',
        () => _emit(EdotSeverity.info, 'cart viewed'),
      ),
      DemoActionTile(
        'Warn',
        'A concern that did not stop the operation.',
        () => _emit(EdotSeverity.warn, 'cart abandoned'),
      ),
      DemoActionTile(
        'Error',
        'A failure in the operation.',
        () => _emit(EdotSeverity.error, 'checkout failed'),
      ),
    ],
  );
}

/// Every path a Dart Error can arrive by.
class ErrorsScreen extends StatefulWidget {
  const ErrorsScreen({super.key});

  @override
  State<ErrorsScreen> createState() => _ErrorsScreenState();
}

class _ErrorsScreenState extends State<ErrorsScreen> {
  bool _breakSubtree = false;

  @override
  Widget build(BuildContext context) => DemoScreen(
    title: 'Errors',
    children: [
      const DemoNote(
        'All of these are non-fatal log records with error.source naming their origin. '
        'None counts towards crash-free rate, which reflects native crashes only, '
        'and Android captures none of those at all.',
      ),
      DemoActionTile(
        'Uncaught async error',
        'Captured with no guarded zone needed.',
        () => Future<void>.error(StateError('an uncaught async failure')),
      ),
      DemoActionTile(
        'Reported by the app',
        'For a failure you handled but still want to know about.',
        () => Edot.reportError(
          StateError('a handled failure'),
          stackTrace: StackTrace.current,
        ),
      ),
      DemoActionTile(
        'Error inside an operation',
        'Recorded on the span as well as on its own, and fails the span.',
        () {
          final span = Edot.tracer.startSpan('risky-operation');
          Edot.tracer.runWithParent(span, () {
            Edot.reportError(StateError('failed inside the operation'));
          });
          span.end();
        },
      ),
      DemoActionTile(
        'Error in a spawned isolate',
        'The one case an app must wire up itself.',
        () => Isolate.spawn(
          _failingIsolate,
          null,
          onError: Edot.isolateErrorPort,
        ),
      ),
      DemoActionTile(
        _breakSubtree ? 'Rebuild the subtree' : 'Break a widget subtree',
        'EdotErrorBoundary records the build failure and shows a fallback.',
        () => setState(() => _breakSubtree = !_breakSubtree),
      ),
      EdotErrorBoundary(
        // Receives the error, so a debug build can show it and a release build need not.
        fallback: (error) => Card(
          color: Theme.of(context).colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text('This subtree failed to build: $error'),
          ),
        ),
        child: Builder(
          builder: (_) => _breakSubtree
              ? throw StateError('this subtree cannot build')
              : const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('This subtree builds fine.'),
                  ),
                ),
        ),
      ),
    ],
  );
}

/// Entry point for the spawned-isolate demonstration.
void _failingIsolate(void _) => throw StateError('the isolate went wrong');

/// A user interaction, modelled as a manual span.
///
/// The Plugin has no dedicated interaction API (unlike the React Native SDK's
/// `trackAction`), so this models a tracked action the way one is built from
/// primitives: a short span named for the action, tagged with what was touched.
/// It carries the Active View of this screen like any other span.
class InteractionScreen extends StatelessWidget {
  const InteractionScreen({super.key});

  Future<void> _trackTap() async {
    final span =
        Edot.tracer.startSpan('interaction', kind: EdotSpanKind.internal)
          ..setString('interaction.type', 'tap')
          ..setString('interaction.element', 'checkout-button');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    span.end();
    demoLog.add('Tracked a tap interaction as a span');
  }

  @override
  Widget build(BuildContext context) => DemoScreen(
    title: 'Interaction',
    children: [
      const DemoNote(
        'There is no dedicated interaction API. A tracked UI action is just a short '
        'span named for the action, so this wraps one in exactly that.',
      ),
      DemoActionTile(
        'Track a tap',
        'Wraps a user action in a span with interaction attributes.',
        _trackTap,
      ),
    ],
  );
}

/// A parameterised route, opened with an order id, to show Screen Name normalization.
///
/// Different ids push different paths, but the shared screen-name extractor collapses
/// every `/orders/...` route to one low-cardinality Screen Name, so a dashboard is not
/// flooded with one screen per order.
class OrderDetailScreen extends StatelessWidget {
  const OrderDetailScreen({required this.orderId, super.key});

  /// The order this screen was opened for; changes per push, unlike the Screen Name.
  final String orderId;

  @override
  Widget build(BuildContext context) => DemoScreen(
    title: 'Order detail',
    children: [
      DemoNote(
        'Opened for order #$orderId. Its Screen Name is the fixed "Order detail" - '
        'the extractor collapses every /orders/... path to one name, so ids do not '
        'explode dashboard cardinality.',
      ),
    ],
  );
}
