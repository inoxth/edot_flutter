import 'package:flutter/material.dart';

import 'demo_screens.dart';

/// A per-category demo screen the Demos list can open.
///
/// Deliberately router-agnostic: it carries a stable [routeName] and a title, but
/// knows nothing about how a flavor app pushes it. The navigator flavor registers
/// [routeName] as a named route; the go_router flavor registers it as a path.
enum DemoDestination {
  network('Network', Icons.cloud, 'All three ways a request gets traced.'),
  tracing(
    'Tracing',
    Icons.account_tree,
    'Spans, and explicit parent/child nesting.',
  ),
  metrics('Metrics', Icons.speed, 'Counter, up-down counter and histogram.'),
  logs(
    'Logs',
    Icons.description,
    'A structured event that is not an operation.',
  ),
  errors(
    'Errors',
    Icons.error_outline,
    'Every path a Dart Error can arrive by.',
  ),
  interaction(
    'Interaction',
    Icons.touch_app,
    'A user action, modelled as a manual span.',
  );

  const DemoDestination(this.title, this.icon, this.summary);

  final String title;
  final IconData icon;
  final String summary;

  /// The route path this destination is registered and pushed at.
  String get routeName => '/$name';
}

/// The screen widget for [destination]. Leaf screens - they never navigate on.
Widget demoScreenFor(DemoDestination destination) => switch (destination) {
  DemoDestination.network => const NetworkScreen(),
  DemoDestination.tracing => const TracingScreen(),
  DemoDestination.metrics => const MetricsScreen(),
  DemoDestination.logs => const LogsScreen(),
  DemoDestination.errors => const ErrorsScreen(),
  DemoDestination.interaction => const InteractionScreen(),
};

/// Maps a route name to the low-cardinality Screen Name the observer should use.
///
/// Both flavors pass this to `EdotNavigatorObserver(screenNameExtractor: ...)`, so a
/// pushed demo is named by what it is rather than by its raw path.
String? demoScreenNameFor(String? routeName) {
  if (routeName == null) return null;
  if (routeName == '/') return 'Home';
  // Any /orders/... route - resolved ('/orders/42') or templated ('/orders/:id') -
  // collapses to one Screen Name, so ids do not explode dashboard cardinality.
  if (routeName.startsWith('/orders/')) return 'Order detail';
  for (final destination in DemoDestination.values) {
    if (destination.routeName == routeName) return destination.title;
  }
  return null;
}
