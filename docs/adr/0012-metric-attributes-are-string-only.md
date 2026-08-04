# Metric attributes are string-only

Status: accepted

## Context

Span attributes carry faithful types — string, integer, double and boolean — and integers must not
become floats or they stop being aggregatable (ADR-0003 vocabulary, delivered in the span enrichment
work). The obvious expectation is that metric attributes behave the same way.

They cannot, on the pinned iOS Agent. `apm-agent-ios` 1.2.1 registers the **legacy**
`MeterProviderBuilder`, and the legacy `Meter` protocol's only label API is:

```swift
func getLabelSet(labels: [String: String]) -> LabelSet
```

There is no typed label anywhere in that API. `StableMeterProviderBuilder` exists in
opentelemetry-swift 1.13.0 and would support typed attributes, but the Agent does not use it, and the
Agent is what owns export (ADR-0002).

Android's `agent-sdk` 1.1.0 has no such limit — `AttributeKey.longKey`/`doubleKey`/`booleanKey` all
work there. So the platforms genuinely differ in capability.

The organisation's React Native SDK reached the same wall and resolved it the same way, with the
reason recorded in its own source: *"Metric attributes are string-only labels on both platforms (iOS
1.2.1's legacy meter supports only string labels). Stringify numeric/boolean values so the same JS
call produces identical metric dimensions everywhere."* Its own metric API types attributes as
`Record<string, string>`.

## Decision

Metric attributes are `Map<String, String>`. The Dart type states the limitation rather than a doc
comment describing it, so a caller with an integer dimension converts it deliberately at the call
site.

This overrides the acceptance criterion in the metrics ticket that asked for metric attributes to
preserve their types consistently with span attributes. That criterion is not implementable.

Log record attributes are unaffected and stay typed: both platforms' logger providers accept typed
attributes, and the React Native SDK's log API accepts `string | number | boolean` too.

## Considered options

- **Typed attributes on Android, strings on iOS.** Rejected. The same call would produce a different
  dimension type per platform, so one Kibana dashboard could not aggregate across both fleets — which
  is the entire reason for the pins (Fleet Alignment).
- **Accept `Map<String, Object>` and stringify inside Dart.** Rejected. Nicer to call and it does
  produce identical dimensions, but it hides a hard platform truth behind a doc comment, and `3`
  silently becoming `"3"` is invisible at the call site.
- **Register `StableMeterProviderBuilder` ourselves on iOS.** Rejected for the same reason ADR-0011
  rejects rebuilding the trace pipeline: the Plugin would own metric export instead of the Agent,
  contradicting ADR-0002 and forfeiting the Agent's own metric instrumentation.

## Consequences

- Numeric metric dimensions are the caller's problem, which is the honest position given the platform.
- Metrics and span attributes are deliberately inconsistent. A reader will notice; that is why this is
  written down.
- Anyone raising the iOS Agent pin should check whether it has moved to the stable meter provider. If
  it has, typed metric attributes become possible and this ADR can be revisited — but only in lockstep
  with the React Native SDK, or the fleets stop sharing dashboards.
