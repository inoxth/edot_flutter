import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/src/edot_screen_name.dart';

/// Seam 1 — deriving a Screen Name from a route.
///
/// A Screen Name is attached to every span and log in the system (ADR-0004), so its
/// cardinality is not a tidiness question: one name per order id makes screen
/// aggregation meaningless and multiplies the index's term dictionary. The table below is
/// the contract, and the collapsing rules are deliberately narrow — the extractor is the
/// escape hatch for anything they miss, because a rule that guesses would quietly merge
/// two genuinely different screens.
void main() {
  String derive(String? name) =>
      deriveScreenName(RouteSettings(name: name), fallback: 'unnamed');

  group('a route name that is already low-cardinality', () {
    test('is kept as it is', () {
      expect(derive('/checkout'), '/checkout');
      expect(derive('/orders/summary'), '/orders/summary');
      expect(derive('/'), '/');
    });

    test('keeps segments that merely contain a digit', () {
      // `v2` and `2fa` are route vocabulary, not identifiers. Collapsing anything with a
      // digit in it would merge `/api/v1/x` and `/api/v2/x` into one screen.
      expect(derive('/api/v2/status'), '/api/v2/status');
      expect(derive('/login/2fa'), '/login/2fa');
    });
  });

  group('collapsing identifier-like segments', () {
    test('collapses an all-digit segment', () {
      expect(derive('/orders/12345'), '/orders/{id}');
      expect(derive('/orders/12345/items/9'), '/orders/{id}/items/{id}');
    });

    test('collapses a UUID', () {
      expect(
        derive('/users/6ba7b810-9dad-11d1-80b4-00c04fd430c8/profile'),
        '/users/{id}/profile',
      );
    });

    test('collapses a UUID whatever case it is written in', () {
      expect(
        derive('/users/6BA7B810-9DAD-11D1-80B4-00C04FD430C8'),
        '/users/{id}',
      );
    });

    test('collapses a long hex identifier', () {
      // A Mongo ObjectId is 24 hex characters; nothing in a route vocabulary is.
      expect(derive('/docs/507f1f77bcf86cd799439011'), '/docs/{id}');
    });

    test('leaves a short hex-looking word alone', () {
      // `face` and `beef` are hex, and are also words. The length floor is what keeps a
      // rule about identifiers from eating the vocabulary.
      expect(derive('/emoji/face'), '/emoji/face');
      expect(derive('/menu/beef'), '/menu/beef');
    });

    test('collapses repeated entries to one name', () {
      // The point of the whole rule: two entries to the same screen must aggregate.
      expect(derive('/orders/1'), derive('/orders/22222'));
    });
  });

  group('what is not part of the name', () {
    test('drops a query string', () {
      // A route name can carry one, and its values are exactly the high-cardinality,
      // sometimes-personal data a Screen Name must not spread across every span.
      expect(derive('/search?q=shoes&page=3'), '/search');
    });

    test('drops a fragment', () {
      expect(derive('/help#billing'), '/help');
    });

    test('keeps a trailing slash distinct from its absence, as the route did', () {
      // Not normalised. Two names differing only in a slash is a routing table's
      // business, and silently merging them would report a screen the app does not have.
      expect(derive('/orders/'), '/orders/');
    });
  });

  group('a route with no usable name', () {
    test('falls back rather than yielding a gap', () {
      // Enrichment attaches the name and the identifier together or not at all, so a
      // blank name would drop screen attribution for the whole screen.
      expect(derive(null), 'unnamed');
      expect(derive(''), 'unnamed');
      expect(derive('   '), 'unnamed');
    });

    test('falls back rather than naming the route type', () {
      // `MaterialPageRoute` would look like a real answer while being the same answer for
      // every unnamed screen in the app. An obviously wrong name is better than a
      // plausible one, because only the first gets fixed.
      expect(derive(null), isNot(contains('Route')));
    });

    test('falls back when collapsing consumes the whole name', () {
      // `/12345` collapses to `/{id}`, which is a real screen. But a name that is
      // *only* separators has nothing left to identify.
      expect(derive('?q=1'), 'unnamed');
      expect(derive('/12345'), '/{id}');
    });
  });
}
