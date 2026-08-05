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
      _logChannelFailure(method, error);
    }),
  );
}

/// Asks the Agent for a map of strings and waits for it.
///
/// The exception ADR-0002 allows to [sendOneWay]: some answers only the Agent has,
/// and Trace Context is one — it is built from the real trace and span ids, which
/// live on the Agent's side of the channel.
///
/// A failure, or a reply that is not a map of strings, yields an empty map. Callers
/// use this on the path of a request the app is about to make, and no telemetry
/// fault is worth failing that request over.
Future<Map<String, String>> fetchStringMap(
  String method,
  Map<String, Object?> arguments,
) async {
  try {
    final reply = await edotChannel.invokeMapMethod<String, String>(
      method,
      arguments,
    );
    if (reply == null) return const {};

    // Copied rather than returned as it arrives: `invokeMapMethod` casts lazily, so
    // a value that is not a string would throw at the caller's first read — past
    // this try, and on the path of their request. Copying moves that failure here,
    // where it is logged and answered with nothing.
    return Map<String, String>.of(reply);
  } catch (error) {
    _logChannelFailure(method, error);
    return const {};
  }
}

/// Asks the Agent for a single string and waits for it.
///
/// Null when the Agent has no answer, when the call fails, or when the reply is not
/// a string. The caller decides what an absent answer means, because the two reasons
/// for one are different: a platform that cannot answer at all, and a call that went
/// wrong. Both are logged here; neither throws, for the same reason [sendOneWay]
/// does not.
Future<String?> fetchString(String method) async {
  try {
    return await edotChannel.invokeMethod<String>(method);
  } catch (error) {
    _logChannelFailure(method, error);
    return null;
  }
}

/// Reports a failed call, in one wording.
///
/// Shared by all three callers so the phrasing they are searched by stays one thing.
/// What differs between them is what they answer the caller with, not how they say a
/// call went wrong.
void _logChannelFailure(String method, Object error) =>
    edotLog('channel call "$method" failed: $error');
