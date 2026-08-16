import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter_example_shared/inoxth_edot_flutter_example_shared.dart';

/// Seam 1 for the shared env-file -> config transform.
///
/// `DemoConfig.fromEnv` is the one piece of demo logic worth proving hermetically:
/// every flavor app builds its `EdotConfig` through it, so the mapping, the
/// credential handling and the missing-config guard are asserted here rather than
/// discovered on a device.
void main() {
  Map<String, String> fullEnv() => {
    'EDOT_SERVER_URL': 'https://collector.example.com:4318',
    'EDOT_SERVICE_NAME': 'demo-service',
    'EDOT_SERVICE_VERSION': '2.3.4',
    'EDOT_DEPLOYMENT_ENVIRONMENT': 'staging',
    'EDOT_SECRET_TOKEN': 'super-secret',
  };

  test('maps every env-file field onto the EdotConfig', () {
    final result = DemoConfig.fromEnv(fullEnv());

    expect(result, isA<DemoConfigReady>());
    final config = (result as DemoConfigReady).config;
    expect(config.serviceName, 'demo-service');
    expect(config.serviceVersion, '2.3.4');
    expect(config.deploymentEnvironment, 'staging');
    // The plugin stores an explicit port; the host is what matters here.
    expect(config.serverUrl, startsWith('https://collector.example.com'));
  });

  test('a non-empty secret token becomes secret-token auth', () {
    final result = DemoConfig.fromEnv(fullEnv()) as DemoConfigReady;

    expect(result.config.auth, isA<EdotSecretTokenAuth>());
    expect((result.config.auth as EdotSecretTokenAuth).token, 'super-secret');
  });

  test('an absent or blank secret token becomes no auth', () {
    for (final token in <String?>[null, '', '   ']) {
      final env = fullEnv();
      if (token == null) {
        env.remove('EDOT_SECRET_TOKEN');
      } else {
        env['EDOT_SECRET_TOKEN'] = token;
      }

      final result = DemoConfig.fromEnv(env) as DemoConfigReady;
      expect(
        result.config.auth,
        isA<EdotNoAuth>(),
        reason: 'token=${token ?? 'absent'}',
      );
    }
  });

  test('a missing server URL is reported as missing config, not thrown', () {
    final env = fullEnv()..remove('EDOT_SERVER_URL');

    expect(DemoConfig.fromEnv(env), isA<DemoConfigMissing>());
  });

  test('a blank server URL is reported as missing config', () {
    final env = fullEnv()..['EDOT_SERVER_URL'] = '   ';

    expect(DemoConfig.fromEnv(env), isA<DemoConfigMissing>());
  });

  test('the identity fields fall back to demo defaults when unset', () {
    final result =
        DemoConfig.fromEnv({'EDOT_SERVER_URL': 'http://localhost:4318'})
            as DemoConfigReady;

    expect(result.config.serviceName, isNotEmpty);
    expect(result.config.serviceVersion, isNotEmpty);
    expect(result.config.deploymentEnvironment, isNotEmpty);
    expect(result.config.auth, isA<EdotNoAuth>());
  });

  test('the session sampling rate is parsed from the env onto the config', () {
    final env = fullEnv()..['EDOT_SESSION_SAMPLING_RATE'] = '0.25';

    final result = DemoConfig.fromEnv(env) as DemoConfigReady;

    expect(result.config.sessionSamplingRate, 0.25);
  });

  test(
    'an absent session sampling rate defaults to reporting every session',
    () {
      final result = DemoConfig.fromEnv(fullEnv()) as DemoConfigReady;

      expect(result.config.sessionSamplingRate, 1.0);
    },
  );

  test(
    'a sampling rate that is out of range or not a number is missing config',
    () {
      for (final bad in ['2', '-0.5', 'abc']) {
        final env = fullEnv()..['EDOT_SESSION_SAMPLING_RATE'] = bad;

        expect(DemoConfig.fromEnv(env), isA<DemoConfigMissing>(), reason: bad);
      }
    },
  );

  test('the export protocol is parsed from the env, case-insensitively', () {
    for (final entry in {
      'grpc': ExportProtocol.grpc,
      'GRPC': ExportProtocol.grpc,
      'http': ExportProtocol.http,
    }.entries) {
      final env = fullEnv()..['EDOT_EXPORT_PROTOCOL'] = entry.key;

      final result = DemoConfig.fromEnv(env) as DemoConfigReady;

      expect(result.config.exportProtocol, entry.value, reason: entry.key);
    }
  });

  test('an absent export protocol defaults to http', () {
    final result = DemoConfig.fromEnv(fullEnv()) as DemoConfigReady;

    expect(result.config.exportProtocol, ExportProtocol.http);
  });

  test('an unrecognised export protocol is reported as missing config', () {
    final env = fullEnv()..['EDOT_EXPORT_PROTOCOL'] = 'quic';

    expect(DemoConfig.fromEnv(env), isA<DemoConfigMissing>());
  });

  test('behaviour flags are threaded through onto the config', () {
    final result =
        DemoConfig.fromEnv(
              fullEnv(),
              debug: true,
              traceAllHttpTraffic: true,
              trackingConsent: EdotTrackingConsent.pending,
            )
            as DemoConfigReady;

    expect(result.config.debug, isTrue);
    expect(result.config.traceAllHttpTraffic, isTrue);
    expect(result.config.trackingConsent, EdotTrackingConsent.pending);
  });
}
