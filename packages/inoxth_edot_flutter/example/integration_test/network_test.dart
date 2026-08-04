import 'dart:io';

import 'package:dio/dio.dart';
import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter_dio/inoxth_edot_flutter_dio.dart';

import 'network_contract.dart';

/// Seam 2, device half — makes real requests through both traced integrations.
///
/// A server on the device's own loopback rather than a public host: it makes the
/// status codes and body sizes deterministic, and it keeps the suite runnable with
/// no network beyond the collector.
///
/// Assertions live in the host half: `tool/verify_network.dart`.
const _iosPersistenceUploadWindow = Duration(seconds: 15);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final endpoint = Platform.isAndroid
      ? CollectorProcess.androidEmulatorEndpoint
      : CollectorProcess.hostEndpoint;

  testWidgets('network spans survive export', (tester) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final failing =
          request.uri.path == failingPath || request.uri.path == dioFailingPath;

      final body = failing ? '{"error":"boom"}' : '{"id":42}';

      request.response.statusCode = failing ? 500 : 200;
      // Declared, not chunked: `http.response_body.size` is the Content-Length the
      // response announced, and a chunked response announces none.
      request.response.headers.contentLength = body.length;
      request.response.write(body);
      await request.response.close();
    });
    final origin =
        'http://${InternetAddress.loopbackIPv4.address}:${server.port}';

    await Edot.start(
      EdotConfig(
        serviceName: 'edot-flutter-seam2',
        serviceVersion: '0.0.1',
        deploymentEnvironment: 'integration-test',
        serverUrl: endpoint,
        debug: true,
        android: const EdotAndroidConfig(diskBufferingEnabled: false),
        excludedUrls: [excludedPath],
        urlSanitizer: (url) =>
            url.replaceAll(RegExp(r'/orders/\d+'), sanitizedTarget),
      ),
    );

    Edot.setActiveView(screenName);

    Edot.tracer.startSpan(controlSpanName)
      ..setString(platformAttribute, Platform.operatingSystem)
      ..end();

    final client = EdotHttpClient(http.Client());

    // Traced: the query string must not survive, and the hook must collapse the id.
    await client.get(Uri.parse('$origin$tracedPath?token=$secretQueryValue'));

    // A failure the server reported.
    await client.get(Uri.parse('$origin$failingPath'));

    // Inside an ambient parent, so the Agent has no root to adopt.
    final ambientParent = Edot.tracer.startSpan(ambientParentSpanName);
    await Edot.tracer.runWithParent(
      ambientParent,
      () => client.get(Uri.parse('$origin$parentedPath')),
    );
    ambientParent.end();

    // Excluded by configuration: performed, never traced.
    await client.get(Uri.parse('$origin$excludedPath'));

    // The Collector Host, which is excluded at any path (ADR-0006).
    try {
      await client.get(Uri.parse('$endpoint$collectorPath'));
    } on Exception {
      // Whether the collector answers a GET is beside the point; the span is what
      // matters, and there must not be one.
    }

    // A transport failure: nothing is listening on port 1.
    try {
      await client.get(Uri.parse('http://127.0.0.1:1$unreachablePath'));
    } on Exception {
      // Expected. The span records why.
    }

    // The Dio integration, through the same server. Its own instance, because an
    // interceptor is added to a Dio rather than wrapping a client.
    final dio = Dio()..interceptors.add(EdotDioInterceptor());

    await dio.get<dynamic>('$origin$dioPath');

    try {
      await dio.get<dynamic>('$origin$dioFailingPath');
    } on DioException {
      // Expected: Dio raises a 500 rather than returning it. That difference is the
      // point of the assertion in the host half.
    }

    await Edot.flush();

    if (Platform.isIOS) {
      // ADR-0011: flush cannot force the iOS persistence worker to upload.
      await Future<void>.delayed(_iosPersistenceUploadWindow);
    }

    client.close();
    await server.close(force: true);
  });
}
