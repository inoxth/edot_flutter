# App-wide tracing is de-duplicated by a header, and scoped to dispatch

Status: accepted

## Context

`EdotHttpClient` and the Dio interceptor only see requests the app makes through them.
A third-party pure-Dart package builds its own `HttpClient`, so its traffic is invisible
to both. Covering it means installing an `HttpOverrides`, which sees everything —
including the requests the other two integrations have already traced, because both
dispatch through `dart:io`. Untreated, one request would produce two spans, doubling
counts and distorting latency percentiles while every individual span looked correct.

De-duplication cannot use ambient state. A Dio interceptor returns before its request is
dispatched, so the dispatch happens outside any scope it could establish, and several
requests are in flight at once.

## Decision

The outer layers mark every request whose span they created with a Traced Marker header,
and the app-wide layer leaves a marked request alone. The marker travels on the request,
which is the only thing the layers demonstrably share, and the check is a synchronous
read of the request in hand.

The marker is emitted by `EdotRequestTrace.outgoingHeaders` together with Trace Context,
in one call, so a transport cannot add the second and forget the first. It is not gated
on propagation: a request the target list left out still has a span, so it still has to
be recognised as already traced.

## Considered options

- **Remember in ambient state which request is being traced.** Rejected — a Dio interceptor has returned by the time its request is dispatched, so there is no scope to read.
- **Compare method and URL against a set of in-flight requests.** Rejected — two identical concurrent requests are indistinguishable, and the set is state to be kept correct on every failure path.
- **Have the outer integrations bypass the override.** Rejected — `package:http` and Dio each construct their own `HttpClient`, and taking that away from them means reimplementing what they do with it.

## Consequences

- **A span from this path begins at dispatch, not at connection.** `HttpClient.openUrl` establishes the connection, and the marker cannot be read until the layer that opened the request has set its headers — which is after `openUrl` has returned. Connection setup therefore falls outside the span, where the two explicit integrations include it. Their spans remain the better measurement of the same request; this path exists to see requests they cannot.
- **A connection that never opens produces no span at all** on this path, for the same reason: there was never a dispatch to attach one to.
- **No Trace Context is injected here.** Adding it needs the Agent's reply, and the only moment this layer may act is synchronous. Requests through the two explicit integrations still propagate; a third-party package's request is traced but does not join the trace downstream. Worth revisiting if the Agent ever offers the context synchronously.
- The marker reaches the service. Stripping it is only possible in the app-wide layer, which runs only when app-wide tracing is enabled — so stripping would make the request a service receives depend on which layers happen to be on. A boolean header is not worth that inconsistency.
- Installing is idempotent, and uninstalling restores the previous override only if ours is still in force. Two nested traced clients would double-count at one layer, which no marker can detect, because both halves would be this same layer.
