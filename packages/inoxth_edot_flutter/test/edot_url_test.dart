import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/src/edot_url.dart';

/// The URL rules every transport shares: what reaches `http.url`, and what is not
/// traced at all.
void main() {
  group('sanitising', () {
    test('drops the query string, which routinely carries tokens', () {
      expect(
        sanitizeUrl('https://api.example.com/orders?token=abc123&page=2'),
        'https://api.example.com/orders',
      );
    });

    test('drops credentials written into the URL', () {
      // A URL is not a safe place for these, but callers do it, and recording one
      // verbatim would publish the credential to everyone with dashboard access.
      expect(
        sanitizeUrl('https://user:s3cret@api.example.com/orders'),
        'https://api.example.com/orders',
      );
    });

    test('drops the fragment', () {
      // Never sent to the server, so it is not part of what was requested — and it
      // is one more place a token can hide.
      expect(
        sanitizeUrl('https://api.example.com/orders#token=abc'),
        'https://api.example.com/orders',
      );
    });

    test('keeps scheme, host, port and path', () {
      expect(
        sanitizeUrl('http://api.example.com:8080/v1/orders/42'),
        'http://api.example.com:8080/v1/orders/42',
      );
    });

    test('applies a custom sanitiser after the built-in stripping', () {
      // The custom hook sees an already-safe URL, so it can only tighten. Running
      // it first would let a caller hand back something with the query restored.
      expect(
        sanitizeUrl(
          'https://api.example.com/users/12345/orders?page=2',
          (url) => url.replaceAll(RegExp(r'/users/\d+'), '/users/{id}'),
        ),
        'https://api.example.com/users/{id}/orders',
      );
    });

    test('leaves an unparseable URL to the custom sanitiser', () {
      // Better a URL that survives than a request that goes untraced because its
      // URL was odd.
      expect(sanitizeUrl('not a url'), 'not a url');
    });

    test('still drops the query from a URL with no host to rebuild', () {
      // The stripping cannot go through Uri here, but "unusual URL" must not become
      // an exemption from the one thing this function exists to do.
      expect(sanitizeUrl('/orders?token=secret'), '/orders');
      expect(sanitizeUrl('not a url#token=secret'), 'not a url');
    });
  });

  group('Collector Host exclusion', () {
    // ADR-0006: host equality and nothing else. Path and port are never compared,
    // because enumerating the Agent's endpoints leaked twice in the React Native
    // SDK before it landed on this rule.
    test('excludes the Collector Host at any path', () {
      expect(
        isCollectorHost('https://apm.example.com/v1/traces', 'apm.example.com'),
        isTrue,
      );
      expect(
        isCollectorHost(
          'https://apm.example.com/config/v1/agents',
          'apm.example.com',
        ),
        isTrue,
      );
    });

    test('excludes it at any port, including none', () {
      expect(
        isCollectorHost('https://apm.example.com:4318/x', 'apm.example.com'),
        isTrue,
      );
      expect(
        isCollectorHost('http://apm.example.com/x', 'apm.example.com'),
        isTrue,
      );
    });

    test('compares the host case-insensitively', () {
      expect(
        isCollectorHost('https://APM.Example.com/v1/traces', 'apm.example.com'),
        isTrue,
      );
    });

    test('does not match a lookalike host', () {
      // The failure a URL-prefix guard produced: this starts with the server URL
      // as a string, and silently went untraced.
      expect(
        isCollectorHost(
          'https://apm.example.com.evil.test/steal',
          'apm.example.com',
        ),
        isFalse,
      );
    });

    test('does not match a different host', () {
      expect(
        isCollectorHost('https://api.example.com/orders', 'apm.example.com'),
        isFalse,
      );
    });

    test('does not match a subdomain of the Collector Host', () {
      expect(
        isCollectorHost('https://eu.apm.example.com/x', 'apm.example.com'),
        isFalse,
      );
    });
  });

  group('URL exclusion', () {
    test('matches a substring, so a path fragment is enough', () {
      expect(isExcluded('https://api.example.com/health', ['/health']), isTrue);
      expect(
        isExcluded('https://api.example.com/orders', ['/health']),
        isFalse,
      );
    });

    test('matches a regular expression', () {
      expect(
        isExcluded('https://api.example.com/poll/42', [RegExp(r'/poll/\d+$')]),
        isTrue,
      );
    });

    test('matches against the URL as given, query string included', () {
      // Deliberately the raw URL rather than the sanitised one: excluding by a
      // query parameter is a normal thing to want, and matching is not recording.
      expect(
        isExcluded('https://api.example.com/x?probe=1', ['probe=1']),
        isTrue,
      );
    });

    test('excludes nothing when no patterns are configured', () {
      expect(isExcluded('https://api.example.com/x', const []), isFalse);
    });
  });

  group('derived attributes', () {
    test('reports the path as the target', () {
      expect(httpTarget('https://api.example.com/v1/orders'), '/v1/orders');
    });

    test('reports the scheme', () {
      expect(httpScheme('https://api.example.com/x'), 'https');
    });

    test('reports the peer host without its port', () {
      expect(peerName('https://api.example.com:8080/x'), 'api.example.com');
    });

    test('reports an explicit port', () {
      expect(peerPort('https://api.example.com:8080/x'), 8080);
    });

    test('resolves the port from the scheme when it is not written', () {
      // The peer is reached on 443 whether or not the URL says so, and a null here
      // would lose the one attribute that tells two services on a host apart.
      expect(peerPort('https://api.example.com/x'), 443);
      expect(peerPort('http://api.example.com/x'), 80);
    });

    test('reports nothing derivable from an unparseable URL', () {
      expect(httpTarget('not a url'), isNull);
      expect(httpScheme('not a url'), isNull);
      expect(peerName('not a url'), isNull);
      expect(peerPort('not a url'), isNull);
    });
  });

  group('span naming', () {
    test('is method and host, so cardinality stays bounded', () {
      // The URL's path would put an identifier in the span name, and one span name
      // per order id makes the trace list useless.
      expect(
        spanNameFor('GET', 'https://api.example.com/orders/42'),
        'GET api.example.com',
      );
    });

    test('falls back to the method alone when there is no host', () {
      expect(spanNameFor('POST', 'not a url'), 'HTTP POST');
    });
  });
}
