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

### Instrumentation

**Traced Marker**:
A header on an outgoing request signalling that the Plugin has already created a span for it.
_Avoid_: dedup header, sentinel header

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
