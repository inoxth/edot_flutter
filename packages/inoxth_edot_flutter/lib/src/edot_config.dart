import 'edot_consent.dart';

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
/// **There is no native crash reporting option here, and that is not an
/// omission.** Android's Agent discovers instrumentations by scanning the
/// classpath and installs everything it finds, with no filter and no runtime
/// switch — so whether crash capture happens is decided by which artefacts the
/// build includes, and this Plugin deliberately does not include the crash one
/// (ADR-0009). Native crashes are therefore not captured on Android at all.
/// iOS is the asymmetric case: see [EdotIosConfig.crashReportingEnabled].
class EdotAndroidConfig {
  const EdotAndroidConfig({this.diskBufferingEnabled = true});

  /// Whether telemetry is buffered to disk before export, so it survives
  /// offline periods.
  ///
  /// Android only, and not because iOS lacks the feature: the pinned iOS Agent
  /// persists telemetry unconditionally and offers no way to turn it off. So
  /// telemetry survives an offline period on both platforms, and only Android
  /// can be told not to.
  final bool diskBufferingEnabled;

  @override
  String toString() =>
      'EdotAndroidConfig(diskBufferingEnabled: $diskBufferingEnabled)';
}

/// iOS-only configuration.
///
/// Scoped the same way as [EdotAndroidConfig], and for the same reason: an option
/// that applies to one platform should be impossible to set for the other rather
/// than silently doing nothing there.
///
/// Every field defaults to what the pinned iOS Agent does on its own, which is
/// also what this organisation's React Native SDK gets — it passes a bare
/// instrumentation configuration and exposes none of these. Adding the toggles
/// therefore costs no Fleet Alignment: an app that sets none of them behaves as
/// the React Native fleet does.
class EdotIosConfig {
  const EdotIosConfig({
    this.crashReportingEnabled = true,
    this.systemMetricsEnabled = true,
    this.appMetricsEnabled = true,
    this.lifecycleEventsEnabled = true,
  });

  /// Whether the Agent captures native crashes. On by default — an opt-*out*.
  ///
  /// **Turn this off if the app already has a crash reporter.** Crash capture
  /// installs process-wide signal and Mach exception handlers, Crashlytics and
  /// Sentry install their own, and for signal-based crashes whichever installed
  /// last tends to win — so leaving both on can silently stop the incumbent from
  /// reporting, which nobody notices until an incident.
  ///
  /// On by default despite that, to match the React Native SDK so both fleets
  /// report crashes identically (ADR-0009). There is no Android equivalent; see
  /// [EdotAndroidConfig].
  final bool crashReportingEnabled;

  /// Whether CPU and memory are sampled, with no app-side work.
  ///
  /// Two observable gauges, `system.cpu.usage` and `system.memory.usage`, read on the
  /// metric reader's collection cycle for as long as the app runs. Turn them off for
  /// an app that has no use for device-level metrics: they arrive continuously, so
  /// they are the steadiest contributor to metric volume the Agent has, and nothing
  /// else here is paid for per unit of time.
  final bool systemMetricsEnabled;

  /// Whether MetricKit reports — launch timings, app exits — are collected, with no
  /// app-side work.
  ///
  /// Cheap to leave on: iOS hands these to the app in one batch a day, so it is a
  /// negligible amount of telemetry. Turn it off if you already collect MetricKit
  /// yourself, so the same reports are not counted twice under two names.
  final bool appMetricsEnabled;

  /// Whether foreground and background transitions are recorded.
  ///
  /// One span per transition, carrying `lifecycle.state`. Turn it off for an app that
  /// backgrounds and foregrounds constantly — a turn-by-turn or media app — where the
  /// transitions outnumber everything the app itself records. Leave it on otherwise:
  /// it is what tells a session that ended from a user who walked away.
  final bool lifecycleEventsEnabled;

  @override
  String toString() =>
      'EdotIosConfig(crashReportingEnabled: $crashReportingEnabled, '
      'systemMetricsEnabled: $systemMetricsEnabled, '
      'appMetricsEnabled: $appMetricsEnabled, '
      'lifecycleEventsEnabled: $lifecycleEventsEnabled)';
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
    this.trackingConsent = EdotTrackingConsent.granted,
    this.debug = false,
    this.disableAgent = false,
    this.android = const EdotAndroidConfig(),
    this.ios = const EdotIosConfig(),
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
  ///
  /// **Honoured on Android; unreliable on iOS.** The pinned iOS Agent's sampler starts out
  /// sampling everything and only consults this rate when the session manager announces a
  /// refresh, which it does only for a session that is new or has expired. A cold start
  /// therefore applies the rate and a warm one — a relaunch inside the 30-minute session
  /// window — ignores it, so the iOS fleet reports more than this asks for. There is no
  /// workaround from here: the refresh is not public API, and this organisation's React
  /// Native SDK passes the same rate to the same Agent, so the two fleets are affected
  /// alike. See ADR-0001.
  ///
  /// Do not use this to switch telemetry off — [disableAgent] does that on both platforms.
  final double sessionSamplingRate;

  /// The user's Tracking Consent as the app starts.
  ///
  /// Defaults to [EdotTrackingConsent.granted], matching this organisation's React
  /// Native SDK — which is a Fleet Alignment choice, not a claim about what your
  /// regulator wants. **An app that must not emit before the user has answered should
  /// start at [EdotTrackingConsent.pending]** and call [Edot.setTrackingConsent] once
  /// they have, which takes effect immediately and needs no restart.
  ///
  /// Telemetry the app produces while this withholds emission is discarded, not held:
  /// granting consent later does not release what came before it.
  ///
  /// Not passed to either Agent. The gate is applied in Dart, before anything reaches
  /// the platform boundary, so sending this natively would imply a second enforcement
  /// point that does not exist.
  final EdotTrackingConsent trackingConsent;

  /// Enables the Agent's internal logging. Never includes credentials.
  final bool debug;

  /// Stops the Agent emitting anything, for local development.
  final bool disableAgent;

  final EdotAndroidConfig android;
  final EdotIosConfig ios;

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
      'sessionSamplingRate: $sessionSamplingRate, '
      'trackingConsent: ${trackingConsent.wireValue}, debug: $debug, '
      'disableAgent: $disableAgent, '
      // The platform blocks in full. They are the first thing to check when
      // telemetry is missing on one platform and present on the other.
      'android: $android, ios: $ios, '
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
    'ios': <String, Object?>{
      'crashReportingEnabled': config.ios.crashReportingEnabled,
      'systemMetricsEnabled': config.ios.systemMetricsEnabled,
      'appMetricsEnabled': config.ios.appMetricsEnabled,
      'lifecycleEventsEnabled': config.ios.lifecycleEventsEnabled,
    },
  };
}
