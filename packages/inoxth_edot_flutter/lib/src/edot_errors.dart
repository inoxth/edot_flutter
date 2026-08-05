import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'edot.dart';
import 'edot_channel.dart';
import 'edot_signals.dart';

/// Where a Dart Error came from, reaching `error.source`.
///
/// The values are named after the runtime that raised the error, following this
/// organisation's React Native SDK, whose sources are `js_uncaught` and
/// `js_promise_rejection`. The names differ because the runtimes do — a framework
/// build failure has no JavaScript equivalent — but the shape is the same, so one
/// dashboard can group both fleets' errors by origin.
enum EdotErrorSource {
  /// The Flutter framework: a build, layout or paint failure.
  flutterFramework('flutter_framework'),

  /// An uncaught asynchronous error, reaching `PlatformDispatcher.onError`.
  dartUncaught('dart_uncaught'),

  /// An error delivered by an isolate's error listener.
  dartIsolate('dart_isolate'),

  /// Reported by the app itself, for an error it caught and handled.
  dartReported('dart_reported');

  const EdotErrorSource(this.wireValue);

  /// Value of `error.source`.
  final String wireValue;
}

/// Records a Dart Error as a non-fatal event.
///
/// One log record carrying the ADR-0003 error vocabulary, at `error` severity — never
/// `fatal`, and never through the Agent's crash reporting. A Dart Error is routinely
/// recoverable, and counting a layout overflow towards crash-free rate would make the
/// one metric mobile teams alert on untrustworthy (ADR-0008). The Active View comes
/// along, added by [Edot.log].
///
/// When an operation is in flight the exception is recorded against its span as well,
/// and the span takes error status — so the failure is visible on the operation rather
/// than only in a log nobody correlated.
///
/// [type] overrides `exception.type` for a source that knows the type better than
/// `error.runtimeType` does — which is only the isolate source, where the type did not
/// survive the boundary.
///
/// Never throws. This runs from inside the framework's own error handlers, where a throw
/// of its own would replace the error the app was trying to report — so a failure here is
/// logged and swallowed, which is the one place that trade is right.
void captureError(
  Object error,
  StackTrace? stackTrace,
  EdotErrorSource source, {
  String? context,
  String? type,
}) {
  try {
    final message = error.toString();

    Edot.log(
      EdotSeverity.error,
      message,
      attributes: <String, Object>{
        // Fleet Alignment: the React Native SDK sets this on every error record, and
        // a dashboard that filters on it would not see this fleet's errors without it.
        'event.name': 'exception',
        'exception.type': type ?? error.runtimeType.toString(),
        'exception.message': message,
        'exception.stacktrace': (stackTrace ?? StackTrace.current).toString(),
        'error.source': source.wireValue,
        // Only when the framework gave one — "while building MyWidget" is the most
        // useful line in a Flutter error and belongs nowhere else.
        'error.context': ?context,
      },
    );

    // The operation the error happened inside, if the app established one. Nothing
    // else can be inferred: a span that merely started most recently is not the one
    // this error belongs to (see EdotTracer.startSpan).
    //
    // No check for an already-ended span: an ambient parent outlives its own `end`,
    // and EdotSpan drops both of these calls once ended.
    final span = Edot.tracer.ambientParent;
    if (span != null) {
      span.recordException(error, stackTrace: stackTrace, type: type);
      span.markFailed(type ?? error.runtimeType.toString());
    }
  } catch (failure) {
    edotLog('failed to capture an error: $failure');
  }
}

/// Decodes what an isolate error listener delivers.
///
/// The payload is a two-element list of *strings* — the error and the stack trace,
/// already formatted, because neither can cross an isolate boundary as an object. So the
/// whole formatted error becomes the message, which is what the listener actually knows.
///
/// `exception.type` is [isolateExceptionType] rather than the type of what arrived. What
/// arrived is a `String`, and reporting that would put `String` on every isolate error
/// in Kibana — a plausible-looking value that is never the truth.
void captureIsolateError(List<Object?> pair) {
  final error = pair.isNotEmpty ? pair.first : null;
  final stack = pair.length > 1 ? pair[1] : null;

  captureError(
    error ?? 'an isolate reported an error with no message',
    stack is String ? StackTrace.fromString(stack) : null,
    EdotErrorSource.dartIsolate,
    type: isolateExceptionType,
  );
}

