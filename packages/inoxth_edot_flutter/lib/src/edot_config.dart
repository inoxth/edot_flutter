/// How the Agent authenticates to the collector.
sealed class EdotAuth {
  const EdotAuth();

  /// Elastic API key.
  const factory EdotAuth.apiKey(String key) = EdotApiKeyAuth;

  /// Elastic secret token.
  const factory EdotAuth.secretToken(String token) = EdotSecretTokenAuth;

  /// No credential. Valid for a local collector.
  const factory EdotAuth.none() = EdotNoAuth;
}

/// Authenticates with an Elastic API key.
final class EdotApiKeyAuth extends EdotAuth {
  const EdotApiKeyAuth(this.key);

  final String key;
}

/// Authenticates with an Elastic secret token.
final class EdotSecretTokenAuth extends EdotAuth {
  const EdotSecretTokenAuth(this.token);

  final String token;
}

/// Sends no credential.
final class EdotNoAuth extends EdotAuth {
  const EdotNoAuth();
}

/// Wire protocol used to export telemetry.
enum ExportProtocol { http, grpc }

/// Android-only configuration.
///
/// Platform-scoped options live in their own type so a field's applicability is
/// visible in the type rather than buried in a doc comment, and so setting an
/// option for the wrong platform is impossible rather than a silent no-op.
///
/// The iOS equivalent arrives with the platform-passthroughs ticket, alongside
/// the options it introduces.
class EdotAndroidConfig {
  const EdotAndroidConfig({this.diskBufferingEnabled = true});

  /// Whether telemetry is buffered to disk before export, so it survives
  /// offline periods.
  final bool diskBufferingEnabled;
}

/// Configuration for [EdotConfig.new].
///
/// Field names match this organisation's React Native SDK verbatim, so the two
/// SDKs are configured the same way. Note `serverUrl` rather than `exportUrl` —
/// that follows the pinned iOS Agent's own API.
///
/// Validation happens in the constructor and throws [ArgumentError] naming the
/// offending field. Invalid configuration is a programming error, and failing at
/// construction is far cheaper to diagnose than silence in production.
class EdotConfig {
  EdotConfig({
    required this.serviceName,
    required this.serviceVersion,
    required this.deploymentEnvironment,
    required String serverUrl,
    this.auth = const EdotAuth.none(),
    this.exportProtocol = ExportProtocol.http,
    this.sessionSamplingRate = 1.0,
    this.debug = false,
    this.disableAgent = false,
    this.android = const EdotAndroidConfig(),
    this.urlSanitizer,
    this.excludedUrls = const [],
    this.tracePropagationTargets,
    this.traceAllHttpTraffic = false,
  }) : serverUrl = _withExplicitPort(serverUrl),
       collectorHost = _validate(
         serviceName: serviceName,
         serviceVersion: serviceVersion,
         deploymentEnvironment: deploymentEnvironment,
         serverUrl: serverUrl,
         sessionSamplingRate: sessionSamplingRate,
       );

  /// Identifies the application in Elastic.
  final String serviceName;

  /// Application version.
  final String serviceVersion;

  /// Environment identifier, such as `prod` or `staging`.
  final String deploymentEnvironment;

  /// OTLP URL telemetry is exported to. Its host becomes [collectorHost].
  ///
  /// Always carries an explicit port, added from the scheme when the URL you passed
  /// wrote none — so `https://apm.example.com` is stored as
  /// `https://apm.example.com:443`. Without that, the two Agents disagree about
  /// where to export: the pinned iOS Agent falls back to its own hardcoded 8200
  /// when the URL string names no port, while Android resolves the scheme default.
  /// The same configuration would then reach the collector on one platform and
  /// silently go nowhere on the other.
  final String serverUrl;

  final EdotAuth auth;
  final ExportProtocol exportProtocol;

  /// Fraction of sessions that report, from 0.0 to 1.0 inclusive.
  final double sessionSamplingRate;

  /// Enables the Agent's internal logging. Never includes credentials.
  final bool debug;

  /// Stops the Agent emitting anything, for local development.
  final bool disableAgent;

  final EdotAndroidConfig android;

  /// Last chance to change a request URL before it is recorded.
  ///
  /// The query string, the fragment and any credentials in the authority are
  /// already stripped before this runs, so use it to collapse what remains —
  /// turning `/users/12345/orders` into `/users/{id}/orders`, typically, which also
  /// keeps `http.url` low-cardinality.
  ///
  /// Dart-side only: it never crosses to the Agent, so it cannot reach spans the
  /// Agent's own instrumentation produces.
  final String Function(String url)? urlSanitizer;

