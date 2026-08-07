import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

/// Seam 1 — the Active View survives a push and a pop off a tabbed host.
///
/// The correctness knot: an in-page switch pushes no route, so without the
/// observer handshake, popping back onto a tabbed host makes the route observer
/// enter the container's own name and clobber the tab. `EdotViewObserver` claims
/// its route and the route observer defers to it, so a pop-back lands on the tab
/// the user was on with exactly one Screen Span.
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

  List<Object?> viewSpanNames() => calls
      .where((c) => c.method == 'spanStart')
      .map((c) => (c.arguments as Map<Object?, Object?>)['name'])
      .toList();

  Widget reentryApp(GlobalKey<NavigatorState> navigator) => MaterialApp(
    navigatorKey: navigator,
    navigatorObservers: [
      EdotNavigatorObserver(
        screenNameExtractor: (route) => switch (route.settings.name) {
          '/' => 'Home',
          '/detail' => 'Detail',
          _ => null,
        },
      ),
    ],
    routes: {
      '/': (_) => const _TabbedHome(names: _tabs),
      '/detail': (_) => const Scaffold(body: Center(child: Text('a detail'))),
    },
  );

  testWidgets('a pop back lands on the tab, with exactly one span', (
    tester,
  ) async {
    await startPlugin();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(reentryApp(navigator));

    // Land on the tabbed host, then switch to a tab that is not the default.
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(Edot.activeView?.name, 'Search');

    // Push a screen off the host, so the route observer moves the Active View away.
    unawaited(navigator.currentState!.pushNamed('/detail'));
    await tester.pumpAndSettle();
    expect(Edot.activeView?.name, 'Detail');

    calls.clear();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();

    // The tab the user was on, not the container - and exactly one span, because the
    // route observer deferred the host route to the in-page observer.
    expect(viewSpanNames(), ['Search - view appearing']);
    expect(Edot.activeView?.name, 'Search');
  });

  testWidgets('switching, opening and returning stays correct each time', (
    tester,
  ) async {
    await startPlugin();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(reentryApp(navigator));

    for (final tab in ['Search', 'Profile', 'Feed']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();

      unawaited(navigator.currentState!.pushNamed('/detail'));
      await tester.pumpAndSettle();

      calls.clear();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();

      expect(viewSpanNames(), [
        '$tab - view appearing',
      ], reason: 'returning to $tab');
      expect(Edot.activeView?.name, tab, reason: 'returning to $tab');
    }
  });
}

const _tabs = ['Feed', 'Search', 'Profile'];

/// A tabbed host route: a TabBar/TabBarView wrapped in the observer, reached at
/// `/` and pushed off of, so a pop returns to it.
class _TabbedHome extends StatefulWidget {
  const _TabbedHome({required this.names});

  final List<String> names;

  @override
  State<_TabbedHome> createState() => _TabbedHomeState();
}

class _TabbedHomeState extends State<_TabbedHome>
    with SingleTickerProviderStateMixin {
  late final TabController controller = TabController(
    length: widget.names.length,
    vsync: this,
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      bottom: TabBar(
        controller: controller,
        tabs: [for (final n in widget.names) Tab(text: n)],
      ),
    ),
    body: EdotViewObserver.tabs(
      controller: controller,
      names: widget.names,
      child: TabBarView(
        controller: controller,
        children: [
          for (final n in widget.names) Center(child: Text('body $n')),
        ],
      ),
    ),
  );
}
