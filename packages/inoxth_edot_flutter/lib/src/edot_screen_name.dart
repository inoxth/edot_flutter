import 'package:flutter/widgets.dart';

/// Screen Name for a route that names nothing usable.
///
/// Reads as the gap it is. Someone seeing it in Kibana knows to name the route or supply
/// an extractor, which is not true of a name that looks deliberate.
const String unnamedScreenName = 'unnamed';

/// Derives a Screen Name from a route's settings.
///
/// The name is attached to every span and log the app produces while the screen is the
/// Active View (ADR-0004), so keeping its cardinality bounded is the whole job here. A
/// route name of `/orders/12345` becomes `/orders/{id}`, so two entries to the same screen
/// aggregate instead of becoming two screens.
///
/// Returns [fallback] when the route names nothing usable. Not the route's runtime type,
/// which would read like an answer while being `MaterialPageRoute` for every unnamed
/// screen in the app — an obviously wrong name gets fixed and a plausible one does not.
/// Never blank, because enrichment attaches the Screen Name and the identifier together or
/// not at all, so a blank one would drop screen attribution for the whole screen.
///
/// The collapsing rules are deliberately narrow (see [_looksLikeAnIdentifier]). Anything
/// they miss is what `EdotNavigatorObserver`'s extractor is for: a rule that guessed more
/// would merge two genuinely different screens, and nothing downstream could tell.
String deriveScreenName(
  RouteSettings settings, {
  String fallback = unnamedScreenName,
}) {
  // A route name may carry a query string or a fragment, and both hold exactly the
  // high-cardinality — often personal — values a Screen Name must not spread across every
  // span in the system. The one check covers a name that was blank to begin with too:
  // splitting an empty string yields an empty first part.
  final path = (settings.name?.trim() ?? '').split(RegExp('[?#]')).first;
  if (path.isEmpty) return fallback;

  // Split and rejoined rather than pattern-replaced across the whole string, so a rule
  // can only ever match a complete segment. `/v12345/x` must not become `/v{id}/x`.
  //
  // Never empty once [path] is not: rejoining N segments restores the N-1 separators, and
  // a lone segment is either kept or replaced by a placeholder.
  return path
      .split('/')
      .map((segment) => _looksLikeAnIdentifier(segment) ? '{id}' : segment)
      .join('/');
}

/// Whether a path segment is a value rather than part of the route vocabulary.
///
/// Three rules, each chosen because nothing in a routing table looks like it:
///
/// - **All digits.** `12345`, `9`. A vocabulary segment containing a digit — `v2`, `2fa` —
///   keeps its letters, so it is not caught.
/// - **A UUID**, in either case.
/// - **Long hex.** A Mongo ObjectId is 24 characters, a Git short SHA 12. The length floor
///   is what stops the rule eating `face` and `beef`, which are hex and are also words.
///
/// Not a rule: "contains a digit and is long". It reads plausibly and would collapse
/// `/settings/notifications2` — a real screen, silently merged with another.
bool _looksLikeAnIdentifier(String segment) =>
    _allDigits.hasMatch(segment) ||
    _uuid.hasMatch(segment) ||
    _longHex.hasMatch(segment);

final RegExp _allDigits = RegExp(r'^\d+$');

final RegExp _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// Twelve is the shortest hex string this treats as an identifier: a Git short SHA. Below
/// it, hex and English overlap enough that the rule would misfire on real route segments.
final RegExp _longHex = RegExp(r'^[0-9a-f]{12,}$', caseSensitive: false);