  /// Requests whose URL matches any of these are not traced at all.
  ///
  /// A `String` matches as a substring, a [RegExp] as a regular expression. For
  /// health checks and polling, which otherwise flood the index with spans nobody
  /// reads.
  ///
  /// Matched against the URL as given, query string included — excluding by a query
  /// parameter is a normal thing to want.
  final List<Pattern> excludedUrls;

  /// Which traced requests carry W3C Trace Context, so the spans they cause
  /// downstream join this app's trace.
  ///
  /// Null, the default, propagates to every traced host — the same reach as the
  /// Agents' own instrumentation. Give a list to narrow it: to keep this app's trace
  /// identifiers away from a third party, or off a partner's request filtering. An
  /// empty list propagates to nothing.
  ///
  /// Narrowing this costs nothing but the link. A request to a host left out is
  /// still traced, and its span still reaches Kibana.
  ///
  /// Matched like [excludedUrls]: a `String` as a substring, a [RegExp] as a
  /// regular expression, against the URL as given.
  final List<Pattern>? tracePropagationTargets;

  /// Traces every request `dart:io` makes, not only those made through this
  /// Plugin's own transports.
  ///
  /// Reaches what wrapping a client cannot: a third-party pure-Dart package builds its
  /// own `HttpClient`, and nothing at the app's own call sites will see it. Off by
  /// default, because it installs a process-wide `HttpOverrides` — one call's worth of
  /// opt-in for a global effect.
  ///
  /// A request already traced by [EdotHttpClient] or the Dio interceptor is not traced
  /// twice; those layers mark it, and this one leaves a marked request alone.
  ///
  /// Two things differ on this path, both unavoidable and neither affecting requests
  /// made through the other transports: the span begins when the request is dispatched
  /// rather than when the connection is opened, and it carries no Trace Context.
  final bool traceAllHttpTraffic;

  /// Host component of [serverUrl].
  ///
  /// Derived once here because requests to this host are never traced, at any
  /// path or port (ADR-0006), and re-parsing the URL at each call site is how
  /// that exclusion drifts.
  final String collectorHost;

  /// Characters that would corrupt the delimited resource-attribute encoding
  /// these values travel in, taking the whole resource down with them.
  static final RegExp _forbiddenInIdentity = RegExp('[,=]');

  static String _validate({
    required String serviceName,
    required String serviceVersion,
    required String deploymentEnvironment,
    required String serverUrl,
    required double sessionSamplingRate,
  }) {
    _requireIdentity(serviceName, 'serviceName');
    _requireIdentity(serviceVersion, 'serviceVersion');
    _requireIdentity(deploymentEnvironment, 'deploymentEnvironment');

    if (sessionSamplingRate < 0.0 || sessionSamplingRate > 1.0) {
      throw ArgumentError.value(
        sessionSamplingRate,
        'sessionSamplingRate',
        'must be between 0.0 and 1.0 inclusive',
      );
    }

    final uri = Uri.tryParse(serverUrl);
    if (uri == null ||
        !uri.hasScheme ||
        !uri.isScheme('http') && !uri.isScheme('https') ||
        (uri.host).isEmpty) {
      throw ArgumentError.value(
        serverUrl,
        'serverUrl',
        'must be an absolute http or https URL, for example '
            'http://localhost:4318',
      );
    }

    return uri.host;
  }

  /// Writes the scheme's default port into [serverUrl] when it names none.
  ///
  /// `Uri` cannot express this: `replace(port: 443)` on an https URL renders nothing,
  /// because Dart normalises a scheme-default port away — the very normalisation that
  /// lets the two platforms disagree. So the port is inserted into the string.
  ///
  /// Idempotent, and a URL that names a port already is returned untouched. A URL
  /// this cannot understand is left alone for [_validate] to reject.
  static String _withExplicitPort(String serverUrl) {
    final uri = Uri.tryParse(serverUrl);
    if (uri == null || uri.host.isEmpty) return serverUrl;

    final defaultPort = switch (uri.scheme.toLowerCase()) {
      'https' => 443,
      'http' => 80,
      _ => null,
    };
    if (defaultPort == null) return serverUrl;

    final authorityStart = serverUrl.indexOf('://') + 3;
    var authorityEnd = serverUrl.length;
    for (final delimiter in const ['/', '?', '#']) {
      final at = serverUrl.indexOf(delimiter, authorityStart);
      if (at != -1 && at < authorityEnd) authorityEnd = at;
    }

    final authority = serverUrl.substring(authorityStart, authorityEnd);
    if (_namesPort(authority)) return serverUrl;

    return serverUrl.replaceRange(authorityEnd, authorityEnd, ':$defaultPort');
  }

