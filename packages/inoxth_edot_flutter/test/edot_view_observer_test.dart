import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

/// Seam 1 — automatic in-page view tracking.
///
/// `EdotViewObserver` turns a tab/page/index switch into the same Screen Span a
/// navigation produces, with no per-switch code. Driven through real widgets - a
/// tapped `TabBar`, a dragged `PageView`, a changed `ValueNotifier` - because which
/// view is showing after a gesture is the framework's answer, not the Plugin's.
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

  group('a TabController source', () {
    testWidgets('enters the initial tab on mount', (tester) async {
      await startPlugin();

      await tester.pumpWidget(const _TabHost(names: _tabs));

      expect(viewSpanNames(), ['Feed - view appearing']);
      expect(Edot.activeView?.name, 'Feed');
    });

    testWidgets('tracks a tab tap', (tester) async {
      await startPlugin();
      await tester.pumpWidget(const _TabHost(names: _tabs));
      calls.clear();

      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();

      expect(viewSpanNames(), ['Search - view appearing']);
      expect(Edot.activeView?.name, 'Search');
    });

    testWidgets('tracks a programmatic index change', (tester) async {
      await startPlugin();
      await tester.pumpWidget(const _TabHost(names: _tabs));
      final controller = tester
          .state<_TabHostState>(find.byType(_TabHost))
          .controller;
      calls.clear();

      controller.animateTo(2);
      await tester.pumpAndSettle();

      expect(viewSpanNames(), ['Profile - view appearing']);
      expect(Edot.activeView?.name, 'Profile');
    });

    testWidgets('emits nothing when the tab does not change', (tester) async {
      await startPlugin();
      await tester.pumpWidget(const _TabHost(names: _tabs));
      calls.clear();

      // Tapping the tab already selected is a no-op switch: the index does not move,
      // so the observer must not spam a duplicate span.
      await tester.tap(find.text('Feed'));
      await tester.pumpAndSettle();

      expect(viewSpanNames(), isEmpty);
    });
  });

  group('a PageController source', () {
    testWidgets('enters the initial page on mount', (tester) async {
      await startPlugin();

      await tester.pumpWidget(const _PageHost(names: _tabs));

      expect(viewSpanNames(), ['Feed - view appearing']);
      expect(Edot.activeView?.name, 'Feed');
    });

    testWidgets('tracks a swipe to the next page', (tester) async {
      await startPlugin();
      await tester.pumpWidget(const _PageHost(names: _tabs));
      calls.clear();

      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      await tester.pumpAndSettle();

      expect(viewSpanNames(), ['Search - view appearing']);
      expect(Edot.activeView?.name, 'Search');
    });
  });

  group('a ValueListenable source', () {
    testWidgets('enters the initial value on mount', (tester) async {
      await startPlugin();
      final index = ValueNotifier(0);
      addTearDown(index.dispose);

      await tester.pumpWidget(_indexApp(index, _tabs));

      expect(viewSpanNames(), ['Feed - view appearing']);
      expect(Edot.activeView?.name, 'Feed');
    });

    testWidgets('tracks a value change', (tester) async {
      await startPlugin();
      final index = ValueNotifier(0);
      addTearDown(index.dispose);
      await tester.pumpWidget(_indexApp(index, _tabs));
      calls.clear();

      index.value = 1;
      await tester.pumpAndSettle();

      expect(viewSpanNames(), ['Search - view appearing']);
      expect(Edot.activeView?.name, 'Search');
    });

    testWidgets('stops tracking once disposed', (tester) async {
      // The listener must come off on dispose: a switch after the observer is gone
      // would be a leak driving a dead widget's telemetry.
      await startPlugin();
      final index = ValueNotifier(0);
      addTearDown(index.dispose);
      await tester.pumpWidget(_indexApp(index, _tabs));

      await tester.pumpWidget(const SizedBox());
      calls.clear();

      index.value = 1;
      await tester.pumpAndSettle();

      expect(viewSpanNames(), isEmpty);
    });
  });

  group('naming', () {
    testWidgets('uses an index-to-name mapper when given one', (tester) async {
      await startPlugin();
      final index = ValueNotifier(0);
      addTearDown(index.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: EdotViewObserver.index(
            listenable: index,
            nameFor: (i) => 'section-$i',
            child: const SizedBox(),
          ),
        ),
      );

      expect(Edot.activeView?.name, 'section-0');
    });
  });
}

const _tabs = ['Feed', 'Search', 'Profile'];

Widget _indexApp(ValueListenable<int> index, List<String> names) => MaterialApp(
  home: EdotViewObserver.index(
    listenable: index,
    names: names,
    child: ValueListenableBuilder<int>(
      valueListenable: index,
      builder: (_, value, _) => IndexedStack(
        index: value,
        children: [for (final n in names) Text(n)],
      ),
    ),
  ),
);

/// A tabbed app whose body is wrapped in the observer, so a tap or a swipe on the
/// real `TabBar`/`TabBarView` drives it exactly as an integrator's app would.
class _TabHost extends StatefulWidget {
  const _TabHost({required this.names});

  final List<String> names;

  @override
  State<_TabHost> createState() => _TabHostState();
}

class _TabHostState extends State<_TabHost>
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
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
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
    ),
  );
}

/// A `PageView` app wrapped in the observer.
class _PageHost extends StatefulWidget {
  const _PageHost({required this.names});

  final List<String> names;

  @override
  State<_PageHost> createState() => _PageHostState();
}

class _PageHostState extends State<_PageHost> {
  final PageController controller = PageController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: EdotViewObserver.pages(
      controller: controller,
      names: widget.names,
      child: PageView(
        controller: controller,
        children: [
          for (final n in widget.names) Center(child: Text('body $n')),
        ],
      ),
    ),
  );
}
