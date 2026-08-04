import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

/// Seam 1 — the parent identifier accompanying each span-start call.
///
/// Parenting is ambient but *scoped*: a span becomes a parent only for work run
/// inside [EdotTracer.runWithParent], never merely by being the most recently
/// started span. "Most recent wins" is what produces trace trees that look
/// plausible and are wrong the moment two async flows overlap, which is a worse
/// outcome than no nesting at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(edotChannelName), (
          call,
        ) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(edotChannelName), null);
    Edot.resetForTesting();
  });

  Future<void> startPlugin() async {
    await Edot.start(
      EdotConfig(
        serviceName: 'example-app',
        serviceVersion: '1.2.3',
        deploymentEnvironment: 'test',
        serverUrl: 'http://localhost:4318',
      ),
    );
    calls.clear();
  }

  /// The parent shadow id sent with the `spanStart` call for [name].
  Object? parentOf(String name) {
    final start = calls.singleWhere((call) {
      if (call.method != 'spanStart') return false;
      return (call.arguments as Map<Object?, Object?>)['name'] == name;
    });
    return (start.arguments as Map<Object?, Object?>)['parentShadowId'];
  }

  group('ambient parent', () {
    test(
      'a span started inside a scope carries that scope as its parent',
      () async {
        await startPlugin();
        final parent = Edot.tracer.startSpan('parent');

        Edot.tracer.runWithParent(parent, () {
          Edot.tracer.startSpan('child').end();
        });

        expect(parentOf('child'), parent.shadowId);
      },
    );

    test('nesting survives await boundaries', () async {
      await startPlugin();
      final parent = Edot.tracer.startSpan('parent');

      await Edot.tracer.runWithParent(parent, () async {
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(const Duration(milliseconds: 1));
        Edot.tracer.startSpan('child-after-awaits').end();
      });

      expect(parentOf('child-after-awaits'), parent.shadowId);
    });

    test('scopes nest, and the innermost wins', () async {
      await startPlugin();
      final outer = Edot.tracer.startSpan('outer');

      Edot.tracer.runWithParent(outer, () {
        final inner = Edot.tracer.startSpan('inner');
        expect(parentOf('inner'), outer.shadowId);

        Edot.tracer.runWithParent(inner, () {
          Edot.tracer.startSpan('leaf').end();
        });

        expect(parentOf('leaf'), inner.shadowId);
      });
    });

    test('the scope ends with the body, not with the span', () async {
      await startPlugin();
      final parent = Edot.tracer.startSpan('parent');

      Edot.tracer.runWithParent(parent, () {});
      Edot.tracer.startSpan('after-scope').end();

      expect(parentOf('after-scope'), isNull);
    });

    test(
      'two interleaved flows keep their own parent, with no cross-contamination',
      () async {
        // The failure mode this whole design exists to prevent. The delays are
        // ordered so the second flow creates its child first, which is exactly
        // when a "most recently started span wins" implementation gets it wrong.
        await startPlugin();
        final first = Edot.tracer.startSpan('flow-one');
        final second = Edot.tracer.startSpan('flow-two');

        Future<void> flow(EdotSpan parent, String child, Duration delay) =>
            Edot.tracer.runWithParent(parent, () async {
              await Future<void>.delayed(delay);
              Edot.tracer.startSpan(child).end();
            });

        await Future.wait([
          flow(first, 'child-one', const Duration(milliseconds: 20)),
          flow(second, 'child-two', const Duration(milliseconds: 5)),
        ]);

        expect(parentOf('child-one'), first.shadowId);
        expect(parentOf('child-two'), second.shadowId);

        // And the interleaving really happened, so the assertions above mean
        // something: the second flow's child was started first.
        final childOrder = calls
            .where((c) => c.method == 'spanStart')
            .map(
              (c) => (c.arguments as Map<Object?, Object?>)['name']! as String,
            )
            .where((name) => name.startsWith('child-'))
            .toList();
        expect(childOrder, ['child-two', 'child-one']);
      },
    );
  });

  group('explicit parent', () {
    test('overrides the ambient one', () async {
      await startPlugin();
      final ambient = Edot.tracer.startSpan('ambient');
      final explicit = Edot.tracer.startSpan('explicit');

      Edot.tracer.runWithParent(ambient, () {
        Edot.tracer.startSpan('child', parent: explicit).end();
      });

      expect(parentOf('child'), explicit.shadowId);
    });

    test('works with no ambient scope at all', () async {
      await startPlugin();
      final parent = Edot.tracer.startSpan('parent');

      Edot.tracer.startSpan('child', parent: parent).end();

      expect(parentOf('child'), parent.shadowId);
    });
  });

  group('roots', () {
    test('no ambient and no explicit parent sends a null parent', () async {
      await startPlugin();

      Edot.tracer.startSpan('lonely').end();

      expect(parentOf('lonely'), isNull);
    });

    test('an ambient scope does not leak across independent zones', () async {
      // runZoned without a parent scope must not inherit one from the caller's
      // zone by accident.
      await startPlugin();
      final parent = Edot.tracer.startSpan('parent');

      Edot.tracer.runWithParent(parent, () {
        runZoned(() {
          // Still inside the parent's zone, so this one *is* a child.
          Edot.tracer.startSpan('nested-zone-child').end();
        });
      });

      expect(parentOf('nested-zone-child'), parent.shadowId);
    });
  });
}
