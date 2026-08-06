/// Shared contract between the two halves of the navigation test.
///
/// Deliberately free of Flutter imports: the host half runs under plain
/// `dart run`, where `dart:ui` does not exist.
///
/// **What this suite proves that Seam 1 cannot.** Seam 1 asserts what the Plugin hands to
/// the channel. Only an export shows that a Screen Span reaches a collector under the name
/// a dashboard looks for, carrying the Fleet Alignment attribute `last.screen.name` — and
/// that the identifier tying a screen's telemetry to the transition that opened it is the
/// same on both sides after crossing the channel and the Agent.
library;

/// The routes the device half enters, in order: the initial screen, an order, then back.
///
/// `/orders/7` is requested and `/orders/{id}` is what must arrive. Collapsing is the whole
/// reason a Screen Name is safe to attach to every span, so an export that still named the
/// order would be the failure worth catching.
const String homeRoute = '/home';
const String orderRoute = '/orders/7';
const String orderScreenName = '/orders/{id}';

/// Screen Span names, per this organisation's React Native SDK.
///
/// Restated here rather than built by importing the Plugin's own formatting: a contract
/// that read the name from the code it checks could only prove the code equals itself, and
/// a rename would sail through.
String screenSpanName(String screenName) => '$screenName - view appearing';

/// Emitted while the order screen is the Active View, so the host half can check that a
/// span the app started carries the same entry identifier as the transition that opened it.
const String spanOnTheOrderScreen = 'navigation-work-on-the-order-screen';

/// Wire names, per ADR-0003, plus the Fleet Alignment attribute this suite exists for.
const String screenNameAttribute = 'screen.name';
const String screenIdAttribute = 'screen.id';
const String lastScreenNameAttribute = 'last.screen.name';
