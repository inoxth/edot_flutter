import 'dart:io';

import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

import 'agent_export.dart';
import 'trace_context_contract.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final endpoint = Platform.isAndroid
      ? CollectorProcess.androidEmulatorEndpoint
      : CollectorProcess.hostEndpoint;

  testWidgets('Trace Context reaches the service', (tester) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final received = <String>[];
      request.headers.forEach((name, _) => received.add(name.toLowerCase()));

      // Set before the span ends: enrichment after the end is dropped, by design.
      Edot.tracer.startSpan(downstreamSpanName)
        ..setString(requestedPathAttribute, request.uri.path)
        ..setString(receivedHeadersAttribute, received.join(','))
        ..setString(
          receivedTraceparentAttribute,
          request.headers.value('traceparent') ?? absentHeader,
        )
        ..end();

      const body = '{"ok":true}';
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
        tracePropagationTargets: [propagationTarget],
      ),
    );

    final client = EdotHttpClient(http.Client());

    // Matched by the target list: the service must receive Trace Context naming the
    // span this request produced.
    await client.get(Uri.parse('$origin$propagatedPath'));

    // Traced, not a target: a span, and no header.
    await client.get(Uri.parse('$origin$plainPath'));

    // Excluded: performed, no span, so nothing to propagate either.
    await client.get(Uri.parse('$origin$excludedPath'));

    // The Collector Host, excluded at any path (ADR-0006).
    try {
      await client.get(Uri.parse('$endpoint$collectorPath'));
    } on Exception {
      // Whether the collector answers a GET is beside the point; the absent span is.
    }

    await flushUntilAssertable();

    client.close();
    await server.close(force: true);
  });
}