/// `exception.type` for an error whose Dart type did not survive an isolate boundary.
const String isolateExceptionType = 'IsolateError';

/// Handlers replaced at install, so [uninstallErrorHandlers] can put them back and so
/// each one can chain to what was there.
FlutterExceptionHandler? _previousFlutterOnError;
ErrorCallback? _previousPlatformOnError;

/// The handlers this library installed, kept so [uninstallErrorHandlers] can tell whether
/// they are still the ones in force.
FlutterExceptionHandler? _installedFlutterOnError;
ErrorCallback? _installedPlatformOnError;

RawReceivePort? _isolateErrorPort;
bool _installed = false;

/// The port an isolate reports its errors to.
///
/// Pass it to `Isolate.spawn`'s `onError` to have a spawned isolate's uncaught errors
/// captured — a spawned isolate reports only to the ports its spawner gave it, so there
/// is no way for the Plugin to find them on its own. Errors from `Isolate.run` and
/// `compute` need nothing: they come back as a failed future and are captured as
/// uncaught async errors.
///
/// Deliberately not registered on the current isolate as well. The current isolate's own
/// uncaught errors already arrive at `PlatformDispatcher.onError`, so listening for them
/// here would record some of them twice — once as `dart_uncaught` and again as
/// `dart_isolate` — and a duplicated error record is worse than a missing one, because
/// nothing about either copy looks wrong.
///
/// Null before `Edot.start`.
SendPort? get isolateErrorPort => _isolateErrorPort?.sendPort;

/// Installs the handlers ADR-0008 calls for, chaining to what is already there, and
/// opens the port a spawned isolate can report to.
///
/// Chaining is the point. An app that already reports to Crashlytics or Sentry keeps
/// reporting to it; adding this Plugin must not silently take an incumbent's errors
/// away, which is the kind of breakage nobody notices until an incident.
void installErrorHandlers() {
  if (_installed) return;
  _installed = true;

  _previousFlutterOnError = FlutterError.onError;
  _installedFlutterOnError = (details) {
    captureError(
      details.exception,
      details.stack,
      EdotErrorSource.flutterFramework,
      context: details.context?.toString(),
    );

    // Whatever was here before, which by default prints the error to the console.
    // Replacing that silently would make the Plugin the reason a developer stopped
    // seeing errors in their terminal.
    _previousFlutterOnError?.call(details);
  };
  FlutterError.onError = _installedFlutterOnError;

  _previousPlatformOnError = PlatformDispatcher.instance.onError;
  _installedPlatformOnError = (error, stack) {
    captureError(error, stack, EdotErrorSource.dartUncaught);

    // The return value decides whether the runtime still treats the error as
    // unhandled. Answering for the previous handler, or false when there was none,
    // leaves that decision exactly where it was — capturing an error must not change
    // whether the app survives it.
    return _previousPlatformOnError?.call(error, stack) ?? false;
  };
  PlatformDispatcher.instance.onError = _installedPlatformOnError;

  _isolateErrorPort = RawReceivePort((dynamic message) {
    if (message is List<Object?>) captureIsolateError(message);
  });
}

/// Restores the handlers that were in place before [installErrorHandlers].
///
/// Each one only when ours is still the one in force. An app that registered its own
/// afterwards — chaining onto ours, exactly as this does — owns the handler now, and
/// restoring over it would silently take that app's error reporting away to tidy up ours.
void uninstallErrorHandlers() {
  if (!_installed) return;
  _installed = false;

  if (FlutterError.onError == _installedFlutterOnError) {
    FlutterError.onError = _previousFlutterOnError;
  }
  if (PlatformDispatcher.instance.onError == _installedPlatformOnError) {
    PlatformDispatcher.instance.onError = _previousPlatformOnError;
  }

  _isolateErrorPort?.close();

  _previousFlutterOnError = null;
  _previousPlatformOnError = null;
  _installedFlutterOnError = null;
  _installedPlatformOnError = null;
  _isolateErrorPort = null;
}
