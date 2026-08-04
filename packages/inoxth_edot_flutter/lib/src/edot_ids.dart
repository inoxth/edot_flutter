import 'dart:math';

/// Random per-process prefix, so identifiers from two runs cannot collide in the
/// Agent's registry if one outlives a hot restart.
final String _prefix = () {
  final random = Random.secure();
  return List.generate(
    4,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}();

int _counter = 0;

/// Mints an identifier unique within this run.
///
/// One generator for Shadow Spans and for the Active View, because a navigation's
/// Screen Span identifier doubles as the Active View's — they have to come from
/// the same space to be the same value.
String newLocalId() => '$_prefix-${_counter++}';
