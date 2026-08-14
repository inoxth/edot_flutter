# inoxth_edot_flutter

Flutter plugin that surfaces the Elastic Distribution of OpenTelemetry (EDOT) mobile agents to Dart,
so Flutter apps emit telemetry indistinguishable from the organisation's React Native apps.

## Language

### Telemetry ownership

**Agent**:
An instance of a native EDOT SDK, one per platform, that owns span creation, session state, buffering and export.
_Avoid_: SDK, client, collector

**Plugin**:
The Dart-facing package that instruments a Flutter app and drives the Agent.
_Avoid_: wrapper, bridge, library

**Shadow Span**:
A Dart-side identifier standing in for a span the Agent holds. Dart mints it; the Agent maps it to the real span.
_Avoid_: span handle, local span, span proxy, span stub

**Session**:
A bounded window of app activity that the Agent stamps onto every span and log, expiring after inactivity.
_Avoid_: visit, user session, trace group

### Screens

**Active View**:
The screen currently visible to the user, identified by a name and by the identifier of its Screen Span.
_Avoid_: current screen, current route, page, tab

**Screen Span**:
The span measuring a transition from one Active View to the next, ending when the destination's first frame renders.
_Avoid_: navigation span, route span, view span, dwell span

**Screen Name**:
The low-cardinality label for an Active View, with variable path segments collapsed.
_Avoid_: route path, screen title, URL

**In-Page View Switch**:
A change of the visible view that pushes no route - switching a tab, paging a `PageView`, changing the index of an `IndexedStack`. It moves the Active View and emits a Screen Span the same way a route navigation does, so a view change is tracked identically whether or not a route changed.
_Avoid_: tab change, page swipe, non-route navigation

### Instrumentation

**Traced Marker**:
A header on an outgoing request signalling that the Plugin has already created a span for it.
_Avoid_: dedup header, sentinel header

**Request Transaction**:
The span a traced request is nested under, so the request is recorded as an outbound call of this app rather than as work of its own. Without one, nothing links the app to the service it called.
_Avoid_: wrapper span, synthetic parent, dummy span, parent span

**Trace Context**:
The W3C headers that carry a span's real trace and span identifiers onto an outgoing request, so the work it causes elsewhere joins this app's trace.
_Avoid_: traceparent, distributed tracing headers, correlation id

**Propagation Target**:
A pattern naming a request that may carry Trace Context. Unset means every traced request.
_Avoid_: allowlist, trusted host, propagation scope

**Collector Host**:
The host of the configured server URL. Requests to it are never traced, at any path or port.
_Avoid_: APM server, endpoint, backend

**Dart Error**:
A non-fatal failure surfaced by the Flutter framework or the Dart runtime; the app survives it.
_Avoid_: crash, fatal, exception

**Native Crash**:
A fatal termination of the process, captured by the platform's own crash handler.
_Avoid_: error, fatal error, ANR

### Alignment

**Fleet Alignment**:
The constraint that telemetry leaving this Plugin carries the same names as telemetry from the organisation's React Native SDK.
_Avoid_: parity, RN compatibility, consistency

**Elastic Mobile Attribute Set**:
The attribute vocabulary the native EDOT agents themselves emit, which predates the stable OpenTelemetry HTTP conventions.
_Avoid_: legacy attributes, semconv, OTel conventions

**Tracking Consent**:
The user's permission state governing whether the Plugin emits telemetry at all.
_Avoid_: recording, opt-in, privacy mode, sampling

**Held Telemetry**:
Telemetry the app produced before the Agent could receive it, kept in order and emitted once it can.
_Avoid_: queued, cached, pending telemetry, retry, backlog
