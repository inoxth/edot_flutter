import 'package:flutter/material.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter_example_shared/inoxth_edot_flutter_example_shared.dart';

/// The `Navigator` flavor of the inoxth_edot_flutter example.
///
/// Everything the app shows lives in the shared package; this file is only the
/// integration recipe: load `.env`, start the Agent, and wire Flutter's built-in
/// `Navigator` to the Plugin. The go_router flavor differs from this file alone.
///
/// Configuration comes from this flavor's `.env`. Copy `.env.example` to `.env` and
/// point `EDOT_SERVER_URL` at your collector; on an Android emulator that is usually
/// `http://10.0.2.2:4318`. With no server URL the app shows a "Missing .env" screen
/// instead of starting the Agent.
Future<void> main() async {
  // dotenv reads the app's asset bundle, so the binding has to exist first.
  WidgetsFlutterBinding.ensureInitialized();

  // Built from `.env` at the edge; the mapping and the missing-config guard are proven in
  // the shared package's Seam 1 tests. Telemetry produced before `Edot.start` is held and
  // replayed rather than lost (ADR-0005), so starting once config is known loses nothing.
  final result = await loadDemoConfig(
    debug: true,

    // Traces every request the app makes over dart:io, including ones inside
    // dependencies. Requests to the collector's own host are never traced (ADR-0006).
    traceAllHttpTraffic: true,

    // Starts granted, the Plugin default and a Fleet Alignment choice; the Settings tab
    // lets you switch it and watch the gate take effect (ADR-0015).
    trackingConsent: EdotTrackingConsent.granted,
  );

  switch (result) {
    case DemoConfigReady(:final config):
      await Edot.start(config);
      runApp(ExampleApp(config: config));
    case DemoConfigMissing(:final reason):
      runApp(MissingEnvApp(reason: reason));
  }
}

/// Shown when `.env` carries no `EDOT_SERVER_URL`, so the Agent is never started.
class MissingEnvApp extends StatelessWidget {
  const MissingEnvApp({required this.reason, super.key});

  final String reason;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'EDOT Flutter example',
    home: Scaffold(
      appBar: AppBar(title: const Text('EDOT example — configuration needed')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(reason, textAlign: TextAlign.center),
        ),
      ),
    ),
  );
}

/// Wires the shared demo to Flutter's built-in `Navigator`.
class ExampleApp extends StatelessWidget {
  const ExampleApp({required this.config, super.key});

  final EdotConfig config;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'EDOT Flutter example',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),

    // One Screen Span per route transition, and the Active View that attributes every
    // other signal to the screen it came from. The screen-name extractor is shared, so
    // the go_router flavor names its screens identically.
    navigatorObservers: [
      EdotNavigatorObserver(
        screenNameExtractor: (route) => demoScreenNameFor(route.settings.name),
      ),
    ],
    routes: {
      '/': (_) => DemoHome(
        config: config,
        onOpenDemo: (context, destination) =>
            Navigator.of(context).pushNamed(destination.routeName),
      ),
      for (final destination in DemoDestination.values)
        destination.routeName: (_) => demoScreenFor(destination),
    },
  );
}
