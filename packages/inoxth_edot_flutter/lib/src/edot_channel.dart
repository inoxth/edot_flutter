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
///
/// Span, log and metric plumbing lands on this in the tracer-bullet ticket. For
/// now it exists so both native implementations have a registered channel to
/// attach to, proving the wiring before any telemetry behaviour depends on it.
const MethodChannel edotChannel = MethodChannel(edotChannelName);
