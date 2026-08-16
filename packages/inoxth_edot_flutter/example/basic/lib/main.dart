import 'package:flutter/material.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter_example_shared/inoxth_edot_flutter_example_shared.dart';

/// The `basic` flavor: the smallest inoxth_edot_flutter integration.
///
/// One scrollable screen, no navigation and no network - just `Edot.start` from
/// `env/local.env` and a handful of signals. See the navigator and go_router flavors for
/// screen tracking and request tracing. Copy `env/local.env.example` to `env/local.env` first.
Future<void> main() async {
  // dotenv reads the app's asset bundle, so the binding has to exist first.
  WidgetsFlutterBinding.ensureInitialized();

  // Consent defaults to granted; the basic flavor has no consent UI.
  final result = await loadDemoConfig(debug: true);

  switch (result) {
    case DemoConfigReady(:final config):
      await Edot.start(config);
      runApp(const BasicExampleApp());
    case DemoConfigMissing(:final reason):
      runApp(MissingEnvApp(reason: reason));
  }
}

/// A single-screen app over the shared demo widgets.
class BasicExampleApp extends StatelessWidget {
  const BasicExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'EDOT basic example',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: const _BasicHome(),
  );
}

class _BasicHome extends StatefulWidget {
  const _BasicHome();

  @override
  State<_BasicHome> createState() => _BasicHomeState();
}

class _BasicHomeState extends State<_BasicHome> {
  String _sessionId = 'not read yet';
  bool _breakSubtree = false;

  Future<void> _readSessionId() async {
    final id = await Edot.currentSessionId();
    setState(() {
      // Empty on Android by design; a real app handles that rather than show it.
      _sessionId = id.isEmpty
          ? 'empty — expected on Android, and before start'
          : id;
    });
  }

  Future<void> _spanWithChild() async {
    final checkout = Edot.tracer.startSpan(
      'checkout',
      kind: EdotSpanKind.internal,
    )..setString('cart.currency', 'THB');
    await Edot.tracer.runWithParent(checkout, () async {
      Edot.tracer.startSpan('reserve-stock').end();
    });
    checkout.end();
  }

  @override
  Widget build(BuildContext context) => DemoScreen(
    title: 'EDOT basic example',
    children: [
      const DemoNote(
        'The smallest integration: Edot.start from env/local.env, then a few signals. No '
        'navigation and no network - the navigator and go_router flavors cover those.',
      ),
      DemoActionTile(
        'Span with a nested child',
        'Two spans, the second a child of the first via runWithParent.',
        _spanWithChild,
      ),
      DemoActionTile(
        'Record a metric',
        'A counter with a String attribute.',
        () {
          Edot.recordMetric('app.opened', 1, attributes: {'flavor': 'basic'});
        },
      ),
      DemoActionTile('Write a log record', 'A structured event.', () {
        Edot.log(
          EdotSeverity.info,
          'hello from the basic flavor',
          attributes: {'flavor': 'basic'},
        );
      }),
      DemoActionTile(
        'Report an error',
        'A non-fatal Dart Error the app handled but wants to know about.',
        () => Edot.reportError(
          StateError('a handled failure'),
          stackTrace: StackTrace.current,
        ),
      ),
      DemoActionTile('Read Session identifier', _sessionId, _readSessionId),
      DemoActionTile(
        _breakSubtree ? 'Rebuild the subtree' : 'Break a widget subtree',
        'EdotErrorBoundary records the build failure and shows a fallback.',
        () => setState(() => _breakSubtree = !_breakSubtree),
      ),
      EdotErrorBoundary(
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
