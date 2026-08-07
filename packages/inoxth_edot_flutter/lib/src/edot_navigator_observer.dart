import 'package:flutter/widgets.dart';

import 'edot.dart';
import 'edot_channel.dart';
import 'edot_screen_name.dart';
import 'edot_view_claims.dart';

/// Emits a Screen Span per navigation and keeps the Active View current.
///
/// Add it once and every navigation is traced, with no per-route annotation:
///
/// ```dart
/// MaterialApp(
///   navigatorObservers: [EdotNavigatorObserver()],
///   // ...
/// )
/// ```
///
/// Each navigation sets the Active View — so every span and log that follows is attributed
/// to the new screen (ADR-0004) — and starts a Screen Span that ends when the destination's
/// first frame renders, measuring what the user actually waited for.
///
/// The Screen Span is deliberately a transition, not a span held open while the screen is
/// visible. A screen open for ten minutes would otherwise become one trace with hundreds
/// of children, which breaks trace waterfalls, head sampling and span limits.
///
/// Switches that do not go through a `Navigator` — tabs, a bottom navigation bar, an
/// `IndexedStack` — are invisible here, because no route changes. Call
/// `Edot.setActiveView` for those; they have no transition to measure, so they get no
/// Screen Span.
class EdotNavigatorObserver extends NavigatorObserver {
  /// Creates the observer. Pass [screenNameExtractor] to name screens from a
  /// router's own route templates; omit it to use the Plugin's derivation.
  EdotNavigatorObserver({this.screenNameExtractor});

  /// Supplies the Screen Name for a route, overriding derivation.
  ///
  /// The documented way to integrate a router the Plugin knows nothing about: hand it the
  /// matched route template, so `/orders/:id` names the screen rather than whatever path
  /// the user happened to open. Dart cannot duck-type an external navigator the way this
  /// organisation's React Native SDK does, so this is the mechanism — a hook rather than a
  /// dependency on any particular router.
  ///
  /// Return null for a route this does not answer for and derivation handles it, so
  /// integrating one router does not mean reimplementing derivation for every other route.
  ///
  /// Runs inside a framework callback, so a throw would take the navigation with it. One
  /// that throws or returns a blank name is reported and the derived name is used.
  final String? Function(Route<dynamic> route)? screenNameExtractor;

  /// The route whose Screen Name is the current Active View.
  ///
  /// The route itself rather than its name, because two entries can share a name:
  /// `/orders/1` and `/orders/2` collapse to one Screen Name and are still two separate
  /// entries, each needing its own Active View identifier. Exactly one route is retained,
  /// replaced on every navigation.
  Route<dynamic>? _current;

  /// Every navigation, whatever produced it.
  ///
  /// The framework's own answer to "what is the user looking at now", which is why this is
  /// the only method overridden: it fires for a push, a pop, a replace and a stack being
  /// cleared, and it fires only when the topmost route actually changed. Handling
  /// [didPush], [didPop] and [didReplace] separately would mean re-deriving which route
  /// becomes visible in each case — and getting a pop wrong is not something any
  /// downstream assertion could catch.
  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    // A dialog, a bottom sheet or any other popup is an overlay over the screen the user
    // is on, not a screen of its own. Treating one as a screen would attribute everything
    // it did away from the screen still visible behind it.
    if (topRoute is! PageRoute) return;

    // The route beneath a popup becoming topmost again once it closes is a real change of
    // the topmost route and not a navigation. A Screen Span here would inflate navigation
    // counts and mint a new Active View identifier, splitting one entry's telemetry.
    if (identical(topRoute, _current)) return;

    _current = topRoute;

    // An in-page observer that lives on this route owns its Active View. Defer to it
    // — re-assert the view the user was on — rather than entering the container's own
    // name, so popping back onto a tabbed host lands on the tab and emits one Screen
    // Span, not a container span plus a tab span.
    final reassert = viewClaimFor(topRoute);
    if (reassert != null) {
      reassert();
      return;
    }

    // The shared "enter a view" primitive, so a route navigation and an in-page switch
    // produce an identical Screen Span through one path. It owns the span lifecycle —
    // the `last.screen.name`, the post-frame end and the overtaking case — leaving this
    // observer to answer only which route became visible and what to name it.
    Edot.enterView(_screenNameFor(topRoute));
  }

  String _screenNameFor(Route<dynamic> route) {
    final derived = deriveScreenName(route.settings);

    final extractor = screenNameExtractor;
    if (extractor == null) return derived;

    try {
      final supplied = extractor(route);

      // Trimmed, because trailing whitespace would make one screen two Screen Names.
      final name = supplied?.trim() ?? '';
      if (name.isNotEmpty) return name;

      // A null return is the documented way to defer to derivation. A blank one is a hook
      // that meant to answer and produced nothing — worth saying out loud rather than
      // quietly treating as a deferral.
      if (supplied != null) {
        edotLog('screenNameExtractor returned a blank name; using "$derived"');
      }

      return derived;
    } catch (error) {
      edotLog('screenNameExtractor failed; using "$derived" instead: $error');
      return derived;
    }
  }
}
