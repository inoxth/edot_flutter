import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Seam 1 - the lockstep invariant ADR-0017 depends on.
///
/// The two packages publish from one tag under one version, so a release that
/// bumps only one of them, or bumps both but leaves Dio's constraint pointing at
/// the previous core, ships a Dio that resolves against the wrong plugin. The
/// release runbook is four hand edits (CONTRIBUTING, Releasing) and the third one
/// is the easy one to miss, so it is asserted here rather than remembered.
///
/// Reads the pubspecs as text on purpose. Parsing two lines does not justify a
/// YAML dependency in a package consumers resolve.
void main() {
  final dioPubspec = File('pubspec.yaml').readAsStringSync();
  final corePubspec = File(
    '../inoxth_edot_flutter/pubspec.yaml',
  ).readAsStringSync();

  String versionOf(String pubspec) {
    final match = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec declares no version');
    return match!.group(1)!;
  }

  test('both packages carry the same version', () {
    expect(
      versionOf(dioPubspec),
      versionOf(corePubspec),
      reason:
          'ADR-0017: the packages version in lockstep. Set both to the same '
          'value, and tag it v<version>.',
    );
  });

  test("the Dio package's constraint tracks the core version", () {
    final constraint = RegExp(
      r'^\s+inoxth_edot_flutter:\s*(\S+)',
      multiLine: true,
    ).firstMatch(dioPubspec);
    expect(constraint, isNotNull, reason: 'no dependency on the core package');

    expect(
      constraint!.group(1),
      '^${versionOf(corePubspec)}',
      reason:
          'ADR-0017: the Dio package must depend on the core version released '
          'alongside it. A stale constraint publishes a Dio that resolves '
          'against the previous plugin.',
    );
  });
}
