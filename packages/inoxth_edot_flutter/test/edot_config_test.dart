import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
// The channel encoding is internal, so it is reached through src/ rather than
// being exported just to be testable.
import 'package:inoxth_edot_flutter/src/edot_config.dart' show encodeConfig;

void main() {
  EdotConfig validConfig({
    String serviceName = 'example-app',
    String serviceVersion = '1.2.3',
    String deploymentEnvironment = 'test',
    String serverUrl = 'http://localhost:4318',
  }) => EdotConfig(
    serviceName: serviceName,
    serviceVersion: serviceVersion,
    deploymentEnvironment: deploymentEnvironment,
    serverUrl: serverUrl,
    auth: const EdotAuth.apiKey('secret-key-value'),
  );

  group('service identity validation', () {
    // These three values travel as resource attributes in a comma-and-equals
    // delimited encoding, so a comma or equals sign in any of them corrupts the
    // whole resource, not just that one field.
    for (final field in [
      'serviceName',
      'serviceVersion',
      'deploymentEnvironment',
    ]) {
      for (final bad in ['', '   ', 'has,comma', 'has=equals']) {
        test('rejects $field = ${bad.isEmpty ? '(empty)' : '"$bad"'}', () {
          EdotConfig build() => switch (field) {
            'serviceName' => validConfig(serviceName: bad),
            'serviceVersion' => validConfig(serviceVersion: bad),
            _ => validConfig(deploymentEnvironment: bad),
          };

          expect(
            build,
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.name,
                'names the offending field',
                field,
              ),
            ),
          );
        });
      }
    }

    test('accepts values with dots, dashes and spaces', () {
      expect(
        () => validConfig(serviceName: 'my app-v2.1 (beta)'),
        returnsNormally,
      );
    });
  });

  group('serverUrl validation', () {
    for (final bad in ['', 'not a url', 'localhost:4318', '/v1/traces']) {
      test('rejects "$bad"', () {
        expect(
          () => validConfig(serverUrl: bad),
          throwsA(
            isA<ArgumentError>().having((e) => e.name, 'field', 'serverUrl'),
          ),
        );
      });
    }

    test(
      'exposes the collector host, which later tickets exclude from tracing',
      () {
        // ADR-0006 keys its exclusion off this host, so it is derived once here
        // rather than re-parsed at each call site.
        expect(
          validConfig(
            serverUrl: 'https://apm.example.com:443/v1/traces',
          ).collectorHost,
          'apm.example.com',
        );
      },
    );
  });

  group('serverUrl port', () {
    // The pinned iOS Agent falls back to its own hardcoded 8200 when the URL
    // string names no port, while Android resolves the scheme default. A portless
    // URL would therefore export to two different places, and the failure is
    // silent: telemetry simply never arrives on one platform.
    test('gains the scheme default when the URL names none', () {
      expect(
        validConfig(serverUrl: 'https://apm.example.com').serverUrl,
        'https://apm.example.com:443',
      );
      expect(
        validConfig(serverUrl: 'http://apm.example.com').serverUrl,
        'http://apm.example.com:80',
      );
    });

    test('keeps the port ahead of the path', () {
      expect(
        validConfig(serverUrl: 'https://apm.example.com/v1/traces').serverUrl,
        'https://apm.example.com:443/v1/traces',
      );
    });

    test('leaves a URL that already names a port untouched', () {
      expect(
        validConfig(serverUrl: 'http://localhost:4318').serverUrl,
        'http://localhost:4318',
      );
      // Including one that names the scheme default explicitly, which is already
      // unambiguous and must not gain a second port. `Uri.hasPort` is false here —
      // Dart normalises the default port away — so this is the case that catches
      // asking `Uri` instead of reading the string.
      expect(
        validConfig(serverUrl: 'https://apm.example.com:443/x').serverUrl,
        'https://apm.example.com:443/x',
      );
    });

    test('tells an IPv6 literal apart from a port', () {
      // A bracketed host is all colons, none of which is a port.
      expect(
        validConfig(serverUrl: 'http://[::1]/v1/traces').serverUrl,
        'http://[::1]:80/v1/traces',
      );
      expect(
        validConfig(serverUrl: 'http://[::1]:4318').serverUrl,
        'http://[::1]:4318',
      );
    });

    test('is what crosses the channel', () {
      // The normalisation is worthless if the Agent receives the original.
      expect(
        encodeConfig(
          validConfig(serverUrl: 'https://apm.example.com'),
        )['serverUrl'],
        'https://apm.example.com:443',
      );
    });

    test('does not change the collector host', () {
      expect(
        validConfig(serverUrl: 'https://apm.example.com').collectorHost,
        'apm.example.com',
      );
    });
  });

  group('credential safety', () {
    // A stack trace or debug dump containing an API key is a credential leak, so
    // redaction is asserted rather than assumed.
    test('toString redacts an API key', () {
      final text = validConfig().toString();

      expect(text, isNot(contains('secret-key-value')));
      expect(text, contains('redacted'));
    });

    test('toString redacts a secret token', () {
      final config = EdotConfig(
        serviceName: 'a',
        serviceVersion: '1',
        deploymentEnvironment: 'test',
        serverUrl: 'http://localhost:4318',
        auth: const EdotAuth.secretToken('token-value'),
      );

      expect(config.toString(), isNot(contains('token-value')));
    });

    test('toString tells unset propagation targets from none at all', () {
      // The two are opposites — every host, or no host — and both would print as a
      // number nobody could tell apart. This string is what a debug dump shows
      // someone asking why their traces stopped joining up.
      expect(validConfig().toString(), contains('all hosts'));
      expect(
        EdotConfig(
          serviceName: 'a',
          serviceVersion: '1',
          deploymentEnvironment: 'test',
          serverUrl: 'http://localhost:4318',
          tracePropagationTargets: const [],
        ).toString(),
        contains('0 pattern(s)'),
      );
    });

    // That the credential still reaches native is asserted in edot_span_test.dart
    // through the initialize channel call, so config encoding stays off the
    // public API rather than being exposed just to be testable.
  });

  group('sessionSamplingRate', () {
    for (final bad in [-0.1, 1.1, 2.0]) {
      test('rejects $bad', () {
        expect(
          () => EdotConfig(
            serviceName: 'a',
            serviceVersion: '1',
            deploymentEnvironment: 'test',
            serverUrl: 'http://localhost:4318',
            sessionSamplingRate: bad,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.name,
              'field',
              'sessionSamplingRate',
            ),
          ),
        );
      });
    }

    test('accepts the inclusive bounds', () {
      for (final rate in [0.0, 0.5, 1.0]) {
        expect(
          () => EdotConfig(
            serviceName: 'a',
            serviceVersion: '1',
            deploymentEnvironment: 'test',
            serverUrl: 'http://localhost:4318',
            sessionSamplingRate: rate,
          ),
          returnsNormally,
        );
      }
    });

    test('is unset by default, so the Agent applies its own default', () {
      // Not forced to 1.0 here: leaving it null means the native Agent picks,
      // which is what omitting it from the channel (below) relies on.
      final config = EdotConfig(
        serviceName: 'a',
        serviceVersion: '1',
        deploymentEnvironment: 'test',
        serverUrl: 'http://localhost:4318',
      );

      expect(config.sessionSamplingRate, isNull);
    });
  });
}
