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
    required this.serverUrl,
    this.auth = const EdotAuth.none(),
    this.exportProtocol = ExportProtocol.http,
    this.sessionSamplingRate = 1.0,
    this.debug = false,
    this.disableAgent = false,
    this.android = const EdotAndroidConfig(),
    this.urlSanitizer,
    this.excludedUrls = const [],
  }) : collectorHost = _validate(
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
      'excludedUrls: ${excludedUrls.length})';
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
