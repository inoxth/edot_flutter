import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Name of the single [MethodChannel] between the Plugin and the Agent.
///
/// There is exactly one channel by design: under ADR-0002 the Agent is
/// authoritative and every signal crosses this one boundary, which is also the
/// seam the Dart test tier asserts against.
///
/// Exposed so tests can install a mock handler without reaching into `src/`.
const String edotChannelName = 'inoxth_edot_flutter';

/// The channel itself. Internal — callers use the Plugin's public API.
const MethodChannel edotChannel = MethodChannel(edotChannelName);

/// Whether the Plugin's own diagnostics are printed.
bool debugLoggingEnabled = false;

/// Emits a Plugin diagnostic.
///
/// Callers must never pass a credential. Configuration is logged through
/// `EdotConfig.toString`, which redacts.
void edotLog(String message) {
  if (!debugLoggingEnabled) return;
  debugPrint('[edot] $message');
}

/// Sends a fire-and-forget call to the Agent.
///
/// Span start and end must not await the Agent (ADR-0002), so failures cannot be
/// surfaced to the caller. They are reported through [edotLog] rather than
/// swallowed: dropping telemetry silently is indistinguishable from a quiet app,
/// but throwing would crash a host app over a telemetry fault.
void sendOneWay(String method, Map<String, Object?> arguments) {
  unawaited(
    edotChannel.invokeMethod<void>(method, arguments).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      edotLog('channel call "$method" failed: $error');
    }),
  );
}
