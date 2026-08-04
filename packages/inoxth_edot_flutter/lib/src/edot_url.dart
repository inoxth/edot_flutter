/// URL handling shared by every traced transport.
///
/// Separate from the transports themselves so the rules that decide what is
/// recorded — and what is not traced at all — are testable without a socket.
library;

/// Reduces [url] to what is safe to record, then applies [customSanitizer].
///
/// Strips the query string, the fragment and any credentials in the authority.
/// None of the three identifies the resource that was requested, and all three
/// routinely carry tokens or personal data — `http.url` keeps the full URL
/// (ADR-0003), so stripping has to happen here rather than by dropping the
/// attribute later.
///
/// [customSanitizer] runs last, on an already-stripped URL, so it can only
/// tighten further — collapsing an identifier in a path, typically. Running it
/// first would let it hand back a URL with the query restored.
///
/// A URL with no host to parse — a relative reference, say — cannot be rebuilt, so
/// it is cut at the first `?` or `#` instead. It is never passed through whole: a
/// request should not go untraced because its URL was unusual, and it should not
/// leak its query string for that reason either.
String sanitizeUrl(String url, [String Function(String)? customSanitizer]) {
  final uri = Uri.tryParse(url);

  // Rebuilt from the parts worth keeping rather than by clearing the rest.
  // `Uri.replace` treats a null query as "leave it alone", so removing a component
  // that way silently keeps it — which for the query string is the whole risk.
  final stripped = (uri == null || uri.host.isEmpty)
      ? url.split(RegExp('[?#]')).first
      : Uri(
          scheme: uri.scheme,
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
          path: uri.path,
        ).toString();

  return customSanitizer == null ? stripped : customSanitizer(stripped);
}

/// Whether [url]'s host is [collectorHost], compared case-insensitively.
///
/// Host and nothing else, per ADR-0006. No path condition and no port condition:
/// host-only is complete by construction, covering signal export, central config
/// and any URL the Agent starts calling later, and it cannot be defeated by a port
/// being normalised away.
bool isCollectorHost(String url, String collectorHost) {
  final host = Uri.tryParse(url)?.host;
  if (host == null || host.isEmpty) return false;

  return host.toLowerCase() == collectorHost.toLowerCase();
}

/// Whether [url] matches any of [patterns].
///
/// A `String` pattern matches as a substring and a [RegExp] as a regular
/// expression — both are [Pattern]s, so one list carries either.
///
/// Matched against the URL as given, query string included. Excluding by a query
/// parameter is a normal thing to want, and matching a URL is not recording it.
bool isExcluded(String url, List<Pattern> patterns) =>
    patterns.any((pattern) => pattern.allMatches(url).isNotEmpty);

/// Path of [url], for `http.target`.
///
/// Read out of the string rather than via `Uri.path`, which percent-encodes
/// characters a sanitiser may legitimately have introduced — a hook collapsing an
/// identifier to `/orders/{id}` would otherwise land here as `/orders/%7Bid%7D`,
/// so `http.url` and `http.target` would render the same URL two different ways.
///
/// Anything from `?` or `#` onward is dropped. The sanitiser has already removed
/// both, and a target carrying a query would reintroduce exactly what it strips.
String? httpTarget(String url) {
  final schemeEnd = url.indexOf('://');
  if (schemeEnd == -1) return null;

  final pathStart = url.indexOf('/', schemeEnd + 3);
  if (pathStart == -1) return '/';

  final path = url.substring(pathStart).split(RegExp('[?#]')).first;
  return path.isEmpty ? '/' : path;
}

String? httpScheme(String url) => _part(url, (uri) => uri.scheme);

/// Host of [url] without its port, for `net.peer.name`.
String? peerName(String url) => _part(url, (uri) => uri.host);

/// Port of [url], for `net.peer.port`.
///
/// Falls back to the scheme's default, because the peer is reached on 443 whether
/// or not the URL writes it — and a missing port would lose the one attribute
/// that tells two services on one host apart.
int? peerPort(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return null;

  return uri.hasPort ? uri.port : _defaultPort(uri.scheme);
}

/// Span name for a request: the method and the host.
///
/// Not the path. A path puts identifiers in the span name, and one name per order
/// id makes a trace list unreadable and span-name aggregation meaningless.
String spanNameFor(String method, String url) {
  final host = peerName(url);

  return (host == null || host.isEmpty) ? 'HTTP $method' : '$method $host';
}

int? _defaultPort(String scheme) => switch (scheme.toLowerCase()) {
  'https' => 443,
  'http' => 80,
  _ => null,
};

/// Reads one component, or null when the URL will not parse or names no host.
String? _part(String url, String Function(Uri) read) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return null;

  final value = read(uri);
  return value.isEmpty ? null : value;
}
