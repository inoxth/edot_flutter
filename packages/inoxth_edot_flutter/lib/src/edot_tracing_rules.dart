import 'package:flutter/foundation.dart';

import 'edot_config.dart';

/// The Dart-side rules the traced transports need.
///
/// Carried separately from [EdotConfig] rather than by handing the whole thing
/// around: these are the only fields instrumentation needs, and the configuration
/// also holds credentials that nothing here has any business reaching.
@immutable
class EdotTracingRules {
  const EdotTracingRules({
    required this.collectorHost,
    this.urlSanitizer,
    this.excludedUrls = const [],
    this.tracePropagationTargets,
  });

  EdotTracingRules.fromConfig(EdotConfig config)
    : collectorHost = config.collectorHost,
      urlSanitizer = config.urlSanitizer,
      excludedUrls = config.excludedUrls,
      tracePropagationTargets = config.tracePropagationTargets;

  final String collectorHost;
  final String Function(String url)? urlSanitizer;
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

EdotTracingRules? get tracingRules => _rules;

void setTracingRules(EdotTracingRules rules) => _rules = rules;

void clearTracingRules() => _rules = null;
