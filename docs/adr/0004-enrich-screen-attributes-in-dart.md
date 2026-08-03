# Enrich screen attributes in Dart, not via a native attribute interceptor

Status: accepted

## Context

Every span and log should carry the Active View's Screen Name and Screen Span identifier, so that
"which screen was this request on" is answerable. The obvious mechanism is a native span-attribute
interceptor reading a mutable field — it would stamp Dart-origin *and* native-origin spans in one place.

`apm-agent-ios` 1.2.1 has no such interceptor (ADR-0001). Android `agent-sdk` 1.1.0 does.

Separately, a long-lived span parenting everything that happens on a screen was considered and
rejected: a screen open for ten minutes becomes a single trace with hundreds of children, which
breaks trace waterfalls, head sampling and span limits. EDOT iOS deliberately measures view *load*
time only, and OpenTelemetry Android takes the same processor-based approach rather than parenting.

## Decision

Hold the Active View in a Dart-side singleton and attach `screen.name` and `screen.id` at span
creation time, in Dart. Do not use the Android interceptor even though it exists — using it on one
platform only would mean Dart-origin spans are enriched identically everywhere while native-origin
spans are enriched on Android alone, which is worse than a consistent limitation.

Navigation emits a short Screen Span ending on the post-frame callback, giving time-to-first-frame.
Non-`Navigator` switches (tabs, bottom navigation) set the Active View explicitly.

This mirrors the React Native SDK, which keeps an `ActiveViewContext` singleton in a shared package
and enriches on the JS side for the same reason.

## Consequences

- Native-origin spans (Firebase, Maps) carry no Screen Name on either platform. They correlate by Session only.
- The Active View is genuinely global state, so a singleton is correct here — unlike span parenting, which uses zone-based ambient context because concurrent async flows must not steal each other's parent.
- If the iOS floor ever rises far enough to regain the interceptor, revisit: doing this natively would extend enrichment to native-origin spans, and the Dart-side path could be retired.
