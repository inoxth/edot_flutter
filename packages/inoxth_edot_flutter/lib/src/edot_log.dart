import 'package:flutter/foundation.dart';

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
