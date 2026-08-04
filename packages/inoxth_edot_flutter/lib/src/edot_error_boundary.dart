import 'package:flutter/widgets.dart';

/// Shows a fallback in place of the part of its subtree that failed.
///
/// Wrap a section of a screen that is allowed to fail on its own:
///
/// ```dart
/// EdotErrorBoundary(
///   fallback: (error) => const Text('This section is unavailable'),
///   child: RecommendationsCarousel(),
/// )
/// ```
///
/// Without one, a build failure inside the subtree renders the framework's error
/// display — a red box in debug, a grey one in release — wherever the failure happened.
/// With one, the same spot renders [fallback] instead.
///
/// The failure is *reported* whether or not a boundary encloses it: the Plugin's
/// framework error handler sees every one of them, and reports it once. A boundary
/// changes what the user sees, not what Kibana sees. Reporting it a second time here
/// would double-count the same failure.
///
/// This covers failures the framework routes through its own error reporting — build,
/// layout and paint. An asynchronous failure in the subtree's own code never passes
/// through a build, so it is captured as an uncaught async error and no fallback
/// appears; there is nothing rebuilding for one to replace.
class EdotErrorBoundary extends StatefulWidget {
  const EdotErrorBoundary({
    required this.child,
    required this.fallback,
    super.key,
  });

  final Widget child;

  /// Built in place of whatever failed. Receives the error, so a debug build can show
  /// it and a release build can decline to.
  final Widget Function(Object error) fallback;

  @override
  State<EdotErrorBoundary> createState() => _EdotErrorBoundaryState();
}

/// Holds the [ErrorWidget.builder] hook for as long as a boundary is mounted.
///
/// Stateful only for that. The hook is global, and taking it over is what makes a
/// boundary able to intercept a failure at all — so it is claimed here rather than at
/// `Edot.start`, and only while there is a boundary that needs it. An app with no
/// boundary then never has its error display touched, and neither does a widget test
/// that merely starts the Plugin: `flutter_test` fails any test that leaves
/// [ErrorWidget.builder] changed, which starting the Plugin would otherwise do to every
/// test an integrator writes.
class _EdotErrorBoundaryState extends State<EdotErrorBoundary> {
  @override
  void initState() {
    super.initState();

    // Before the subtree is built, which is what makes the hook available in time for
    // the first failure.
    _acquireErrorWidgetBuilder();
  }

  @override
  void dispose() {
    _releaseErrorWidgetBuilder();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _EdotBoundaryScope(fallback: widget.fallback, child: widget.child);
}

/// Carries the nearest enclosing [EdotErrorBoundary]'s fallback down the tree.
///
/// Inherited rather than passed, because the widget that has to find it is the one the
/// framework substitutes for the failure — and that widget is built at the point of
/// failure, which the boundary knows nothing about.
class _EdotBoundaryScope extends InheritedWidget {
  const _EdotBoundaryScope({required this.fallback, required super.child});

  final Widget Function(Object error) fallback;

  @override
  bool updateShouldNotify(_EdotBoundaryScope oldWidget) =>
      fallback != oldWidget.fallback;
}

/// Renders the nearest enclosing boundary's fallback, or what the framework would have.
///
/// The framework inserts this in place of a widget that failed, which is what makes a
/// boundary work at all: this is built at the point of failure, so it can look *up* for
/// a boundary. Nothing else in the tree knows where the failure was.
class _EdotFallbackWidget extends StatelessWidget {
  const _EdotFallbackWidget(this.details, this.orElse);

  final FlutterErrorDetails details;

  /// What to show when no boundary encloses the failure — the builder that was in place
  /// before the first boundary was mounted, so an unguarded subtree looks exactly as it
  /// did.
  final ErrorWidgetBuilder orElse;

  @override
  Widget build(BuildContext context) {
    final boundary = context
        .dependOnInheritedWidgetOfExactType<_EdotBoundaryScope>();

    if (boundary == null) return orElse(details);

    return boundary.fallback(details.exception);
  }
}

/// How many boundaries are mounted. The hook is global, so it is claimed once by the
/// first and released by the last — nesting two boundaries must not restore the previous
/// builder while the outer one is still relying on it.
int _mountedBoundaries = 0;

/// The builder this library installed, kept so [_releaseErrorWidgetBuilder] can tell
/// whether it is still the one in force.
ErrorWidgetBuilder? _installedBuilder;
ErrorWidgetBuilder? _previousBuilder;

void _acquireErrorWidgetBuilder() {
  _mountedBoundaries++;
  if (_mountedBoundaries > 1) return;

  final previous = ErrorWidget.builder;
  _previousBuilder = previous;
  _installedBuilder = (details) => _EdotFallbackWidget(details, previous);
  ErrorWidget.builder = _installedBuilder!;
}

void _releaseErrorWidgetBuilder() {
  _mountedBoundaries--;
  if (_mountedBoundaries > 0) return;

  // Only when ours is still in force. Something installed after us owns the hook now,
  // and restoring over it would silently undo whatever that was.
  final previous = _previousBuilder;
  if (previous != null && ErrorWidget.builder == _installedBuilder) {
    ErrorWidget.builder = previous;
  }

  _installedBuilder = null;
  _previousBuilder = null;
}
