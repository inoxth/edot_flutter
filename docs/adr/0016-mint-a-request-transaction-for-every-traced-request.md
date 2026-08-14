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
with the request span.

It is a **deliberate copy of the parent `ElasticSpanProcessor` manufactures** on iOS - the same
values on every axis that can be matched from Dart, so the two fleets and the two platforms emit
one shape:

| | The iOS Agent's parent | The Request Transaction |
|---|---|---|
| Name | the child's | the same |
| Kind | the child's, so `client` | `client` |
| Start / end | the child's exactly | the same, from one clock reading |
| Attributes | `type`, `session.id` - both added by the Agent to every span | none of its own, so the same two |
| Status | none | none |
| Export path | direct `exporter.export`, bypassing the batch processor | the Agent's normal pipeline - **not matchable** |

Two consequences of that copy are worth stating outright, because both look like oversights:

- **It carries no `http.url`** - the one attribute that would break the parity outright. A
  parentless span with that key is precisely what the iOS Agent wraps, so a transaction carrying
  it would be wrapped in turn and one request would export three spans.
- **It carries no status, so a failed request leaves a successful transaction.** A service's
  transaction error rate therefore does not see HTTP failures, on either platform. The failure is
  on the exit span, with the exception event; read it from there.

The pair is minted by one `EdotTracer.startRequest` call rather than two `startSpan` calls, and
ended by one `EdotRequestSpans.end`. That is what makes the timestamps *identical* rather than
merely close: one wall-clock reading and one monotonic stopwatch serve both spans, so ADR-0005's
rule that an end is a start plus elapsed time still holds - the measurement is shared, not
re-taken. Neither type is exported from the package's main library; an app nests its own work with
`startSpan` and `runWithParent`.

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

- **One request produces two documents on both platforms**, where Android produced one. Ingest and storage for request telemetry roughly double there. iOS is unchanged: the Agent was already emitting the pair.
- **The Android transaction is not new - the exit span is.** A root span is recorded as a transaction, so a request already appeared in the Transactions view as `GET <host>`; what was missing beneath it was the exit span carrying the destination. Transaction *count* is therefore unchanged. What changed is that transaction's content: it no longer carries the `http.*` fields, and `transaction.type` moves from `request` to `unknown`, because apm-data derives the type from HTTP attributes and the Request Transaction deliberately has none. **An Android query filtering transactions on `http.status_code`, `http.method` or `transaction.type: request` must move to span documents.** This is the one existing-dashboard break.
- **A failed request now leaves a successful transaction, and Android has regressed here.** Before this decision an Android request span *was* the transaction, so its failed status landed on a transaction document and the service's transaction error rate counted HTTP failures. The failure now sits on the exit span, and the Request Transaction carries no status - because the Agent's parent carries none, and parity with it was chosen over the more useful reading. Mirroring the status onto the transaction was implemented first and deliberately removed for that parity; it is a two-line change in `EdotRequestTrace.recordFailure` if the trade is ever reversed. Until then, **read HTTP failures from exit spans, not from transaction error rate**, on both platforms - which is what the React Native fleet has always required.
- **Span counts are now comparable across platforms**, which they were not before. ADR-0001's note that they are not is superseded for requests specifically.
- **Until the React Native SDK makes the same change, the two fleets differ in trace shape on Android** - two spans per traced request here against one there. Wire attribute names are untouched, so Fleet Alignment (ADR-0003) is unaffected: a dashboard grouping by attribute reads both fleets, only one counting raw spans reads them differently.
- **The Request Transaction must never gain an HTTP attribute.** `http.url` on it re-triggers the iOS Agent and produces a third span per request. Seam 2 asserts both the absence of the attribute and that exactly two spans reach the collector per request.
- **An Agent bump is a reason to re-check this.** If a future `apm-agent-ios` stops manufacturing parents, nothing here changes - the Plugin already supplies one. If a future `agent-sdk` starts, the two would not collide either, since it would key off a parentless span and there are none. Both directions are safe, which is the point of owning it in Dart.
