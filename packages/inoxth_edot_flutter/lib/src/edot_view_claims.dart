import 'package:flutter/widgets.dart';

/// Routes an [EdotViewObserver] owns the Active View for, each mapped to how to
/// re-assert the view the user was on.
///
/// The handshake between the two observers. An in-page switch pushes no route, so
/// after pushing a screen from a tabbed host and popping back, the route observer
/// would otherwise enter the container's own name and clobber the tab. An
/// [EdotViewObserver] claims the route it lives on; when that route returns to the
/// front, [EdotNavigatorObserver] finds the claim and defers to it - calling the
/// re-assert rather than entering the container - so the return lands on the tab
/// and emits exactly one Screen Span, not a container span plus a tab span.
///
/// Global for the same reason the Active View is (ADR-0004): the Navigator is a
/// process-wide notion of what is on top, and a claim is meaningful only against it.
final Map<Route<dynamic>, void Function()> _claims =
    <Route<dynamic>, void Function()>{};

/// Records that an in-page observer owns [route], with [reassert] re-entering the
/// view it is on. Replaces any previous claim on the same route.
void claimViewRoute(Route<dynamic> route, void Function() reassert) =>
    _claims[route] = reassert;

/// Drops the claim on [route], when the observer that made it is disposed.
void releaseViewRoute(Route<dynamic> route) => _claims.remove(route);

/// How to re-assert the view for [route], or null when no observer claimed it.
void Function()? viewClaimFor(Route<dynamic> route) => _claims[route];

/// Drops every claim, so a reset leaves no route owned by a disposed observer.
void clearViewClaims() => _claims.clear();
