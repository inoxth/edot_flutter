import 'dart:collection';

import 'edot_consent.dart';
import 'edot_log.dart';

/// Decides what may cross the channel: the Tracking Consent gate, and the queue for
/// telemetry produced before the Agent was ready.
///
/// Both live here because they are one decision with three answers — emit, hold, or
/// discard — and splitting them would let a caller consult one without the other.
/// The rules, in order:
///
/// 1. **Tracking Consent is not granted** — discard. Never held for later: telemetry
///    produced while the user was refusing is not made acceptable by a later yes.
/// 2. **The Agent is not ready yet** — hold, oldest dropped first under pressure.
/// 3. **Otherwise** — emit.
///
/// The gate is in Dart rather than native, which is a deliberate divergence from the
/// React Native SDK: it passes consent across its bridge and drops on the far side.
/// Refusing here means refused telemetry never reaches the platform boundary at all,
/// which is both stronger and what makes the Seam 1 tier able to assert it.

/// How many emissions are held while the Agent starts.
///
/// Bounded because an app that never starts the Agent — one that fails during
/// initialisation, say — would otherwise grow this queue for its whole lifetime. A
/// hundred covers the startup burst an app actually produces while leaving the cost
/// of the pathological case bounded and small.
const int emissionBufferLimit = 100;

/// Attribute naming how many held emissions the buffer had to drop.
///
/// Prefixed `edot.` because it describes the Plugin's own behaviour rather than the
/// app's — it is not part of the Elastic Mobile Attribute Set (ADR-0003), and reading
/// it as app telemetry would be a mistake.
const String droppedBeforeStartAttribute = 'edot.buffer.dropped';

/// One held emission, kept whole so replay is a re-send rather than a reconstruction.
class BufferedEmission {
  /// Holds a channel call — its [method] and [arguments] — for later replay.
  const BufferedEmission(this.method, this.arguments);

  /// The channel method name that was held.
  final String method;

  /// The channel arguments that were held, replayed verbatim.
  final Map<String, Object?> arguments;
}

EdotTrackingConsent _consent = EdotTrackingConsent.granted;
bool _agentReady = false;
final Queue<BufferedEmission> _buffer = Queue<BufferedEmission>();
int _dropped = 0;

/// The current Tracking Consent.
EdotTrackingConsent get trackingConsent => _consent;

/// Records the user's Tracking Consent, taking effect on the very next emission.
///
/// Withdrawing consent does not retract telemetry already exported — that has left
/// the device and the Plugin has no way to recall it. It stops everything after.
void setTrackingConsent(EdotTrackingConsent consent) {
  if (consent == _consent) return;

  _consent = consent;
  edotLog('tracking consent is now ${consent.wireValue}');

  // Held telemetry is discarded the moment consent stops allowing it, rather than
  // waiting to be refused at replay. Keeping it would mean a refusal left the data
  // sitting in memory, which is not what a user who declined would expect.
  if (!consent.allowsEmission && _buffer.isNotEmpty) {
    edotLog('discarding ${_buffer.length} held emission(s): consent withdrawn');
    _discardBuffer();
  }
}

/// Whether [method] may go on the channel now.
///
/// False means the caller must not send. It has already been held or discarded here,
/// so there is nothing further for the caller to decide.
bool admitEmission(String method, Map<String, Object?> arguments) {
  if (!_consent.allowsEmission) {
    edotLog('$method suppressed: tracking consent is ${_consent.wireValue}');
    return false;
  }

  if (_agentReady) return true;

  _hold(method, arguments);
  return false;
}

void _hold(String method, Map<String, Object?> arguments) {
  // Oldest first, per ADR-0005. A startup burst that overflows loses its beginning,
  // which is preferred to unbounded growth and is reported rather than silent.
  if (_buffer.length >= emissionBufferLimit) {
    _buffer.removeFirst();
    _dropped++;
  }

  _buffer.add(BufferedEmission(method, arguments));
}

/// Hands back everything held, in the order it was produced, and opens the gate.
///
/// Call once the Agent can receive telemetry. Emissions after this go straight out.
///
/// Deliberately does **not** re-check consent. The buffer can only ever hold
/// telemetry that consent allowed: [admitEmission] discards rather than holds while
/// consent withholds emission, and [setTrackingConsent] empties the buffer the moment
/// it stops allowing it. A check here would be unreachable — and an unreachable guard
/// on a privacy rule is worse than none, because it suggests the rule is enforced here
/// when in fact it is enforced in those two places.
Iterable<BufferedEmission> releaseBufferedEmissions() {
  _agentReady = true;

  if (_buffer.isNotEmpty) {
    edotLog('replaying ${_buffer.length} emission(s) held before start');
  }

  // Drained rather than copied-then-cleared, so emptying the buffer is not a separate
  // step that could be forgotten: taking an entry is what removes it.
  final released = <BufferedEmission>[];
  while (_buffer.isNotEmpty) {
    released.add(_buffer.removeFirst());
  }

  return released;
}

/// How many emissions the buffer dropped because it was full.
///
/// Read after [releaseBufferedEmissions] so the loss can be reported as telemetry in
/// its own right — a count that is never read would make the bound invisible, and an
/// invisible bound is indistinguishable from a quiet app (ADR-0005).
int get droppedEmissionCount => _dropped;

/// Forgets the dropped count, once it has been reported.
void clearDroppedEmissionCount() => _dropped = 0;

void _discardBuffer() {
  _buffer.clear();
  // The count goes too. It exists to report loss the Plugin caused by its own bound,
  // and telemetry discarded because the user said no is not that.
  _dropped = 0;
}

/// Clears the gate between tests, and for `Edot.resetForTesting`.
void resetEmissionGate() {
  _consent = EdotTrackingConsent.granted;
  _agentReady = false;
  _buffer.clear();
  _dropped = 0;
}
