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
| Start / end | the child's exactly | the same, from one clock reading [^clock] |
| Attributes | `type`, `session.id` - both added by the Agent to every span | none of its own, so the same two |
| Status | none | none |
| Export path | direct `exporter.export`, bypassing the batch processor | the Agent's normal pipeline - **not matchable** |

[^clock]: On the wire they can still land a few nanoseconds apart on Android, where the Agent rewrites the timestamps of any span created before its clock sync completes - see ADR-0005. Each span's duration survives that rewrite, so the pair still measures one request.

Export path aside, the copy is complete: **the Plugin sets no span status anywhere on the request
path**, on either span, which is what the iOS Agent's own `URLSessionInstrumentation` does for the
traffic it instruments. How a request failed is said the way the Agent says it - with an exception
event on the request span:

| What happened | Request span | Request Transaction |
|---|---|---|
| 2xx / 3xx | `http.status_code`, no status, no event | nothing |
| 4xx / 5xx | `http.status_code`, no status, one `exception` event: `exception.type` is the status code, `exception.message` the reason phrase | nothing |
| Transport failure (refused, timeout, TLS) | no `http.status_code`, no status, one `exception` event naming the failure type | nothing |
| Cancellation | as a transport failure, told apart by `exception.type` | nothing |

Two properties of the copy are worth stating outright, because both look like oversights:

- **It carries no `http.url`** - the one attribute that would break the parity outright. A
  parentless span with that key is precisely what the iOS Agent wraps, so a transaction carrying
  it would be wrapped in turn and one request would export three spans.
- **Nothing on the request path is ever marked failed**, though `EdotSpan.markFailed` exists and
  Dart Errors still use it (ADR-0008). Intake supplies the outcome the Plugin withholds: the
  request span carries HTTP attributes, so apm-data derives `event.outcome` from
  `http.status_code`, and the exit span reports success and failure per destination without a
  status being set. The Request Transaction has no HTTP attributes for that fallback to read, so
  it stays `event.outcome: unknown` - see the consequences.

The exception event stays on the request span alone; duplicating it would double every error the
Plugin reports.

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
- **Mark both spans failed when the request fails, departing from the Agent on that one axis.** Held briefly and reverted. It keeps Android's transaction error rate counting HTTP failures, which a status-free transaction cannot do. Rejected because it buys that at the cost of the parity the whole decision rests on: the two platforms and the two fleets would then report `event.outcome` differently on the same request, and a cross-fleet dashboard reading it would have to know which SDK produced each document. The failure signal is not lost - it moves to the exit span, where intake derives it from `http.status_code`, and to the APM error documents the exception events become.
- **Put it behind a config flag.** Rejected - without it, Android exit spans, the Dependencies view and span-destination metrics are simply absent. That is a defect, not a preference, and a flag is a way for an app to lose its service map silently.
- **Leave it and document `runWithParent` as the workaround.** Rejected - it makes every consumer responsible for a data-model requirement they cannot be expected to know.

## Consequences

- **One request produces two documents on both platforms**, where Android produced one. Ingest and storage for request telemetry roughly double there. iOS is unchanged: the Agent was already emitting the pair.
- **The Android transaction is not new - the exit span is.** A root span is recorded as a transaction, so a request already appeared in the Transactions view as `GET <host>`; what was missing beneath it was the exit span carrying the destination. Transaction *count* is therefore unchanged. What changed is that transaction's content: it no longer carries the `http.*` fields, and `transaction.type` moves from `request` to `unknown`, because apm-data derives the type from HTTP attributes and the Request Transaction deliberately has none. **An Android query filtering transactions on `http.status_code`, `http.method` or `transaction.type: request` must move to span documents.** This is the one existing-dashboard break.
- **Transaction error rate no longer sees HTTP failure on Android, and never did on iOS.** Before this decision an Android request span *was* the transaction, so a 500 produced a failed transaction document. The Request Transaction carries no status and no HTTP attributes, so it reaches Elastic as `event.outcome: unknown` - and Kibana's failed transaction rate is `failure / (failure + success)`, so an `unknown` document is *excluded* from the chart rather than counted as a success. An alert built on that chart for a mobile service therefore goes **no-data**, not falsely green. This is a real Android regression in one chart, taken deliberately for parity with iOS and with the React Native fleet, which have always behaved this way.
- **Where the failure signal lives instead.** The exit span: it carries `http.status_code`, so intake derives `event.outcome` from it and the **Dependencies** view reports failure rate per destination - the more detailed answer, and the only one that breaks down by host. And the **error rate**: every 4xx, 5xx and transport failure records an exception event, which apm-data turns into an APM error document, so a service's error rate and the Errors view both count them. **A mobile service should be alerted on error rate and on dependency failure rate, not on failed transaction rate.**
- **Every 4xx and 5xx now costs an error document.** That is the price of saying failure the Agent's way, and it is the same price iOS and React Native already pay. An app that treats a 404 as an expected answer will see it in the Errors view; exclude the URL (`EdotConfig.excludedUrls`) if that noise is not wanted.
- **Span counts are now comparable across platforms**, which they were not before. ADR-0001's note that they are not is superseded for requests specifically.
- **Until the React Native SDK makes the same change, the two fleets differ in trace shape on Android** - two spans per traced request here against one there. Wire attribute names are untouched, so Fleet Alignment (ADR-0003) is unaffected: a dashboard grouping by attribute reads both fleets, only one counting raw spans reads them differently.
- **The Request Transaction must never gain an HTTP attribute.** `http.url` on it re-triggers the iOS Agent and produces a third span per request. Seam 2 asserts both the absence of the attribute and that exactly two spans reach the collector per request.
- **An Agent bump is a reason to re-check this.** If a future `apm-agent-ios` stops manufacturing parents, nothing here changes - the Plugin already supplies one. If a future `agent-sdk` starts, the two would not collide either, since it would key off a parentless span and there are none. Both directions are safe, which is the point of owning it in Dart.
