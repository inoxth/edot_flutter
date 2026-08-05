# inoxth_edot_flutter_dio

> **Unofficial.** Not built or supported by Elastic. It wraps Elastic's own EDOT mobile
> Agents, which are pinned — see [ADR-0001](../../docs/adr/0001-pin-edot-agents-for-ios-15.6-and-minsdk-24.md).

Dio integration for [`inoxth_edot_flutter`](../inoxth_edot_flutter/README.md). Adds one client
span per Dio request, carrying the same attributes and the same W3C Trace Context as the
plugin's own `EdotHttpClient`.

| | Minimum |
|---|---|
| iOS | 15.6 |
| Android | minSdk 24 |
| Dart SDK | ^3.12.0 |
| Flutter | >=3.44.0 |
| Dio | ^5.4.0 |

## Why it is a separate package

Dart has no optional dependencies. Bundling this into the plugin would impose Dio's version
constraint on every consumer, including the ones that never use it
([ADR-0010](../../docs/adr/0010-dio-integration-ships-as-a-separate-package.md)). The cost is one
extra line in your `pubspec.yaml`; the benefit is that the plugin's Dio constraint is never
yours to satisfy unless you asked for it.

## Setup

```yaml
dependencies:
  inoxth_edot_flutter: ^0.0.1
  inoxth_edot_flutter_dio: ^0.0.1
```

Start the plugin as its README describes, then add the interceptor to the `Dio` instance the
app already uses:

```dart
import 'package:inoxth_edot_flutter_dio/inoxth_edot_flutter_dio.dart';

final dio = Dio();
dio.interceptors.add(EdotDioInterceptor());
```

That is the whole API. The interceptor holds no state, so one instance can serve several `Dio`
instances.

**Add it last** if the app has other interceptors that rewrite requests. Dio runs interceptors
in the order they were added, so a URL rewritten by an interceptor added *after* this one is
recorded as it was *before* the rewrite.

## What you get

Everything the plugin's network tracing gives you, because both integrations drive the same
`EdotRequestTrace` ([ADR-0013](../../docs/adr/0013-one-shared-request-trace-for-every-transport.md)) — the URL
sanitizer, both exclusion rules and the trace-propagation decision are applied in one place for
both, so the two cannot drift apart:

- One client span per request, named `<METHOD>`, with the Elastic Mobile Attribute Set
  ([ADR-0003](../../docs/adr/0003-emit-the-elastic-mobile-attribute-set.md)).
- The Active View's screen attributes, so a request is attributable to the screen that made it.
- `traceparent` on requests to hosts you propagate to, joining the server's spans to this one.
- Request and response sizes where they can be known before the wire.

Configuration lives entirely on `EdotConfig` — `excludedUrls`, `urlSanitizer`,
`tracePropagationTargets`. There is nothing to configure here.

## Dio-specific behaviour

- **A 4xx or 5xx is recorded as a response, not a failure.** Dio raises those as
  `DioException` where `package:http` returns them as responses. Recording Dio's version
  literally would put an exception event on one integration's 500 spans and not the other's, so
  a rejected status code is recorded as the answer it is.
- **`exception.type` is Dio's own type**, not `DioException`. A single `DioException` covers a
  cancellation, four kinds of timeout and a refused connection alike, and telling those apart is
  most of what the attribute is read for.
- **A `Map` request body reports no size.** Dio's transformers encode it to JSON *after* this
  interceptor runs, so the encoded size does not exist yet. Strings, byte lists and `FormData`
  do report one. Absent rather than guessed — a wrong body size is worse than none.
- **`traceparent` you set yourself is overwritten.** The header names the immediate parent of
  the request, and once traced that is this span.
- **A request the plugin excludes is not traced at all** — the Collector Host
  ([ADR-0006](../../docs/adr/0006-exclude-collector-host-requests.md)), anything
  matching `excludedUrls`, and anything issued before `Edot.start`. The request itself proceeds
  untouched.

## Using it alongside the other transports

`EdotHttpClient`, `traceAllHttpTraffic` and this interceptor can all be enabled at once. A
request is never traced twice: the transport that traced it marks it, and
`traceAllHttpTraffic` leaves a marked request alone
([ADR-0014](../../docs/adr/0014-app-wide-tracing-is-marker-de-duplicated.md)).

## Limitations

Every limitation in the [plugin's README](../inoxth_edot_flutter/README.md#limitations)
applies here — `flush()` not promising delivery, the attribute set not being stable semconv,
the crash-reporting asymmetry. This package adds no telemetry pipeline of its own; it only adds
a source.

## Example

`../inoxth_edot_flutter/example` exercises this interceptor alongside the other two network
paths in its Network tab.