  /// Whether [authority] writes a port.
  ///
  /// Read off the string rather than taken from `Uri.hasPort`, which is false for
  /// an *explicitly* written scheme default — the same normalisation as above, on
  /// the detection side. Trusting it appends a second port to
  /// `https://host:443/x`.
  static bool _namesPort(String authority) {
    // Any colon before the '@' belongs to credentials, not a port.
    final host = authority.substring(authority.lastIndexOf('@') + 1);

    // An IPv6 literal is bracketed and full of colons; only one after the
    // closing bracket is a port.
    final portStart = host.startsWith('[') ? host.indexOf(']') + 1 : 0;

    return host.indexOf(':', portStart) != -1;
  }

  static void _requireIdentity(String value, String field) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, field, 'must not be blank');
    }
    if (_forbiddenInIdentity.hasMatch(value)) {
      throw ArgumentError.value(
        value,
        field,
        "must not contain ',' or '=' — these corrupt the resource attributes "
        'this value is encoded into',
      );
    }
  }

  /// Redacts credentials.
  ///
  /// [EdotConfig] can reach logs and crash reports through a stack trace or a
  /// debug dump, so the credential must not be in its string form.
  @override
  String toString() =>
      'EdotConfig(serviceName: $serviceName, serviceVersion: $serviceVersion, '
      'deploymentEnvironment: $deploymentEnvironment, serverUrl: $serverUrl, '
      'auth: ${switch (auth) {
        EdotApiKeyAuth() => 'apiKey(redacted)',
        EdotSecretTokenAuth() => 'secretToken(redacted)',
        EdotNoAuth() => 'none',
      }}, exportProtocol: ${exportProtocol.name}, '
      'sessionSamplingRate: $sessionSamplingRate, debug: $debug, '
      'disableAgent: $disableAgent, '
      // Whether they are set, not what they are: a sanitiser is a closure with no
      // useful representation, and the patterns are the first thing to suspect when
      // a request is missing from Kibana.
      'urlSanitizer: ${urlSanitizer == null ? 'none' : 'set'}, '
      'excludedUrls: ${excludedUrls.length}, '
      // "all hosts" rather than a count, because null and an empty list are
      // opposites here and both would print as a number nobody could tell apart.
      'tracePropagationTargets: '
      '${tracePropagationTargets == null ? 'all hosts' : '${tracePropagationTargets!.length} pattern(s)'}, '
      'traceAllHttpTraffic: $traceAllHttpTraffic)';
}

/// Encodes [config] for the platform channel.
///
/// Deliberately a function in `src/` rather than a method on [EdotConfig]: the
/// channel encoding is an internal contract with the two native implementations,
/// not something consumers should call or depend on.
/// [EdotConfig.collectorHost] is sent rather than re-derived natively, so both
/// layers apply ADR-0006 to the same value. `Uri.host` and `URL.host` do not
/// agree on case, and a host the two sides disagree about is a self-tracing leak.
Map<String, Object?> encodeConfig(EdotConfig config) {
  // One switch rather than one per wire field, so the sealed type is matched
  // exhaustively in a single place.
  final (apiKey, secretToken) = switch (config.auth) {
    EdotApiKeyAuth(:final key) => (key, null),
    EdotSecretTokenAuth(:final token) => (null, token),
    EdotNoAuth() => (null, null),
  };

  return <String, Object?>{
    'serviceName': config.serviceName,
    'serviceVersion': config.serviceVersion,
    'deploymentEnvironment': config.deploymentEnvironment,
    'serverUrl': config.serverUrl,
    'collectorHost': config.collectorHost,
    'exportProtocol': config.exportProtocol.name,
    'sessionSamplingRate': config.sessionSamplingRate,
    'debug': config.debug,
    'disableAgent': config.disableAgent,
    'apiKey': apiKey,
    'secretToken': secretToken,
    'android': <String, Object?>{
      'diskBufferingEnabled': config.android.diskBufferingEnabled,
    },
  };
}
