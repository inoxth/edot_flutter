# One shared request trace for every transport

Status: accepted

## Context

The Plugin traces requests from more than one transport: `package:http` through
`EdotHttpClient`, Dio through an interceptor in a separate package (ADR-0010), and
app-wide `dart:io` traffic still to come. Each transport has its own request type,
its own way of reporting a failure, and its own idea of when a 4xx is an exception.

What each one records must not vary: the Elastic Mobile Attribute Set (ADR-0003),
the URL sanitiser, the Collector Host and excluded-URL rules (ADR-0006) and the
Trace Context decision are properties of *the Plugin*, not of a transport. Written
per transport they would drift the first time one of them gained an attribute, and a
dashboard cannot tell "this request was not traced" from "this integration forgot an
attribute".

## Decision

One `EdotRequestTrace` in the core package owns everything a transport does not have
to know about. `begin` applies the exclusion rules and returns null when a request
must not be traced; it sanitises the URL, creates the span with the full attribute
set, and decides whether Trace Context travels. `recordResponse`, `recordFailure`
and `end` take it from there.

A transport is left with only what is genuinely its own: reading a method, URL and
body size out of its request type, putting the returned headers on it, and saying how
the request finished.

An integration **must** go through it, and **must** call `end` exactly once for every
request `begin` returned a trace for — including on the failure path, because a span
that never ends stays in the Agent's registry for the life of the process.

The trace a transport gets back is not always one span: `begin` also mints the Request
Transaction the request span hangs under, and `end` ends both (ADR-0016). A transport
neither knows nor cares — which is the point of this decision, and the reason the fix
for a data-model requirement landed in one file rather than three.

It is exported from `instrumentation.dart` rather than from the package's main
library. Dart has no visibility between packages, so the Dio package can only reach a
public element; `@internal` would make every use from that package an analysis
failure, which is the one use it exists for. A second library keeps the surface an app
developer reads unchanged while making an integration's import a deliberate act.

## Considered options

- **A shared base class each transport extends.** Rejected — `EdotHttpClient` already extends `http.BaseClient` and the Dio interceptor already extends `Interceptor`, so neither has an inheritance slot free. Composition costs nothing here.
- **Copy the recording into each integration.** Rejected — this is the drift the decision exists to prevent, and the Dio ticket asked for the two paths to be identical.
- **Keep it private and let the Dio package import `src/`.** Rejected — reaching into another package's `src/` is what `implementation_imports` exists to stop, and it makes an internal file a de facto public contract without saying so.

## Consequences

- The core package has a second public library. An integration author has to know to import it; an app developer never sees it.
- Its API is a compatibility surface. A change to it is a breaking change for every integration package, which is the cost of the two not being able to drift.
- Only `http.client` and body-size extraction remain per transport. Those are the two places a genuine difference between integrations can still appear, so both are asserted in each integration's own Seam 1 suite rather than shared.
- A transport whose failure model differs from `package:http` has to translate rather than record what it is given. Dio raises a 4xx as an exception where `package:http` returns a response; recording that as an exception event would put one on Dio's 500 spans and not the other's, for identical server behaviour.
