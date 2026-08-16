import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter_example_shared/inoxth_edot_flutter_example_shared.dart';

/// The `go_router` flavor of the inoxth_edot_flutter example.
///
/// Every screen it shows comes from the shared package - this file differs from the
/// navigator flavor only in how navigation is wired: a `GoRouter` whose `observers`
/// include the same `EdotNavigatorObserver`, and `context.push` in place of
/// `Navigator.pushNamed`.
///
/// Configuration comes from this flavor's `env/local.env`. Copy `env/local.env.example` to it and
/// point `EDOT_SERVER_URL` at your collector; on an Android emulator that is usually
/// `http://10.0.2.2:4318`. With no server URL the app shows its "configuration needed" screen.
Future<void> main() async {
  // dotenv reads the app's asset bundle, so the binding has to exist first.
  WidgetsFlutterBinding.ensureInitialized();

  final result = await loadDemoConfig(
    debug: true,
    traceAllHttpTraffic: true,
    // Starts granted, the Plugin default; the Settings tab lets you switch it.
    trackingConsent: EdotTrackingConsent.granted,
  );

  switch (result) {
    case DemoConfigReady(:final config):
      await Edot.start(config);
      runApp(GoRouterExampleApp(config: config));
    case DemoConfigMissing(:final reason):
      runApp(MissingEnvApp(reason: reason));
  }
}

/// Wires the shared demo to `go_router`.
class GoRouterExampleApp extends StatefulWidget {
  const GoRouterExampleApp({required this.config, super.key});

  final EdotConfig config;

  @override
  State<GoRouterExampleApp> createState() => _GoRouterExampleAppState();
}

class _GoRouterExampleAppState extends State<GoRouterExampleApp> {
  late final GoRouter _router = GoRouter(
    // The same EdotNavigatorObserver and shared screen-name extractor as the navigator
    // flavor - go_router just takes the observer in its `observers` list, attaching it to
    // the Navigator it drives, so pushes produce Screen Spans exactly as they do there.
    observers: [
      EdotNavigatorObserver(
        screenNameExtractor: (route) => demoScreenNameFor(route.settings.name),
      ),
    ],
    // Each page's `name` becomes the Route's settings.name the extractor reads. These
    // routes take no path parameters; if you add one, name the page with the route
    // template ('/orders/:id') rather than the resolved location ('/orders/42'), so the
    // Screen Name stays low-cardinality.
    routes: [
      GoRoute(
        path: '/',
        pageBuilder: (context, state) => MaterialPage(
          name: '/',
          child: DemoHome(
            config: widget.config,
            onOpenDemo: (context, destination) async {
              await context.push<void>(destination.routeName);
            },
            onOpenOrder: (context, orderId) async {
              await context.push<void>('/orders/$orderId');
            },
          ),
        ),
      ),
      for (final destination in DemoDestination.values)
        GoRoute(
          path: destination.routeName,
          pageBuilder: (context, state) => MaterialPage(
            name: destination.routeName,
            child: demoScreenFor(destination),
          ),
        ),
      // A path parameter. The page is named with the template ('/orders/:id'), not the
      // resolved location, so every order shares one low-cardinality Screen Name - the
      // exact case the comment above warns about.
      GoRoute(
        path: '/orders/:id',
        pageBuilder: (context, state) => MaterialPage(
          name: '/orders/:id',
          child: OrderDetailScreen(orderId: state.pathParameters['id']!),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'EDOT Flutter example (go_router)',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    routerConfig: _router,
  );
}
