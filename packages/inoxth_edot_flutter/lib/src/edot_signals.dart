/// Severity of a log record.
///
/// The names are the wire values, matching the React Native SDK's `emitLog`
/// signature exactly (Fleet Alignment). Do not rename these to OpenTelemetry's
/// `WARN`/`ERROR` spellings without changing the React Native SDK in lockstep.
enum EdotSeverity {
  /// Finest-grained tracing detail.
  trace,

  /// Diagnostic detail useful while debugging.
  debug,

  /// Ordinary informational record.
  info,

  /// A concern that did not stop the operation.
  warn,

  /// A failure in the operation.
  error,

  /// A failure severe enough to threaten the app.
  fatal,
}

/// Kind of instrument a recorded metric goes to.
///
/// One record call rather than an instrument registry, which is what makes
/// metrics affordable in the first release. The names are the wire values, again
/// matching the React Native SDK's `recordMetric` signature.
enum EdotMetricKind {
  /// Monotonic sum, for things that only go up.
  counter,

  /// Distribution, for measuring spread rather than a total.
  histogram,

  /// Non-monotonic sum, for values that go up and down.
  upDownCounter,
}

/// Encodes log attributes so the value's type survives the channel.
///
/// A `Map<String, Object>` cannot carry its types across to iOS on its own:
/// Flutter delivers every number as `NSNumber`, which casts to `Int` and `Double`
/// alike, so an integer attribute would arrive indistinguishable from a float.
/// Span attributes solve this with one channel method per type; a log record's
/// attributes all arrive at once, so each one carries its own type tag instead.
///
/// Throws [ArgumentError] for a type the wire cannot carry, rather than dropping
/// it — a silently missing attribute is worse than a loud failure, because the
/// caller believes it was recorded.
List<Map<String, Object?>> encodeLogAttributes(Map<String, Object> attributes) {
  return [
    for (final entry in attributes.entries)
      <String, Object?>{
        'key': entry.key,
        'type': switch (entry.value) {
          String() => 'string',
          int() => 'int',
          double() => 'double',
          bool() => 'bool',
          _ => throw ArgumentError.value(
            entry.value,
            'attributes["${entry.key}"]',
            'log attributes must be String, int, double or bool',
          ),
        },
        'value': entry.value,
      },
  ];
}
