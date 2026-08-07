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

Both a route navigation and an in-page view switch (tabs, a `PageView`, an `IndexedStack`) emit a
short Screen Span ending on the post-frame callback, giving time-to-first-frame, and move the Active
View - through one shared `Edot.enterView` primitive, so the two produce an identical Screen Span. A
route navigation drives it from `NavigatorObserver.didChangeTop`; an in-page switch drives it from
`EdotViewObserver`, which watches the app's own `TabController`, `PageController` or
`ValueListenable<int>`. `Edot.setActiveView` remains available as the attribute-only operation, for
re-tagging telemetry without measuring a transition.

Navigation is observed through `NavigatorObserver.didChangeTop` alone, and only routes that are
`PageRoute`s count as screens.

This mirrors the React Native SDK, which keeps an `ActiveViewContext` singleton in a shared package
and enriches on the JS side for the same reason.

## Revision: in-page switches emit a Screen Span

This ADR originally held that non-`Navigator` switches set the Active View only, with no Screen Span,
on the grounds that they have no transition to measure. That line is reversed: an in-page switch now
emits the same `"<name> - view appearing"` Screen Span a route navigation does.

The reason is Fleet Alignment. This organisation's React Native SDK records every view change its
navigation container reports - tabs included - as a view-appearing transition. Leaving Flutter silent
on tab switches was a visible gap between the two fleets and read as a missing feature. Emitting the
same span through the same primitive closes it: one dashboard query covers every view change,
whatever triggered it.

The guards this ADR already gives are retained. The span is still a short transition ending on the
next frame, not a long-lived span held open while the view is visible - the ten-minute-trace problem
is unchanged by where the switch came from. A popup is still not a screen. And an in-page switch that
pushes no route is still invisible to the `Navigator`, which is why tracking is wired to the app's
own tab or page mechanism rather than detected globally - Flutter exposes no global in-page navigation
event, so this is a documented limitation, not a gap to close.

## Consequences

- Native-origin spans (Firebase, Maps) carry no Screen Name on either platform. They correlate by Session only.
- **`didChangeTop` is the only observer method used.** It reports the route that is now topmost, for a push, a pop, a replace and a stack being cleared alike, and only when the topmost route actually changed. Handling `didPush`/`didPop`/`didReplace` separately would mean re-deriving which route becomes visible in each case, and a pop attributed to the wrong screen is not something any downstream assertion could catch. The cost is that a route removed from *underneath* the visible one is not reported at all — which is correct here, because nothing the user sees changed.
- **A popup is not a screen.** Dialogs and bottom sheets push routes through the same observer, and treating one as a screen would move the Active View off the screen still visible behind it — so every request the dialog made would be attributed away from it. Only `PageRoute`s count. The consequence is that a full-screen flow built out of `PopupRoute`s is invisible to navigation tracing and has to enter its view explicitly - with `Edot.enterView`, or `Edot.setActiveView` for attribution without a Screen Span.
- **Entries are de-duplicated by route, not by Screen Name.** Two entries can share a name: `/orders/1` and `/orders/2` collapse to one Screen Name and are still separate entries, each needing its own Active View identifier. De-duplicating by name would attribute the second entry's telemetry to the first. Exactly one route reference is retained, replaced on every navigation.
- **`enterView` never de-duplicates; its callers do, by their own identity.** Because same-named routes must stay distinct entries, the shared primitive always mints a fresh entry and span. The route observer de-duplicates by route identity (so a popup closing does not re-enter the screen); `EdotViewObserver` de-duplicates by index (so a rebuild or a no-op notification emits nothing). Putting the de-duplication in the primitive would have collapsed `/orders/1` and `/orders/2`.
- **An in-page observer owns the Active View for its route, and the route observer defers to it.** An in-page switch pushes no route, so after pushing a screen off a tabbed host and popping back, the route observer would enter the container's own name and clobber the tab. `EdotViewObserver` claims the route it lives on; when that route returns to the front, the route observer finds the claim and re-asserts the tab the user was on instead of entering the container - so a pop back onto a tabbed host lands on the tab and emits one Screen Span, not a container span plus a tab span.
- **A Screen Span carries `last.screen.name`** when the screen changed, matching this organisation's React Native SDK, so one dashboard answers "where did users come from" for both fleets.
- The Active View is genuinely global state, so a singleton is correct here — unlike span parenting, which uses zone-based ambient context because concurrent async flows must not steal each other's parent.
- If the iOS floor ever rises far enough to regain the interceptor, revisit: doing this natively would extend enrichment to native-origin spans, and the Dart-side path could be retired.
