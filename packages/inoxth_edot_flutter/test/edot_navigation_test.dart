import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter/src/edot_active_view.dart' show activeView;

/// Seam 1 — Screen Spans from navigation.
///
/// A Screen Span measures a transition, ending when the destination's first frame renders
/// (ADR-0004). It is deliberately not a span that stays open while the screen is visible:
/// a screen open for ten minutes would become a single trace with hundreds of children,
/// which breaks trace waterfalls, head sampling and span limits.
///
/// Driven through a real `Navigator` rather than by calling the observer's methods. Which
/// route is visible after a pop, a replace or a dialog closing is the framework's answer,
/// not the Plugin's, and a test that called `didPop` by hand would be asserting against
/// this file's guess at it.
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
        serverUrl: 'https://apm.example.com:4318',
      ),
    );
    calls.clear();
  }

  List<MethodCall> callsTo(String method) =>
      calls.where((c) => c.method == method).toList();

  Map<Object?, Object?> argumentsOf(MethodCall call) =>
      call.arguments as Map<Object?, Object?>;

  /// Names of the spans started, in order.
  List<Object?> startedSpanNames() =>
      callsTo('spanStart').map((c) => argumentsOf(c)['name']).toList();

  Map<Object?, Object?> attributesOf(MethodCall spanStart) =>
      argumentsOf(spanStart)['attributes']! as Map<Object?, Object?>;

  /// Shadow ids of the spans that have ended.
  Set<Object?> endedShadowIds() =>
      callsTo('spanEnd').map((c) => argumentsOf(c)['shadowId']).toSet();

  /// An app whose routes are named, so derivation has something to work with.
  Widget appWith(
    GlobalKey<NavigatorState> navigator, {
    String? Function(Route<dynamic>)? extractor,
  }) => MaterialApp(
    navigatorKey: navigator,
    navigatorObservers: [EdotNavigatorObserver(screenNameExtractor: extractor)],
    initialRoute: '/home',
    onGenerateRoute: (settings) => MaterialPageRoute<void>(
      settings: settings,
      builder: (_) => Text('at ${settings.name}'),
    ),
  );

  group('the Screen Span a navigation produces', () {
    testWidgets('is named for the screen being entered', (tester) async {
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();

      await tester.pumpWidget(appWith(navigator));

      // The initial route counts as a navigation: it is the first screen the user sees,
      // and the framework reports it as a change of the topmost route like any other.
      expect(startedSpanNames(), ['/home - view appearing']);
    });

    testWidgets('carries the screen it is entering', (tester) async {
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));

      final attributes = attributesOf(callsTo('spanStart').single);
      expect(attributes['screen.name'], '/home');
      expect(attributes['screen.id'], isNotNull);
      // The Active View is established before the span starts, so the span carries the
      // same identifier every later span on this screen will — which is what lets a
      // dashboard join a screen's telemetry to the transition that opened it.
      expect(attributes['screen.id'], activeView!.id);
    });

    testWidgets('names the screen it came from, once there is one', (
      tester,
    ) async {
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));

      // Fleet Alignment: this organisation's React Native SDK sets `last.screen.name` on
      // its own Screen Spans, so a dashboard answering "where did users come from" must
      // find this fleet's transitions too.
      expect(
        attributesOf(
          callsTo('spanStart').single,
        ).containsKey('last.screen.name'),
        isFalse,
        reason: 'nothing preceded the first screen',
      );

      calls.clear();
      unawaited(navigator.currentState!.pushNamed('/orders'));
      await tester.pumpAndSettle();

      expect(
        attributesOf(callsTo('spanStart').single)['last.screen.name'],
        '/home',
      );
    });

    testWidgets('ends at the destination\'s first frame', (tester) async {
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();

      await tester.pumpWidget(appWith(navigator));
      calls.clear();

      // The push, with no frame pumped after it: the framework reports the change of
      // topmost route synchronously, so the span exists before anything has rendered.
      unawaited(navigator.currentState!.pushNamed('/orders'));

      final started = callsTo('spanStart').single;
      expect(callsTo('spanEnd'), isEmpty, reason: 'no frame has rendered yet');

      // The destination's first frame. One pump is the whole measurement: the span opens
      // at the push and closes in that frame's post-frame callback, which is what makes
      // its duration time-to-first-frame rather than time-to-anything-else.
      await tester.pump();

      expect(endedShadowIds(), {argumentsOf(started)['shadowId']});
    });

    testWidgets('does not grow the trace while the screen stays open', (
      tester,
    ) async {
      // The reason ADR-0004 makes this a transition rather than a span held open: a span
      // that stayed open would parent everything the screen did, and a screen open for
      // ten minutes would be one trace with hundreds of children.
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));

      await tester.pump(const Duration(minutes: 10));

      // One transition, already over. Both halves matter: a second span per interval would
      // grow the trace with time, and a span still open after ten minutes would be
      // collecting the screen's whole lifetime.
      expect(callsTo('spanStart'), hasLength(1));
      expect(callsTo('spanEnd'), hasLength(1));
    });
  });

  group('alongside a screen set by hand', () {
    testWidgets('names the screen the user actually came from', (tester) async {
      // A tab switch sets the Active View with no route changing (ADR-0004). Reading the
      // last route this observer happened to see would name the screen before the tab —
      // one the user left two changes ago — and the attribute exists to answer "where did
      // the user come from".
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));

      Edot.setActiveView('Settings');
      calls.clear();

      unawaited(navigator.currentState!.pushNamed('/orders'));
      await tester.pumpAndSettle();

      expect(
        attributesOf(callsTo('spanStart').single)['last.screen.name'],
        'Settings',
      );
    });

    testWidgets('has nothing to name after the screen was cleared', (
      tester,
    ) async {
      // Nothing rather than the last route seen: the app said the user is on no screen, and
      // naming one anyway would report a transition from a screen they had already left.
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));

      Edot.clearActiveView();
      calls.clear();

      unawaited(navigator.currentState!.pushNamed('/orders'));
      await tester.pumpAndSettle();

      expect(
        attributesOf(
          callsTo('spanStart').single,
        ).containsKey('last.screen.name'),
        isFalse,
      );
    });
  });

  group('every kind of navigation', () {
    testWidgets('a push is tracked', (tester) async {
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));

      unawaited(navigator.currentState!.pushNamed('/orders'));
      await tester.pumpAndSettle();

      expect(startedSpanNames(), [
        '/home - view appearing',
        '/orders - view appearing',
      ]);
      expect(activeView!.name, '/orders');
    });

    testWidgets('a pop is tracked, naming the screen returned to', (
      tester,
    ) async {
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));

      unawaited(navigator.currentState!.pushNamed('/orders'));
      await tester.pumpAndSettle();
      calls.clear();

      navigator.currentState!.pop();
      await tester.pumpAndSettle();

      expect(startedSpanNames(), ['/home - view appearing']);
      expect(
        attributesOf(callsTo('spanStart').single)['last.screen.name'],
        '/orders',
      );
      expect(activeView!.name, '/home');
    });

    testWidgets('a replace is tracked', (tester) async {
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));
      calls.clear();

      unawaited(navigator.currentState!.pushReplacementNamed('/orders'));
      await tester.pumpAndSettle();

      expect(startedSpanNames(), ['/orders - view appearing']);
      expect(activeView!.name, '/orders');
    });

    testWidgets('clearing the stack lands on the destination, once', (
      tester,
    ) async {
      // `pushAndRemoveUntil` removes several routes and pushes one. Only the screen the
      // user ends up on is a screen they entered; the ones removed underneath were never
      // shown.
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));

      unawaited(navigator.currentState!.pushNamed('/orders'));
      await tester.pumpAndSettle();
      calls.clear();

      unawaited(
        navigator.currentState!.pushNamedAndRemoveUntil('/login', (_) => false),
      );
      await tester.pumpAndSettle();

      expect(startedSpanNames(), ['/login - view appearing']);
      expect(activeView!.name, '/login');
    });
  });

  group('what is not a screen', () {
    testWidgets('a dialog does not become one', (tester) async {
      // A dialog is an overlay over the screen the user is on, not a screen of its own.
      // Treating it as one would change the Active View — so every request the dialog
      // made would be attributed away from the screen the user is looking at.
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));
      calls.clear();

      unawaited(
        showDialog<void>(
          context: navigator.currentContext!,
          builder: (_) => const Text('a dialog'),
        ),
      );
      await tester.pumpAndSettle();

      expect(calls, isEmpty);
      expect(activeView!.name, '/home');
    });

    testWidgets('closing a dialog does not re-enter the screen', (
      tester,
    ) async {
      // The framework reports the route beneath it becoming topmost again, a real change of
      // the topmost route — but not a navigation. A new Screen Span here would inflate
      // navigation counts and mint a new Active View identifier, splitting one entry's
      // telemetry in two.
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));

      final entryId = activeView!.id;

      unawaited(
        showDialog<void>(
          context: navigator.currentContext!,
          builder: (_) => const Text('a dialog'),
        ),
      );
      await tester.pumpAndSettle();
      calls.clear();

      navigator.currentState!.pop();
      await tester.pumpAndSettle();

      expect(calls, isEmpty);
      expect(activeView!.id, entryId);
    });
  });

  group('the same screen, entered twice', () {
    testWidgets('is a fresh entry with its own identifier', (tester) async {
      // `/orders/1` and `/orders/2` collapse to one Screen Name, and they are still two
      // separate entries. De-duplicating on the name would attribute the second entry's
      // telemetry to the first.
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));

      unawaited(navigator.currentState!.pushNamed('/orders/1'));
      await tester.pumpAndSettle();
      final firstEntry = activeView!.id;

      unawaited(navigator.currentState!.pushNamed('/orders/2'));
      await tester.pumpAndSettle();

      expect(activeView!.name, '/orders/{id}');
      expect(activeView!.id, isNot(firstEntry));
      expect(startedSpanNames(), [
        '/home - view appearing',
        '/orders/{id} - view appearing',
        '/orders/{id} - view appearing',
      ]);
    });

    testWidgets('does not name itself as the screen it came from', (
      tester,
    ) async {
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));

      unawaited(navigator.currentState!.pushNamed('/orders/1'));
      await tester.pumpAndSettle();
      calls.clear();

      unawaited(navigator.currentState!.pushNamed('/orders/2'));
      await tester.pumpAndSettle();

      // `last.screen.name` answers "where did the user come from". Naming the screen they
      // are already on answers nothing, which is why the React Native SDK omits it too.
      expect(
        attributesOf(
          callsTo('spanStart').single,
        ).containsKey('last.screen.name'),
        isFalse,
      );
    });
  });

  group('a navigation faster than a frame', () {
    testWidgets('ends the transition it interrupted, and only that one', (
      tester,
    ) async {
      // Two pushes in one turn, so the first Screen Span has not reached its post-frame
      // callback. Without ending it, the transition would stay open for the rest of the
      // app's life and its duration would be meaningless.
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));
      calls.clear();

      unawaited(navigator.currentState!.pushNamed('/orders'));
      unawaited(navigator.currentState!.pushNamed('/orders/1'));
      await tester.pumpAndSettle();

      final started = callsTo('spanStart');
      expect(started, hasLength(2));
      expect(
        endedShadowIds(),
        started.map((c) => argumentsOf(c)['shadowId']).toSet(),
        reason: 'both transitions have to be over',
      );
    });
  });

  group('a route the app did not name', () {
    testWidgets('still yields a usable Screen Name', (tester) async {
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));
      calls.clear();

      // The `Navigator.push` form, which carries no route settings at all — the common
      // case in an app that never declared a routing table.
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const Text('unnamed screen')),
        ),
      );
      await tester.pumpAndSettle();

      expect(startedSpanNames(), ['unnamed - view appearing']);
      expect(activeView!.name, 'unnamed');
    });
  });

  group('a caller-supplied extractor', () {
    testWidgets('overrides derivation', (tester) async {
      // The documented way to integrate a router the Plugin knows nothing about: hand it
      // the matched route template. Dart cannot duck-type an external navigator the way
      // the React Native SDK does, so an extractor is the mechanism rather than a
      // dependency on any particular router.
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        appWith(
          navigator,
          extractor: (route) => switch (route.settings.name) {
            '/orders/1' => 'OrderDetail',
            _ => null,
          },
        ),
      );
      calls.clear();

      unawaited(navigator.currentState!.pushNamed('/orders/1'));
      await tester.pumpAndSettle();

      expect(startedSpanNames(), ['OrderDetail - view appearing']);
      expect(activeView!.name, 'OrderDetail');
    });

    testWidgets('defers to derivation for a route it does not answer for', (
      tester,
    ) async {
      // So integrating one router does not mean reimplementing derivation for every
      // route the app has.
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator, extractor: (route) => null));

      expect(activeView!.name, '/home');
    });

    testWidgets('is not trusted to return something usable', (tester) async {
      // A blank name would drop screen attribution for the whole screen, because
      // enrichment attaches the name and the identifier together or not at all.
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator, extractor: (route) => '   '));

      expect(activeView!.name, '/home');
    });

    testWidgets('says so when it answers with a blank name', (tester) async {
      // Distinct from returning null, which is the documented way to defer. A hook that
      // meant to answer and produced nothing is a bug in the hook, and silently deriving
      // instead would leave its author with no way to notice.
      final printed = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');

      await Edot.start(
        EdotConfig(
          serviceName: 'example-app',
          serviceVersion: '1.2.3',
          deploymentEnvironment: 'test',
          serverUrl: 'https://apm.example.com:4318',
          debug: true,
        ),
      );

      printed.clear();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator, extractor: (route) => ''));

      // Restored inside the body, not in a tear-down: a widget test asserts that the
      // foundation's debug variables are back to their defaults before the body returns.
      debugPrint = previous;

      expect(printed, contains(contains('blank name')));
    });

    testWidgets('does not break navigation when it throws', (tester) async {
      // It is app code running inside a framework callback. A throw here would take the
      // navigation down with it, which is a far worse outcome than a missing name.
      await startPlugin();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        appWith(navigator, extractor: (route) => throw StateError('bad hook')),
      );

      expect(find.text('at /home'), findsOneWidget);
      expect(activeView!.name, '/home');
    });
  });

  group('before start', () {
    testWidgets('navigation works, and is held until started', (tester) async {
      // The observer is in the widget tree before `Edot.start` has necessarily completed.
      // It must not throw: telemetry is not worth breaking an app's navigation over.
      final navigator = GlobalKey<NavigatorState>();

      await tester.pumpWidget(appWith(navigator));
      unawaited(navigator.currentState!.pushNamed('/orders'));
      await tester.pumpAndSettle();

      expect(find.text('at /orders'), findsOneWidget);
      expect(calls, isEmpty, reason: 'the Agent cannot receive these yet');

      // The Active View is Dart-side state, not an emission, so it was always set here —
      // which is what lets telemetry produced during startup name the screen it came from.
      expect(activeView?.name, '/orders');

      await Edot.start(
        EdotConfig(
          serviceName: 'example-app',
          serviceVersion: '1.0.0',
          deploymentEnvironment: 'test',
          serverUrl: 'http://localhost:4318',
        ),
      );

      // The first screen the user saw is no longer missing from Kibana. It used to be
      // reported to the debug log and dropped, which made a screen nobody opened and the
      // screen everybody opens first look identical.
      final started = calls.where((c) => c.method == 'spanStart');
      expect(
        started.map((c) => (c.arguments as Map<Object?, Object?>)['name']),
        containsAll(<String>[
          '/home - view appearing',
          '/orders - view appearing',
        ]),
      );
    });
  });
}
