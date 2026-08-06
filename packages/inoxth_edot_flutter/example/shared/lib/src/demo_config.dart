import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

/// The outcome of turning a loaded `.env` map into telemetry configuration.
sealed class DemoConfigResult {
  const DemoConfigResult();
}

/// The `.env` supplied everything required; [config] is ready for `Edot.start`.
class DemoConfigReady extends DemoConfigResult {
  const DemoConfigReady(this.config);

  final EdotConfig config;
}

/// The `.env` was absent or carried no server URL; nothing should start.
///
/// [reason] is a short, human-readable explanation the app can show instead of
/// starting the Agent.
class DemoConfigMissing extends DemoConfigResult {
  const DemoConfigMissing(this.reason);

  final String reason;
}

/// Builds a demo [EdotConfig] from a loaded `.env` map.
///
/// Pure by design: it takes the already-loaded map, never the file system, so it
/// is provable at Seam 1. `EDOT_SERVER_URL` is the only required key - the rest
/// fall back to demo defaults - because it is the one value that must point at a
/// collector for anything to be worth starting. Behaviour flags the `.env` does
/// not cover (debug, app-wide tracing, the starting consent) are supplied by the
/// caller.
abstract final class DemoConfig {
  static const _defaultServiceName = 'edot-flutter-example';
  static const _defaultServiceVersion = '1.0.0';
  static const _defaultEnvironment = 'example';

  /// Transforms [env] into a [DemoConfigResult].
  ///
  /// Returns [DemoConfigMissing] when `EDOT_SERVER_URL` is absent or blank, or
  /// when `EDOT_SESSION_SAMPLING_RATE` is set but is not a number from 0.0 to
  /// 1.0; otherwise a [DemoConfigReady] wrapping the built config. A non-empty
  /// `EDOT_SECRET_TOKEN` becomes [EdotAuth.secretToken]; anything else becomes
  /// [EdotAuth.none]. An absent sampling rate defaults to 1.0 (report every
  /// session).
  static DemoConfigResult fromEnv(
    Map<String, String> env, {
    bool debug = false,
    bool traceAllHttpTraffic = false,
    EdotTrackingConsent trackingConsent = EdotTrackingConsent.granted,
  }) {
    final serverUrl = env['EDOT_SERVER_URL']?.trim() ?? '';
    if (serverUrl.isEmpty) {
      return const DemoConfigMissing(
        'EDOT_SERVER_URL is not set. Copy .env.example to .env and fill it in.',
      );
    }

    final samplingRaw = env['EDOT_SESSION_SAMPLING_RATE']?.trim() ?? '';
    final samplingRate = samplingRaw.isEmpty
        ? 1.0
        : double.tryParse(samplingRaw);
    if (samplingRate == null || samplingRate < 0.0 || samplingRate > 1.0) {
      return DemoConfigMissing(
        'EDOT_SESSION_SAMPLING_RATE must be a number from 0.0 to 1.0, '
        'got "$samplingRaw".',
      );
    }

    final token = env['EDOT_SECRET_TOKEN']?.trim() ?? '';

    return DemoConfigReady(
      EdotConfig(
        serviceName: _valueOr(env['EDOT_SERVICE_NAME'], _defaultServiceName),
        serviceVersion: _valueOr(
          env['EDOT_SERVICE_VERSION'],
          _defaultServiceVersion,
        ),
        deploymentEnvironment: _valueOr(
          env['EDOT_DEPLOYMENT_ENVIRONMENT'],
          _defaultEnvironment,
        ),
        serverUrl: serverUrl,
        auth: token.isEmpty
            ? const EdotAuth.none()
            : EdotAuth.secretToken(token),
        sessionSamplingRate: samplingRate,
        debug: debug,
        traceAllHttpTraffic: traceAllHttpTraffic,
        trackingConsent: trackingConsent,
      ),
    );
  }

  static String _valueOr(String? value, String fallback) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? fallback : trimmed;
  }
}
