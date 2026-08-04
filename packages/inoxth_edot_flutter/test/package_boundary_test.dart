import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ADR-0010's boundary, as an assertion rather than a warning in a document.
///
/// Dart has no optional dependencies, so a Dio dependency here would impose Dio's
/// version constraint on every consumer of the core package — a Dio major release
/// would then block apps that never use Dio. Adding it is a one-line change that
/// looks harmless in review, which is why it is worth a test.
void main() {
  test('the core package does not depend on Dio', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    // Only what is imposed on consumers. A dev dependency is the package's own
    // business and reaches nobody else.
    final imposed = pubspec.split('dev_dependencies:').first;

    // The dependency key, not the word: a comment mentioning Dio is not a
    // dependency on it, and this test must not be the reason nobody may write one.
    expect(RegExp(r'^\s+dio\s*:', multiLine: true).hasMatch(imposed), isFalse);
  });
}
