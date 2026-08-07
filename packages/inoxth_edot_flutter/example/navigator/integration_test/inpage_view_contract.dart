/// Shared contract between the two halves of the in-page view tracking test.
///
/// Deliberately free of Flutter imports: the host half runs under plain
/// `dart run`, where `dart:ui` does not exist.
///
/// **What this suite proves that Seam 1 cannot.** Seam 1 asserts what the Plugin hands to
/// the channel for an in-page switch. Only an export shows that the view-appearing Screen
/// Span an `EdotViewObserver` emits reaches a collector under the name a dashboard looks
/// for, carrying the Fleet Alignment attribute `last.screen.name`, and that the identifier
/// tying a tab's telemetry to the switch that opened it survives the channel and the Agent
/// unchanged. An in-page switch pushes no route, so an export is the only proof it is
/// tracked at all. The view span is Dart-emitted like a navigation's, so this suite runs on
/// both platforms rather than naming one it cannot prove.
library;

/// The two tabs the device half switches between: the initial one, then the next.
const String firstView = 'Feed';
const String secondView = 'Search';

/// Screen Span names, per this organisation's React Native SDK.
///
/// Restated here rather than built by importing the Plugin's own formatting: a contract
/// that read the name from the code it checks could only prove the code equals itself, and
/// a rename would sail through.
String screenSpanName(String viewName) => '$viewName - view appearing';

/// Emitted while the second tab is the Active View, so the host half can check that a span
/// the app started carries the same entry identifier as the switch that opened the tab.
const String spanOnTheSecondView = 'work-on-the-second-tab';

/// Wire names, per ADR-0003, plus the Fleet Alignment attribute this suite exists for.
const String screenNameAttribute = 'screen.name';
const String screenIdAttribute = 'screen.id';
const String lastScreenNameAttribute = 'last.screen.name';
