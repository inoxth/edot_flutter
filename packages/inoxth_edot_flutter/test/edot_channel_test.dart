import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

/// Seam 1 — the platform channel. Every later ticket asserts Plugin behaviour by
/// capturing calls on this channel, so its name is part of the contract with both
/// native implementations and must not drift silently.
void main() {
  test('channel name matches the name both native implementations register', () {
    // Kotlin and Swift register this literal. Changing it here without changing
    // both natives would break every call at runtime, not at compile time.
    expect(edotChannelName, 'inoxth_edot_flutter');
  });
}
