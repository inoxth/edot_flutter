import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter_dio/inoxth_edot_flutter_dio.dart';

/// Example app for `inoxth_edot_flutter`, exercising every documented feature.
///
/// Deliberately starts with Tracking Consent **pending**, which is what an app under a
/// consent obligation should do: nothing is emitted until the user answers on the Consent
/// tab. It is not the Plugin's default — that is `granted`, to match this organisation's
/// React Native SDK — so the app also demonstrates the choice a regulated app has to make.
///
/// Point it at a collector with:
///
///   flutter run --dart-define=EDOT_SERVER_URL=http://10.0.2.2:4318
const _serverUrl = String.fromEnvironment(
  'EDOT_SERVER_URL',
  defaultValue: 'http://localhost:4318',
);

Future<void> main() async {
  // Before `runApp`, so the widget tree's own errors are captured from the first frame.
  // Telemetry produced before this call would be held and replayed rather than lost
  // (ADR-0005) — starting early just leaves less to hold.
  await Edot.start(
    EdotConfig(
      serviceName: 'edot-flutter-example',
      serviceVersion: '1.0.0',
      deploymentEnvironment: 'example',
      serverUrl: _serverUrl,
      debug: true,

      // Nothing is emitted until the user answers on the Consent tab.
      trackingConsent: EdotTrackingConsent.pending,

      // Traces every request the app makes over dart:io, including ones inside
      // dependencies. Requests to the collector's own host are never traced (ADR-0006).
      traceAllHttpTraffic: true,
    ),
  );

  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'EDOT Flutter example',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),

    // One Screen Span per transition, and the Active View that attributes every other
    // signal to the screen it came from.
    navigatorObservers: [
      EdotNavigatorObserver(
        // Route names are often not what a dashboard should show. GoRouter's paths in
        // particular; this is where you fix that. Returning null falls back to the
        // Plugin's own derivation.
        screenNameExtractor: (route) => switch (route.settings.name) {
          '/' => 'Home',
          '/detail' => 'Order detail',
          _ => null,
        },
      ),
    ],
    routes: {
      '/': (_) => const HomePage(),
      '/detail': (_) => const DetailPage(),
    },
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _tabs = ['Telemetry', 'Network', 'Errors', 'Consent'];
  int _tab = 0;

  void _selectTab(int index) {
    // A tab switch pushes no route, so no `NavigatorObserver` can see it. Without this
    // call the Active View would still name the screen the user left, and every signal
    // would be attributed to it. Tab switches get no Screen Span — a Screen Span measures
    // a transition the framework reported, and this is not one (ADR-0004).
    Edot.setActiveView(_tabs[index]);
    setState(() => _tab = index);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('EDOT example — ${_tabs[_tab]}')),
    body: switch (_tab) {
      0 => const _TelemetryTab(),
      1 => const _NetworkTab(),
      2 => const _ErrorsTab(),
      _ => const _ConsentTab(),
    },
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: _selectTab,
      destinations: const [
        NavigationDestination(icon: Icon(Icons.insights), label: 'Telemetry'),
        NavigationDestination(icon: Icon(Icons.cloud), label: 'Network'),
        NavigationDestination(icon: Icon(Icons.error_outline), label: 'Errors'),
        NavigationDestination(icon: Icon(Icons.privacy_tip), label: 'Consent'),
      ],
    ),
  );
}

/// Spans, log records, metrics, and the Session identifier.
class _TelemetryTab extends StatefulWidget {
  const _TelemetryTab();

  @override
  State<_TelemetryTab> createState() => _TelemetryTabState();
}

class _TelemetryTabState extends State<_TelemetryTab> {
  String _sessionId = 'not read yet';

  Future<void> _readSessionId() async {
    final id = await Edot.currentSessionId();
    setState(() {
      // Empty on Android, always: its Agent exposes the session manager only as internal
      // API (ADR-0001). A support screen has to handle that rather than display it.
      _sessionId = id.isEmpty
          ? 'empty — expected on Android, and before start'
          : id;
    });
  }

  Future<void> _spanWithChildren() async {
    final checkout = Edot.tracer.startSpan(
      'checkout',
      kind: EdotSpanKind.internal,
    )..setString('cart.currency', 'THB');

    // Nesting is explicit. Being the most recently started span does not make a span a
    // parent — that rule produces wrong trace trees as soon as two async flows overlap.
    await Edot.tracer.runWithParent(checkout, () async {
      final reserve = Edot.tracer.startSpan('reserve-stock');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      reserve.end();
    });

    checkout
      ..setInt('cart.items', 3)
      ..end();
  }

  @override
  Widget build(BuildContext context) => _Actions(
    children: [
      _Note(
        'Every signal here carries the Active View — switch tabs and watch '
        'screen.name change on what you emit next.',
      ),
      _Action(
        'Span with a nested child',
        'Two spans, the second a child of the first via runWithParent.',
        _spanWithChildren,
      ),
      _Action('Log record', 'A structured event that is not an operation.', () {
        Edot.log(
          EdotSeverity.warn,
          'cart abandoned',
          attributes: {'cart.items': 3, 'cart.value': 199.5, 'guest': true},
        );
      }),
      _Action(
        'Metric',
        'Attributes are String-valued only — a limit of the pinned iOS meter (ADR-0012).',
        () {
          Edot.recordMetric(
            'checkout.completed',
            1,
            attributes: {'tier': 'gold'},
          );
        },
      ),
      _Action(
        'Flush',
        'Drains the Plugin\'s buffers. Does NOT promise delivery (ADR-0011).',
        Edot.flush,
      ),
      _Action('Read Session identifier', _sessionId, _readSessionId),
      _Action(
        'Push a screen',
        'A Screen Span, named by the extractor rather than the route.',
        () => Navigator.of(context).pushNamed('/detail'),
      ),
    ],
  );
}

