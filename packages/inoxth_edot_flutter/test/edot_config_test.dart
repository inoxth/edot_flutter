import 'package:flutter_test/flutter_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

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
  });
}
