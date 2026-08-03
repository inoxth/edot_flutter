# Native crash reporting: opt-out on iOS, unavailable on Android

Status: accepted

## Context

Native crash capture installs process-wide handlers: `PLCrashReporter` signal and Mach exception
handlers on iOS, a default uncaught-exception handler on Android. Crashlytics and Sentry install their
own, and for signal-based crashes whoever installs last tends to win — so enabling this can silently
stop an app's existing reporter from working.

On Android, EDOT discovers instrumentations with `ServiceLoader.load(Instrumentation::class.java)` and
installs everything it finds, with no filter. Both `InstrumentationManager` and the `Instrumentation`
interface are marked "internal and is hence not for public use. Its APIs are unstable." So classpath
presence *is* the switch — there is no runtime opt-out.

The safest design would be off-by-default on both platforms. But the organisation's React Native SDK
ships no Android crash library at all and leaves iOS at the Agent's default, which is on.

## Decision

Mirror the React Native SDK, accepting asymmetry, so both fleets report crashes identically:

- **iOS** — enabled by default; exposed as an opt-*out* in the iOS config block.
- **Android** — the crash instrumentation artefact is not shipped, so crash capture is unavailable and there is no toggle.

## Consequences

- The platforms genuinely differ. A reader will notice; that is why this ADR exists.
- On iOS the Plugin contends with any incumbent crash reporter by default. Apps already using Crashlytics or Sentry should opt out explicitly, and the README must say so plainly.
- Choosing Fleet Alignment over the safer symmetric default is deliberate. If this proves wrong in practice, change it in **both** SDKs together rather than only here.
