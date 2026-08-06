import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:edot_collector_harness/edot_collector_harness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

import 'agent_export.dart';
import 'error_contract.dart';

/// Seam 2, device half — captures one Dart Error from each source.
///
/// Assertions live in the host half: `tool/verify_error.dart`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Dart Errors reach the collector as error records', (
    tester,
  ) async {
    if (!Platform.isAndroid) {
      fail(
        'This suite runs on Android only. flush() drains log records on Android but '
        'not on iOS (ADR-0011), so an iOS run would be asserting on the Agent\'s own '
        'export timers rather than on the Plugin.',
      );
    }

    await Edot.start(
      EdotConfig(
        serviceName: 'edot-flutter-seam2',
        serviceVersion: '0.0.1',
        deploymentEnvironment: 'integration-test',
        serverUrl: CollectorProcess.androidEmulatorEndpoint,
        debug: true,
        android: const EdotAndroidConfig(diskBufferingEnabled: false),
      ),
    );

    Edot.setActiveView(activeView);

    // The isolate goes first: its error arrives on a port asynchronously, so it needs
    // the longest to settle before the flush.
    await _captureFromAnIsolate();

    await _captureFromTheFramework(tester);
    _captureUncaughtAsync();
    _captureReported();
    _captureInsideAnOperation();

    await flushUntilAssertable();
  });
}

/// A build failure inside an error boundary.
///
/// The framework routes it through its own error reporting, which the Plugin has taken
/// over — so this is the framework source arriving the way an app would produce it,
/// rather than a handler called by hand. The boundary is here too: a failing subtree
/// must render its fallback, which is only observable on a device.
Future<void> _captureFromTheFramework(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: EdotErrorBoundary(
        fallback: (error) => const Text(fallbackText),
        child: Builder(builder: (_) => throw StateError(frameworkMarker)),
      ),
    ),
  );

  expect(find.text(fallbackText), findsOneWidget);

  // The framework recorded the exception it caught; taking it here is what says the
  // failure was accounted for rather than swallowed.
  expect(tester.takeException(), isStateError);
}

/// An uncaught asynchronous error, delivered exactly as the engine delivers one.
///
/// Not by leaving a future unawaited: the test framework runs the body inside a guarded
/// zone, which would take the error before `PlatformDispatcher.onError` ever saw it and
/// fail the test. Calling the handler the Plugin installed is the same entry point the
/// engine uses, without the harness in the way.
void _captureUncaughtAsync() {
  final handler = PlatformDispatcher.instance.onError;
  if (handler == null) {
    fail('Edot.start did not install an uncaught-error handler');
  }

  handler(
    const FormatException(uncaughtMarker),
    StackTrace.fromString('#0 seam2 async gap'),
  );
}

/// An error the app caught and chose to report.
void _captureReported() => Edot.reportError(
  ArgumentError(reportedMarker),
  stackTrace: StackTrace.current,
);

/// An error inside an operation, which must arrive on the span as well as in a record.
void _captureInsideAnOperation() {
  final span = Edot.tracer.startSpan(failingOperationName);

  Edot.tracer.runWithParent(
    span,
    () => Edot.reportError(UnsupportedError(operationMarker)),
  );

  span.end();
}

/// A real isolate, failing for real.
///
/// A spawned isolate reports only to the ports its spawner gave it, so
/// [Edot.isolateErrorPort] has to be handed over explicitly — there is no way for the
/// Plugin to find a spawned isolate on its own. Waiting on the exit port and then
/// settling briefly is what keeps the flush from racing the error's delivery.
Future<void> _captureFromAnIsolate() async {
  final port = Edot.isolateErrorPort;
  if (port == null) {
    fail('Edot.start did not register an isolate error listener');
  }

  final exited = ReceivePort();
  await Isolate.spawn(
    _failInAnIsolate,
    null,
    onError: port,
    onExit: exited.sendPort,
    errorsAreFatal: true,
  );

  await exited.first;
  exited.close();

  // The error and the exit are delivered on separate ports with no ordering between
  // them, so the record may still be in flight when the isolate is already gone.
  await Future<void>.delayed(const Duration(milliseconds: 500));
}

void _failInAnIsolate(void _) => throw StateError(isolateMarker);