/// All three ways a request gets traced.
class _NetworkTab extends StatelessWidget {
  const _NetworkTab();

  static const _url = 'https://example.com/';

  Future<void> _viaEdotHttpClient() async {
    final client = EdotHttpClient(http.Client());
    try {
      await client.get(Uri.parse(_url));
    } finally {
      client.close();
    }
  }

  Future<void> _viaDio() async {
    final dio = Dio()..interceptors.add(EdotDioInterceptor());
    await dio.get<void>(_url);
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
  }

  @override
  Widget build(BuildContext context) => _Actions(
    children: [
      _Note(
        'This app enables traceAllHttpTraffic, so all three produce exactly one span '
        'each — a request is never traced twice (ADR-0014). One request also produces '
        'a synthetic parent span on iOS, so counts differ by platform (ADR-0001).',
      ),
      _Action(
        'EdotHttpClient',
        'Wraps one package:http client explicitly.',
        _viaEdotHttpClient,
      ),
      _Action(
        'Dio interceptor',
        'From the companion package, which ships separately (ADR-0010).',
        _viaDio,
      ),
      _Action(
        'Bare dart:io HttpClient',
        'Untouched by the app, traced by the override.',
        _viaAppWideTracing,
      ),
    ],
  );
}

/// Every path a Dart Error can arrive by.
class _ErrorsTab extends StatefulWidget {
  const _ErrorsTab();

  @override
  State<_ErrorsTab> createState() => _ErrorsTabState();
}

class _ErrorsTabState extends State<_ErrorsTab> {
  bool _breakSubtree = false;

  @override
  Widget build(BuildContext context) => _Actions(
    children: [
      _Note(
        'All of these are non-fatal log records with error.source naming their origin. '
        'None counts towards crash-free rate, which reflects native crashes only '
        '(ADR-0008) — and Android captures none of those at all (ADR-0009).',
      ),
      _Action(
        'Uncaught async error',
        'Captured with no guarded zone needed.',
        () => Future<void>.error(StateError('an uncaught async failure')),
      ),
      _Action(
        'Reported by the app',
        'For a failure you handled but still want to know about.',
        () => Edot.reportError(
          StateError('a handled failure'),
          stackTrace: StackTrace.current,
        ),
      ),
      _Action(
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
      _Action(
        'Error in a spawned isolate',
        'The one case an app must wire up itself.',
        () => Isolate.spawn(
          _failingIsolate,
          null,
          onError: Edot.isolateErrorPort,
        ),
      ),
      _Action(
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
            child: Text('This subtree failed to build: \$error'),
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

/// All three Tracking Consent states, and what each one means.
class _ConsentTab extends StatefulWidget {
  const _ConsentTab();

  @override
  State<_ConsentTab> createState() => _ConsentTabState();
}

class _ConsentTabState extends State<_ConsentTab> {
  static const _meanings = {
    EdotTrackingConsent.granted: 'Emitting. The user said yes.',
    EdotTrackingConsent.notGranted: 'Silent. The user said no.',
    EdotTrackingConsent.pending: 'Silent. We have not asked yet.',
  };

  @override
  Widget build(BuildContext context) => _Actions(
    children: [
      _Note(
        'Takes effect on the very next emission, in either direction, with no restart. '
        'Telemetry produced while consent is withheld is discarded rather than held — '
        'granting later does not release it. Withdrawing cannot retract what has '
        'already been exported (ADR-0015).',
      ),
      RadioGroup<EdotTrackingConsent>(
        groupValue: Edot.trackingConsent,
        onChanged: (value) {
          if (value == null) return;
          setState(() => Edot.setTrackingConsent(value));
        },
        child: Column(
          children: [
            for (final consent in EdotTrackingConsent.values)
              RadioListTile<EdotTrackingConsent>(
                value: consent,
                title: Text(consent.wireValue),
                subtitle: Text(_meanings[consent]!),
              ),
          ],
        ),
      ),
      _Note(
        'The gate covers what this Plugin emits, not what the Agent collects by itself. '
        'On iOS, crash reports and lifecycle events are produced natively and bypass it '
        '— an app that must emit nothing before consent is resolved should use '
        'disableAgent and start the Agent afterwards.',
      ),
    ],
  );
}

/// A pushed route, so navigation produces a Screen Span with a `last.screen.name`.
class DetailPage extends StatelessWidget {
  const DetailPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Order detail')),
    body: const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'This screen produced a Screen Span named "Order detail - view appearing", '
          'carrying last.screen.name for wherever you came from. It is named by the '
          'extractor, not by its route.',
          textAlign: TextAlign.center,
        ),
      ),
    ),
  );
}

class _Actions extends StatelessWidget {
  const _Actions({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(16), children: children);
}

class _Action extends StatelessWidget {
  const _Action(this.label, this.description, this.onPressed);

  final String label;
  final String description;
  final FutureOr<void> Function() onPressed;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      title: Text(label),
      subtitle: Text(description),
      trailing: const Icon(Icons.play_arrow),
      onTap: () => onPressed(),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
}
