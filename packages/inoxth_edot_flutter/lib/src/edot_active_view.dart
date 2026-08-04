import 'package:flutter/foundation.dart';

import 'edot_ids.dart';

/// The screen currently visible to the user.
@immutable
class EdotActiveView {
  const EdotActiveView(this.name, this.id);

  /// The Screen Name: a low-cardinality label, with variable path segments
  /// collapsed.
  final String name;

  /// Identifies this entry to the screen.
  ///
  /// Fresh on every entry, so one entry's telemetry can be grouped without also
  /// matching earlier ones.
  ///
  /// Minted here, not by the Agent. It is not an OpenTelemetry span id — the Agent
  /// owns those and Dart never sees one (ADR-0002) — so it cannot be joined against
  /// a span's `span_id` in a dashboard; join on this attribute on both sides
  /// instead. Where a navigation set the view, its Screen Span carries the same
  /// value; a view set explicitly for an in-page switch has no Screen Span behind
  /// it at all (ADR-0004).
  final String id;

  @override
  String toString() => 'EdotActiveView($name, id: $id)';
}

/// The current Active View, or null when none is set.
///
/// Genuinely global, unlike span parenting: exactly one screen is visible to the
/// user at a time, so a singleton is the honest model here where a zone is the
/// honest model there (ADR-0004).
EdotActiveView? _activeView;

EdotActiveView? get activeView => _activeView;

void setActiveView(String name) {
  if (name.trim().isEmpty) {
    throw ArgumentError.value(name, 'name', 'Screen Name must not be blank');
  }
  _activeView = EdotActiveView(name, newLocalId());
}

void clearActiveView() => _activeView = null;

/// Screen attributes for the current Active View, keyed by their wire names.
///
/// Empty when no view is set — both attributes are attached together or not at
/// all, because a screen name with no identifier could not be tied to an entry, and
/// inventing a placeholder would report a screen the user was never on.
///
/// This is the only place the production code spells the ADR-0003 names: the
/// native sides receive a map of attributes to apply and never learn the
/// vocabulary. The Seam 2 contract spells them again on purpose — a test that
/// imported them from here could only prove the code equals itself, and a rename
/// would sail through.
Map<String, String> activeViewAttributes() {
  final view = _activeView;
  if (view == null) return const {};

  return {'screen.name': view.name, 'screen.id': view.id};
}
