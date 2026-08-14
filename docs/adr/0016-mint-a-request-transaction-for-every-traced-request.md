# Mint a Request Transaction for every traced request

Status: accepted

## Context

Kibana's service map drew no link from the Android service to the hosts it called. The same
app on iOS drew them. So did the organisation's React Native fleet: iOS linked, Android did not.

Elastic's data model splits incoming OpenTelemetry spans in two. In `apm-data`'s OTLP intake a
span becomes a **transaction** when `root || kind == Server || kind == Consumer`, and a **span**
otherwise. Only the span branch computes `span.destination.service.resource` - the transaction
branch has no destination at all. That field is what the service map draws an external edge
from, what the Dependencies view lists, and what APM Server aggregates span-destination metrics
from.

`EdotRequestTrace` created each request span with no parent, so every traced request arrived as
a root. A root client span is therefore recorded as a transaction that called nothing, and there
is no edge to draw.

iOS was never doing anything different - it was being rescued. `ElasticSpanProcessor.onEnd` in
`apm-agent-ios` 1.2.1 treats any parentless span carrying `http.url` as an HTTP span, builds a
second span around it, reparents the real span beneath it and exports both (ADR-0001). The
request span stops being a root on the way out, so it lands as an exit span with a destination.
`co.elastic.otel.android:agent-sdk` 1.1.0 has no equivalent processor, so Android kept the roots.

ADR-0001 recorded this as a span-count difference between the platforms. It is the same fact:
the missing service map edge is what that difference costs.

## Decision

The Plugin gives every traced request a parent of its own - a **Request Transaction** - rather
than relying on an Agent to supply one.

`EdotRequestTrace.begin` starts it when `Edot.tracer.ambientParent` is null, and `end` ends it
after the request span. It is:

- **`kind: internal`**, taking the request span's name. It represents the app doing work that
  caused a request, not the request.
- **Free of attributes of its own.** It carries only the Active View attributes every span gets
  from `EdotTracer.startSpan`, which gives the transaction screen attribution for nothing.
- **Never carrying `http.url`.** That attribute on a parentless span is exactly what the iOS
  Agent wraps, so a Request Transaction carrying it would be wrapped in turn and one request
  would export three spans.
- **Marked failed with the request span.** A transaction reporting success over an exit span
  that failed makes Kibana's error rate confidently wrong. The exception event stays on the
  request span alone.

It applies on **both platforms**, with no platform branch. The Plugin's parent lands first, so
`ElasticSpanProcessor` finds nothing to rescue and iOS keeps exporting two spans per request
rather than three.

A request started inside `EdotTracer.runWithParent` gets **no** Request Transaction: the ambient
span is the transaction it belongs to already.

## Considered options

- **Mirror `ElasticSpanProcessor` in the Android plugin.** Rejected - it converges Android on iOS's wire shape without touching Dart, but it is a native-only change Seam 1 cannot prove, it puts trace shaping in a native file rather than in the one place every transport goes through (ADR-0013), and it leaves iOS depending on an Agent quirk we do not control.
- **Apply it on Android only.** Rejected - it would be the first platform branch in the Dart library, for two behaviours where one will do, and it keeps iOS's trace shape in the Agent's hands.
- **Open one long-lived transaction per screen visit and parent every request on that screen to it.** Attractive: transactions named by screen read far better in the APM UI, and it costs one extra span per visit rather than per request. Rejected for now - the transaction only exports when the screen is left, so an app killed on-screen never exports it and leaves exit spans whose parent document is missing. The per-request shape is the one already known to produce the edge in Kibana, because iOS has been emitting it all along.
- **Put it behind a config flag.** Rejected - without it, Android exit spans, the Dependencies view and span-destination metrics are simply absent. That is a defect, not a preference, and a flag is a way for an app to lose its service map silently.
- **Leave it and document `runWithParent` as the workaround.** Rejected - it makes every consumer responsible for a data-model requirement they cannot be expected to know.

## Consequences

- **One request produces two spans on both platforms.** Android span volume for traced requests roughly doubles, and the APM Transactions view gains a `GET <host>` transaction per request. This is what iOS has been paying since the Plugin shipped.
- **Span counts are now comparable across platforms**, which they were not before. ADR-0001's note that they are not is superseded for requests specifically.
- **Until the React Native SDK makes the same change, the two fleets differ in trace shape on Android** - two spans per traced request here against one there. Wire attribute names are untouched, so Fleet Alignment (ADR-0003) is unaffected: a dashboard grouping by attribute reads both fleets, only one counting raw spans reads them differently.
- **The Request Transaction must never gain an HTTP attribute.** `http.url` on it re-triggers the iOS Agent and produces a third span per request. Seam 2 asserts both the absence of the attribute and that exactly two spans reach the collector per request.
- **An Agent bump is a reason to re-check this.** If a future `apm-agent-ios` stops manufacturing parents, nothing here changes - the Plugin already supplies one. If a future `agent-sdk` starts, the two would not collide either, since it would key off a parentless span and there are none. Both directions are safe, which is the point of owning it in Dart.
