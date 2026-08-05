# The Tracking Consent gate is applied in Dart, not by the Agent

Status: accepted

## Context

Telemetry must not be emitted until the user has permitted it. The state is three-valued —
granted, not granted, pending — so an unresolved consent flow is representable rather than
being forced to look like a refusal.

Neither pinned Agent has a consent API. `co.elastic.otel.android:agent-sdk` 1.1.0 and
`apm-agent-ios` 1.2.1 both export whatever they are given, so the gate has to be built rather
than configured.

This organisation's React Native SDK built it **natively**: `EdotReactNativeModuleImpl` holds a
`TrackingConsent` enum, `setTrackingConsent` writes it, and each emitting method consults
`emissionAllowed()` before touching the Agent. Telemetry crosses its bridge and is dropped on
the far side. Its default is `GRANTED`, and its wire values are `granted`, `not_granted` and
`pending`.

Under ADR-0002 every signal this Plugin produces crosses one channel through one function, so
there is a place in Dart where the same rule could be applied once.

## Decision

Apply the gate in **Dart**, at the single channel chokepoint, and keep the React Native SDK's
vocabulary and default.

- Three states with the same wire values, so the two fleets describe consent identically.
- Default **granted**, matching the React Native SDK. An app with a stricter obligation starts
  at `pending` and grants when the user answers.
- Refused telemetry is **discarded, not held**. Nothing is queued for a later yes.

Telemetry produced before the Agent is ready is a separate rule that shares this gate, per
ADR-0005: it is held in a bounded queue and replayed. The two interact in one direction only —
what consent refuses is never held, and what is held is discarded the moment consent stops
allowing it.

## Considered options

- **Gate natively, as the React Native SDK does.** Rejected. It is weaker for the same
  outcome: refused telemetry would reach the platform boundary before being dropped, and the
  Dart tier could then only assert that no *export* happened, not that nothing was handed over.
  The stronger promise — refused telemetry never leaves Dart — is also the cheaper one here,
  because ADR-0002 already funnels every signal through one function.
- **Gate in both places.** Rejected as an unreachable second guard. Nothing can reach the
  natives except through the channel the Dart gate sits on, so the native half could never
  fire, and a privacy rule that appears to be enforced in two places but is enforced in one is
  worse documentation than a single honest one.
- **Send the consent state to the Agents anyway, for symmetry with the React Native SDK's wire
  protocol.** Rejected. Neither native side reads it, and a key that is transmitted but unread
  implies an enforcement point that does not exist.
- **Default to `pending`, so no app can emit before asking.** Rejected, with reluctance. It is
  the safer default and it would break Fleet Alignment: the same app built on the two SDKs
  would emit different telemetry from the same configuration. The default is documented at the
  call site instead, together with what to set for an app that must not emit before asking.
- **Refuse to initialise the Agent while consent is withheld.** Rejected. Granting consent
  would then need a restart to take effect, and consent would become indistinguishable from
  `disableAgent`, which is a developer's switch rather than a user's answer.

## Consequences

- **The gate covers every signal by construction**, including ones added later: a new signal
  reaches the Agent through the same function or not at all. This is the main reason the
  placement is worth writing down — it is what makes the rule hold without being re-applied.
- **Emission is asserted at the channel.** "No telemetry crossed" is the testable statement,
  and it is stronger than "nothing was exported".
- **Withdrawing consent cannot retract telemetry already exported.** It has left the device and
  the Plugin has no way to reach it; deleting it is a matter for whoever administers the
  cluster. The API documents this rather than implying a recall it cannot perform.
- **A future Agent with its own consent API would make this redundant.** If either pin gains
  one, prefer it and supersede this ADR — the Agent can gate its own instrumentation, which
  this cannot: telemetry the Agent collects on its own (native crashes on iOS, lifecycle
  events) is not produced through the channel and so is **not covered by this gate**. An app
  under a strict obligation should use `disableAgent` until consent is resolved, and this
  limitation is documented for integrators.
- The Plugin diverges from the React Native SDK in *where* the rule lives while matching it in
  what an integrator writes and what the telemetry looks like. That is the intended trade: the
  API surface and vocabulary are aligned, the enforcement is stronger.
