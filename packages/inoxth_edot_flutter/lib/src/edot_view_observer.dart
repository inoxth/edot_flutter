// Material, not widgets: TabController is a Material class, and accepting one is
// the whole point of the tabs constructor.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'edot.dart';

/// Records in-page view switches automatically, the way [EdotNavigatorObserver]
/// records route navigations.
///
/// Tabs, a `PageView` and an `IndexedStack` change the visible view without
/// pushing a route, so a `NavigatorObserver` never sees them. Wrap the tabbed
/// subtree in one of these and every switch - a tap, a swipe, a programmatic index
/// change - calls [Edot.enterView], emitting a `"<name> - view appearing"` Screen
/// Span and moving the Active View, with no per-switch code:
///
/// ```dart
/// EdotViewObserver.tabs(
///   controller: _tabController,
///   names: const ['Feed', 'Search', 'Profile'],
///   child: TabBarView(controller: _tabController, children: [...]),
/// )
/// ```
///
/// It hooks the mechanism the app already drives its UI from rather than owning
/// one, so it fits a `TabController`, a `PageController`, or a
/// `ValueListenable<int>` behind a `NavigationBar`. The current view is entered
/// when the widget mounts and the listener is removed when it is disposed.
///
/// Switches are de-duplicated by index: a rebuild or a notification that does not
/// change the index emits nothing, so duplicate spans are not spammed. Returning
/// to a tab after pushing a screen and popping back is handled separately; this
/// widget tracks switches within the view it lives on.
class EdotViewObserver extends StatefulWidget {
  // Positional initializing formals: the fields are private, and a private name is
  // illegal in a named parameter.
  const EdotViewObserver._(
    this._listenable,
    this._currentIndex,
    this._nameFor, {
    required this.child,
    super.key,
  });

  /// Tracks the tab a [TabController] is on - taps, swipes and `animateTo` alike.
  ///
  /// Supply the Screen Names as [names], indexed by tab position, or as [nameFor]
  /// mapping an index to a name; provide exactly one. [nameFor] suits tabs built
  /// from a dynamic list.
  factory EdotViewObserver.tabs({
    required TabController controller,
    required Widget child,
    List<String>? names,
    String Function(int index)? nameFor,
    Key? key,
  }) => EdotViewObserver._(
    controller,
    () => controller.index,
    _resolveNames(names, nameFor),
    key: key,
    child: child,
  );

  /// Tracks the page a [PageController] is on, entering a page as it becomes the
  /// dominant one during a swipe.
  ///
  /// Supply the Screen Names as [names], indexed by page, or as [nameFor]; provide
  /// exactly one.
  factory EdotViewObserver.pages({
    required PageController controller,
    required Widget child,
    List<String>? names,
    String Function(int index)? nameFor,
    Key? key,
  }) => EdotViewObserver._(
    controller,
    // `page` throws before the controller is attached to a viewport, and is a
    // double mid-swipe: the dominant page is the rounded value.
    () => controller.hasClients
        ? (controller.page?.round() ?? controller.initialPage)
        : controller.initialPage,
    _resolveNames(names, nameFor),
    key: key,
    child: child,
  );

  /// Tracks a `ValueListenable<int>` the app drives a `NavigationBar` or
  /// `IndexedStack` from, so tracking needs no controller the app does not already
  /// have.
  ///
  /// Supply the Screen Names as [names], indexed by value, or as [nameFor]; provide
  /// exactly one.
  factory EdotViewObserver.index({
    required ValueListenable<int> listenable,
    required Widget child,
    List<String>? names,
    String Function(int index)? nameFor,
    Key? key,
  }) => EdotViewObserver._(
    listenable,
    () => listenable.value,
    _resolveNames(names, nameFor),
    key: key,
    child: child,
  );

  /// The subtree this observer wraps. Rendered unchanged; the observer adds no UI.
  final Widget child;

  final Listenable _listenable;
  final int Function() _currentIndex;
  final String Function(int index) _nameFor;

  static String Function(int index) _resolveNames(
    List<String>? names,
    String Function(int index)? nameFor,
  ) {
    assert(
      (names == null) != (nameFor == null),
      'Provide exactly one of names or nameFor.',
    );
    if (nameFor != null) return nameFor;
    final list = names!;
    return (index) => list[index];
  }

  @override
  State<EdotViewObserver> createState() => _EdotViewObserverState();
}

class _EdotViewObserverState extends State<EdotViewObserver> {
  /// The index last entered, so a notification that does not change it is ignored.
  int? _lastIndex;

  @override
  void initState() {
    super.initState();
    widget._listenable.addListener(_syncView);
    _syncView();
  }

  @override
  void didUpdateWidget(EdotViewObserver oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A parent that swaps the controller: move the listener across so the old one
    // is not leaked and the new one is tracked from here.
    if (!identical(widget._listenable, oldWidget._listenable)) {
      oldWidget._listenable.removeListener(_syncView);
      widget._listenable.addListener(_syncView);
      _syncView();
    }
  }

  @override
  void dispose() {
    widget._listenable.removeListener(_syncView);
    super.dispose();
  }

  void _syncView() {
    final index = widget._currentIndex();
    if (index == _lastIndex) return;

    _lastIndex = index;
    Edot.enterView(widget._nameFor(index));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
