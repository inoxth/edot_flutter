import 'package:flutter/foundation.dart';

import 'edot_config.dart';

/// The Dart-side rules the traced transports need.
///
/// Carried separately from [EdotConfig] rather than by handing the whole thing
/// around: these are the only fields instrumentation needs, and the configuration
/// also holds credentials that nothing here has any business reaching.
@immutable
class EdotTracingRules {
  /// Creates the rule set directly. See [EdotTracingRules.fromConfig] for the
  /// usual path from an [EdotConfig].
  const EdotTracingRules({
    required this.collectorHost,
    this.urlSanitizer,
    this.excludedUrls = const [],
    this.tracePropagationTargets,
  });

  /// Copies the tracing-relevant fields out of [config], leaving its credentials
  /// behind.
  EdotTracingRules.fromConfig(EdotConfig config)
    : collectorHost = config.collectorHost,
      urlSanitizer = config.urlSanitizer,
      excludedUrls = config.excludedUrls,
      tracePropagationTargets = config.tracePropagationTargets;

  /// Host whose requests are never traced. See [EdotConfig.collectorHost].
  final String collectorHost;

  /// Rewrites a request URL before it is recorded. See [EdotConfig.urlSanitizer].
  final String Function(String url)? urlSanitizer;

  /// Requests matching any of these are not traced. See [EdotConfig.excludedUrls].
  final List<Pattern> excludedUrls;

  /// Null means every traced host, which is not the same as an empty list. See
  /// [EdotConfig.tracePropagationTargets].
  final List<Pattern>? tracePropagationTargets;
}

/// The rules in force, or null before the Plugin has started.
///
/// Ambient because a wrapped client is built by the app, often before `Edot.start`
/// runs, so it cannot be handed these at construction.
EdotTracingRules? _rules;

/// The rules in force, or null before the Plugin has started.
EdotTracingRules? get tracingRules => _rules;

/// Installs [rules] as the rules in force, from `Edot.start`.
void setTracingRules(EdotTracingRules rules) => _rules = rules;

/// Clears the rules in force, so instrumentation traces nothing until the next
/// `Edot.start`.
void clearTracingRules() => _rules = null;
