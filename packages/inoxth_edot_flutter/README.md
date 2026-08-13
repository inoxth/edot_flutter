# inoxth_edot_flutter

Flutter plugin for the Elastic Distribution of OpenTelemetry (EDOT) mobile Agents. It emits the
telemetry the native Agents produce, so a Flutter app reports into Elastic the same way a native
app does.

| | Minimum |
|---|---|
| **iOS** | **15.6** - Swift Package Manager required, **no CocoaPods support** |
| **Android** | **API 24**, compileSdk 35 |
| **Flutter** | **3.44** - SPM is default-on from this version |

These floors are not incidental. The Agents are pinned to the newest releases that meet them
(`apm-agent-ios` 1.2.1, `co.elastic.otel.android:agent-sdk` 1.1.0), because `apm-agent-ios`
raised its own floor to iOS 16 in 1.3.0. **Raising the pins raises the floors.** Your app must
set its iOS deployment target to 15.6 or higher.

---

## Read this first

Six things surprise people, and all six are deliberate. The full list is in
[Limitations](#limitations); these are the ones that change what you build.

1. **Android captures no native crashes.** iOS does, by default, and it will fight your
   existing crash reporter. See [Crash reporting](#crash-reporting).
2. **Dart errors are not crashes.** They are non-fatal log records and never affect crash-free
   rate, on either platform.
3. **On Android, nothing is exported for the first ~3 seconds after `Edot.start`** - and
   `flush()` reports success anyway. Do not build a "start, report, exit" flow.
4. **`Edot.currentSessionId()` is always empty on Android.** Its Agent exposes no accessor.
5. **`sessionSamplingRate` is unreliable on iOS.** Use `disableAgent` to switch telemetry off.
6. **The attribute names are deliberately the older Elastic vocabulary**, not stable
   OpenTelemetry semantic conventions. Do not "fix" them. See
   [The attribute set](#the-attribute-set).

---

## Setup

### 1. Add the dependency

```yaml
dependencies:
  inoxth_edot_flutter: ^0.1.0
  # Only if you use Dio - it ships separately, see below
  inoxth_edot_flutter_dio: ^0.1.0
```

### 2. Start the Agent

Early in `main`, before the first frame if you can - telemetry produced before this is held and
replayed, but the sooner it starts the less there is to hold.

```dart
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

Future<void> main() async {
  await Edot.start(EdotConfig(
    serviceName: 'my-app',
    serviceVersion: '1.4.2',
    deploymentEnvironment: 'prod',
    serverUrl: 'https://apm.example.com:443',
    auth: const EdotAuth.apiKey('...'),
  ));

  runApp(const MyApp());
}
```

`start` throws `ArgumentError` for invalid configuration and `StateError` if called twice. Both
are programming errors: failing loudly at startup is cheaper than silence in production.

Never hardcode the URL or credential. Read them from `--dart-define` or your own config layer.

Only the four identity fields above are required; every other option is in the
[Configuration reference](#configuration-reference).

### 3. Trace navigation

Navigation tracing produces a **Screen Span** per transition - ending when the destination's
first frame renders - and sets the **Active View**, so every later signal carries the screen it
came from. Screen names are derived from the route, with variable segments collapsed so
`/orders/9f8e7d6c` and `/orders/12345` do not become thousands of distinct screens. In-page view
switches - tabs, a `PageView`, an `IndexedStack` - produce the same Screen Span through
`EdotViewObserver`, covered under [Tabs and other in-page switches](#tabs-and-other-in-page-switches)
below.

#### Flutter's Navigator (the default)

Add the observer to your app's `navigatorObservers`. It works with named routes and imperative
`Navigator.push` / `pushNamed` alike:

```dart
MaterialApp(
  navigatorObservers: [EdotNavigatorObserver()],
  // ...
)
```

#### GoRouter

GoRouter reports through `NavigatorObserver`, so the same observer attaches via its `observers`
list:

```dart
GoRouter(
  observers: [EdotNavigatorObserver()],
  routes: [...],
)
```

GoRouter's own route names are usually paths such as `/orders/:id`, which do not read well on a
dashboard. Supply a `screenNameExtractor` to name them yourself:

```dart
EdotNavigatorObserver(
  screenNameExtractor: (route) => switch (route.settings.name) {
    '/orders/:id' => 'Order detail',
    final other => other,
  },
)
```

Return `null` or a blank string to fall back to the derived name. If the extractor throws, the
Plugin logs it and uses the derived name - navigation is never broken by telemetry.

A `ShellRoute` or `StatefulShellRoute` runs its own nested `Navigator`. Add an
`EdotNavigatorObserver` to that route's `observers` too, or the transitions inside the shell go
unobserved.

#### Other routers

Any router that drives a `NavigatorObserver` - auto_route, Beamer, and the rest - works the same
way. The `screenNameExtractor` hook shown above is the general escape hatch: it hands you the
`Route` and takes whatever name you return, so you can map any router's own route identifiers to
the screen names you want. It is the integration point, rather than a per-router adapter.

#### Tabs and other in-page switches

A bottom navigation bar, tabs, a `PageView` or an `IndexedStack` change what is on screen without
pushing a route, so a `NavigatorObserver` never sees them. Wrap the tabbed subtree in an
`EdotViewObserver` and each switch produces the same Screen Span a navigation does - automatically,
with no per-switch code. It hooks whichever mechanism you already drive the UI from:

```dart
EdotViewObserver.tabs(
  controller: _tabController,
  names: const ['Feed', 'Search', 'Profile'],
  child: TabBarView(controller: _tabController, children: [...]),
)
```

Use `.pages` for a `PageController`, or `.index` for a `ValueListenable<int>` behind a
`NavigationBar`. Supply the screen names as a list, or as a `nameFor` mapper for a set built at
runtime. The observer also owns the Active View for the route it lives on, so after opening a
screen from a tabbed host and popping back, the Active View returns to the tab you were on - with
no manual re-assert.

Flutter exposes no global in-page navigation event, so tracking is wired once to your own
controller or index rather than detected for you.

For a custom or imperative switcher no observer covers, call `Edot.enterView(name)` yourself - it
does exactly what the observer does on each switch (moves the Active View and emits the Screen
Span). It emits on every call and never de-duplicates, because two entries may legitimately share a
name; so de-duplicate no-op switches - a rebuild, or re-entering the view already showing - before
calling it. The observers above already do this for you.

If what you want is attribution without a transition - re-tagging telemetry without emitting a
Screen Span - call `Edot.setActiveView(name)` directly instead.

### 4. Trace network requests

Three options, in increasing order of reach. They can be combined - see [below](#combining-them-and-the-collector).

#### A single client - `EdotHttpClient`

Wrap the `http.Client` you already use. Only requests made through this client are traced;
nothing else is touched. It is the smallest blast radius, and the right choice when your app
funnels requests through a networking layer you control.

```dart
final client = EdotHttpClient(http.Client());
final response = await client.get(Uri.parse('https://api.example.com/orders'));
```

#### Dio - `EdotDioInterceptor`

Add the interceptor from the companion `inoxth_edot_flutter_dio` package to the `Dio` instance
your app already uses:

```dart
dio.interceptors.add(EdotDioInterceptor());
```

It ships separately because Dart has no optional dependencies. Its Dio-specific behaviour - how a
4xx is recorded, what `exception.type` carries, why a `Map` body reports no size - is documented
in the [Dio package README](../inoxth_edot_flutter_dio/README.md).

#### Everything over `dart:io` - `traceAllHttpTraffic`

A single config flag traces every request `dart:io` makes - `package:http`, and anything a
dependency sends through its own `HttpClient`:

```dart
await Edot.start(EdotConfig(/* ... */, traceAllHttpTraffic: true));
```

This reaches requests you did not write, which is usually the point. It is off by default because
it installs a process-wide `HttpOverrides`. Two things differ on this path only: the span begins
when the request is dispatched rather than when the connection opens, and it carries no Trace
Context - so a request traced this way does not join the server's spans downstream.

#### Combining them, and the collector

**Combining is safe.** A request is traced once, never twice: whichever layer traces it marks it,
and the others leave a marked request alone. So `traceAllHttpTraffic` alongside `EdotHttpClient`
or the Dio interceptor does not double-count.

**Your collector's own host is never traced**, at any path or port - otherwise exporting
telemetry would itself generate telemetry. The exclusion is host equality; see
[Traces](#traces) under Limitations.

### 5. Errors are already captured

`Edot.start` installs the handlers. Uncaught Dart errors, framework errors and failed futures
become non-fatal log records with `error.source` naming where they came from. Nothing to wire
up, and no guarded zone needed.

Two things you may want to add:

```dart
// Report something you caught and handled yourself.
try { ... } catch (error, stackTrace) {
  Edot.reportError(error, stackTrace: stackTrace);
}

// Capture errors from an isolate you spawn. Isolate.run and compute need nothing.
await Isolate.spawn(worker, message, onError: Edot.isolateErrorPort);
```

To also record errors thrown while a widget subtree builds, wrap it:

```dart
EdotErrorBoundary(child: MyRiskyWidget())
```

The boundary claims Flutter's error-widget hook only while it is mounted, so an app without one
keeps the error display it always had.

---

## Tracking Consent

Telemetry is gated on the user's permission, in three states. Only `granted` emits; `pending`
withholds exactly as `notGranted` does, and exists so an unanswered prompt is distinguishable
from a refusal.

```dart
// Start silent, because we have not asked yet.
await Edot.start(EdotConfig(
  // ...
  trackingConsent: EdotTrackingConsent.pending,
));

// The user answers. No restart needed, in either direction.
Edot.setTrackingConsent(
  accepted ? EdotTrackingConsent.granted : EdotTrackingConsent.notGranted,
);

// Render your privacy screen from one source of truth.
final current = Edot.trackingConsent;
```

| State | Emits? | Means |
|---|---|---|
| `granted` | yes | The user said yes |
| `notGranted` | no | The user said no |
| `pending` | no | We have not asked yet |

Three things to know:

- **The default is `granted`** - not because that is what your regulator wants. Pass `pending`
  if you must not emit before asking.
- **Refused telemetry is discarded, not held.** Granting later does not release what the app
  produced while consent was withheld. Withdrawing cannot retract what has already been
  exported - that has left the device.
- **The gate covers what the Plugin emits, not what the Agent collects by itself.** On iOS,
  crash reports, lifecycle events and system metrics are produced natively and never pass
  through it - each can be turned down through [`EdotIosConfig`](#ios-edotiosconfig). An app
  that must emit *nothing* before consent is resolved should use `disableAgent: true` and start
  the Agent only afterwards. On Android nothing measurable escapes the gate, because this plugin
  ships no self-instrumenting artefacts there.

---

## Manual instrumentation

```dart
// A span for your own operation.
final span = Edot.tracer.startSpan('checkout', kind: EdotSpanKind.internal);
span.setString('cart.currency', 'THB');
span.setInt('cart.items', 3);
span.end();

// Nest work underneath it, including across await boundaries.
await Edot.tracer.runWithParent(span, () async {
  await _reserveStock();   // spans in here become children
});

// A structured event that is not an operation.
Edot.log(EdotSeverity.warn, 'cart abandoned', attributes: {'cart.items': 3});

// A metric. Attributes are String-valued only - a hard limit of the pinned
// iOS Agent's legacy meter, not a simplification.
Edot.recordMetric('checkout.completed', 1, attributes: {'tier': 'gold'});
```

Being the most recently started span does **not** make a span a parent. That rule produces
plausible-looking, wrong trace trees the moment two async flows overlap, so use
`runWithParent` to say what nests under what.

---

## Configuration reference

Every option on `EdotConfig`. Only the four identity fields are required; every other option
defaults to what the EDOT Agent already does on its own on each platform.

### Required

| Field | Type | Purpose |
|---|---|---|
| `serviceName` | `String` | Identifies the app in Elastic |
| `serviceVersion` | `String` | Application version |
| `deploymentEnvironment` | `String` | Environment identifier, such as `development`, `staging`, `production` |
| `serverUrl` | `String` | OTLP endpoint telemetry is exported to; the port is made explicit for you |

### Optional

| Field | Type | Default | Purpose |
|---|---|---|---|
| `auth` | `EdotAuth` | `none()` | `apiKey` / `secretToken` / `none` - none suits a collector you run, and is wrong for Elastic Cloud |
| `exportProtocol` | `ExportProtocol` | `http` | `http` or `grpc`; grpc needs the receiver's port, usually 4317 |
| `sessionSamplingRate` | `double?` | unset | Fraction of sessions that report, `0.0`-`1.0`. Defaults to native agent's default. Honoured on Android, [unreliable on iOS](#absent-by-design) |
| `trackingConsent` | `EdotTrackingConsent` | `granted` | `granted` / `notGranted` / `pending` - see [Tracking Consent](#tracking-consent) |
| `debug` | `bool` | `false` | Enables the Agent's internal logging |
| `disableAgent` | `bool` | `false` | Stops the Agent emitting anything, for local development |
| `urlSanitizer` | `String Function(String)?` | `null` | Last chance to reshape a request URL before it is recorded |
| `excludedUrls` | `List<Pattern>` | `[]` | Requests whose URL matches any pattern are not traced at all |
| `tracePropagationTargets` | `List<Pattern>?` | `null` (all hosts) | Which traced requests carry W3C Trace Context |
| `traceAllHttpTraffic` | `bool` | `false` | Trace every `dart:io` request, not only those through this Plugin's transports |
| `android` | `EdotAndroidConfig` | defaults | Options that exist on Android only (below) |
| `ios` | `EdotIosConfig` | defaults | Options that exist on iOS only (below) |

### Android (`EdotAndroidConfig`)

| Field | Default | Purpose |
|---|---|---|
| `diskBufferingEnabled` | `true` | Buffer telemetry to disk so it survives offline periods (Android only; the iOS Agent persists unconditionally) |

### iOS (`EdotIosConfig`)

Each is an opt-*out* of something the iOS Agent does on its own. There are no Android equivalents:
its Agent installs whatever instrumentation ships on the classpath, with no runtime switch.

| Field | Default | Emits / effect | Turn off when |
|---|---|---|---|
| `crashReportingEnabled` | `true` | Native crash capture | You already run a crash reporter - [it will fight yours](#crash-reporting) |
| `systemMetricsEnabled` | `true` | `system.cpu.usage` and `system.memory.usage` gauges, sampled each cycle | Device-level metrics aren't useful - they are the steadiest contributor to metric volume |
| `appMetricsEnabled` | `true` | MetricKit reports - launch timings, app exits - batched about once a day | You already collect MetricKit yourself |
| `lifecycleEventsEnabled` | `true` | One span per foreground/background transition, carrying `lifecycle.state` | The app foregrounds and backgrounds constantly (turn-by-turn, media) |

### Value types

- **`EdotAuth`**: `EdotAuth.apiKey(key)`, `EdotAuth.secretToken(token)`, `EdotAuth.none()`. Never appears in `toString`.
- **`ExportProtocol`**: `http`, `grpc`.
- **`EdotTrackingConsent`**: `granted`, `notGranted`, `pending`.

---

## Limitations

Every item here is a recorded consequence of a decision, not an oversight.

### Absent by design

The pinned Agents predate these APIs, and raising the pins would raise the platform floors.

- **No user identity, no global attributes, no attribute redaction.** `apm-agent-ios` 1.2.1 has
  no span-attribute interceptor. Android's Agent *does* - it is forgone anyway, so the two
  platforms emit the same shape.
- **No central configuration / OpAMP.**
- **No Session control** - you cannot start, stop or rename a Session.
- **`Edot.currentSessionId()` returns an empty string on Android.** Its Agent exposes
  `SessionManager` only as internal, explicitly-unstable API. A support screen must handle an
  empty answer rather than displaying it.
- **`sessionSamplingRate` is unreliable on iOS.** The pinned sampler starts out sampling
  everything and consults the rate only when a Session is new or expired, so a relaunch inside
  the 30-minute Session window reports in full whatever the rate says. Use `disableAgent`.

### Delivery and timing

- **`flush()` does not promise delivery.** It drains the Plugin's buffers so nothing waits on a
  batch timer. Where the telemetry goes next is the Agent's business.
- **On Android, nothing is exported for the first ~3 seconds after `start`.** The Agent gates
  its exporters until its own latches open and reports success while telemetry is still queued.
  An app that starts, emits and is killed inside that window loses it. No configuration
  shortens the wait.
- **`flush()` covers traces only on iOS** - not log records, not metrics. Metrics leave on the
  Agent's own 60-second timer.
- **Buffered telemetry is delivered at least once.** After an outage the same span can arrive
  twice, because the buffer re-sends any batch it could not confirm. Count distinct span ids,
  not spans.
- **Telemetry buffered offline expires after 18 hours.**
- **On Android, telemetry held before `start` is dated when it was replayed**, not when it
  happened - the Agent re-derives every timestamp at export from its own clock. Durations are
  unaffected. iOS keeps the original time.

### Crash reporting

- **Unavailable on Android.** Its Agent installs whatever instrumentation is on the classpath
  with no filter and no runtime switch, so the only control is which artefacts ship - and this
  plugin deliberately does not ship the crash one.
- **On by default on iOS, and it will fight your incumbent.** Crash capture installs
  process-wide signal and Mach exception handlers; Crashlytics and Sentry install their own, and
  for signal-based crashes whichever installed last tends to win. **If you already have a crash
  reporter, opt out:**

  ```dart
  ios: EdotIosConfig(crashReportingEnabled: false),
  ```

  It is on by default because that is the Agent's own default.
- **Dart errors are not crashes.** They are non-fatal log records, so crash-free rate reflects
  native crashes only - which on Android means it reflects nothing this plugin sends.
- **Dart stack traces are not symbolicated.** An obfuscated release build produces unreadable
  frames. Keep your symbol files and deobfuscate offline.

### Traces

- **One request produces two spans on iOS and one on Android.** The iOS Agent treats any span
  carrying `http.url` as an HTTP span and manufactures a synthetic parent for it when it has
  none, because Elastic's data model requires a span to belong to a transaction. Span counts are
  not comparable across platforms. Giving the request a parent of your own avoids it.
- **Native-origin spans do not parent to Dart spans.** Anything the Agent instruments itself -
  lifecycle events, its own network instrumentation on iOS - starts its own trace. Correlate
  through `session.id` and the Active View attributes, not through trace structure.
- **No request to the collector's host is traced, at any path or port.** The exclusion is host
  equality, so a collector on `example.com` also excludes your API on `example.com`. Put them on
  different hosts.

### The attribute set

Emitted names follow the **Elastic Mobile Attribute Set** - the vocabulary the native EDOT
Agents themselves emit, which predates the stable OpenTelemetry HTTP conventions.

| Emitted | Stable OpenTelemetry equivalent |
|---|---|
| `http.method` | `http.request.method` |
| `http.url` | `url.full` |
| `http.target` | `url.path` + `url.query` |
| `http.scheme` | `url.scheme` |
| `http.status_code` | `http.response.status_code` |
| `http.request_body.size` / `http.response_body.size` | `http.request.body.size` / `http.response.body.size` |
| `net.peer.name` / `net.peer.port` | `server.address` / `server.port` |
| `screen.name` | `app.screen.name` |
| `screen.id`, `last.screen.name` | no upstream equivalent |
| `event.name`, `error.source` | no upstream equivalent |

**Do not migrate these.** They are the vocabulary the native Agents emit; renaming them here
would split what the plugin sends from what the Agents send and break any dashboard built on the
native names. If you want the stable OpenTelemetry set, it has to change at the Agent, not here.

Two details that matter when you write queries:

- **`screen.id` is not a span id.** This plugin never learns the Agent's span ids, so it mints
  its own per-visit identifier for the attribute. Group or filter on it as an attribute; do not
  expect it to join against a span's `span_id` field, because it is not one.
- **`http.url` is stripped before you see it.** Before any sanitizer of yours runs, this plugin
  removes the query string, the fragment and any credentials in the authority - all three
  routinely carry tokens or PII, and none of them names the resource requested. A dashboard
  grouping by `http.url` is unaffected; anything relying on a query parameter being present in it
  will not find one. Use `urlSanitizer` if you need to reshape what remains.

### Other

- **Metric attributes are `String`-valued only.** Convert numeric dimensions at the call site.
- **Dio support ships as a separate package**, because Dart has no optional dependencies and this
  package will not pull Dio into apps that do not use it.
- **Telemetry produced before `start` is held in a bounded queue** of 100 entries, oldest
  dropped first. The number dropped arrives as `edot.buffer.dropped` on a warning record, so the
  bound is visible rather than silent.

---

## Example

[`example/`](example/README.md) holds three apps - `basic`, `navigator`, and `go_router` - that
integrate the plugin with different navigation approaches over the same shared demo screens.
Between them they exercise every feature above: consent states, navigation and tab tracking, all
three network paths, error capture and the boundary, manual spans, logs, metrics, and the Session
identifier. The example index helps you pick one.

## Design decisions

`docs/adr/` in the repository records every decision this implementation is bound by, including
all the trade-offs behind the limitations above. `CONTEXT.md` is the domain glossary - the terms
used in this document have precise meanings there.
