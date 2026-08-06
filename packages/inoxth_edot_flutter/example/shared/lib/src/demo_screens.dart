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

  @override
  Widget build(BuildContext context) => DemoScreen(
    title: 'Network',
    children: [
      const DemoNote(
        'This app enables traceAllHttpTraffic, so all three produce exactly one span '
        'each - a request is never traced twice (ADR-0014). One request also produces '
        'a synthetic parent span on iOS, so counts differ by platform (ADR-0001).',
      ),
      DemoActionTile(
        'EdotHttpClient',
        'Wraps one package:http client explicitly.',
        _viaEdotHttpClient,
      ),
      DemoActionTile(
        'Dio interceptor',
        'From the companion package, which ships separately (ADR-0010).',
        _viaDio,
      ),
      DemoActionTile(
        'Bare dart:io HttpClient',
        'Untouched by the app, traced by the override.',
        _viaAppWideTracing,
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
        'Attributes are String-valued only - a limit of the pinned iOS meter (ADR-0012).',
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

/// A structured event that is not an operation.
class LogsScreen extends StatelessWidget {
  const LogsScreen({super.key});

  @override
  Widget build(BuildContext context) => DemoScreen(
    title: 'Logs',
    children: [
      const DemoNote(
        'A log record is an event you want to see, not an operation you time.',
      ),
      DemoActionTile(
        'Log record',
        'A structured event with typed attributes.',
        () {
          Edot.log(
            EdotSeverity.warn,
            'cart abandoned',
            attributes: {'cart.items': 3, 'cart.value': 199.5, 'guest': true},
          );
          demoLog.add('Emitted a "cart abandoned" log record');
        },
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
        'None counts towards crash-free rate, which reflects native crashes only '
        '(ADR-0008) - and Android captures none of those at all (ADR-0009).',
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
