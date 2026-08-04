# Emit the Elastic Mobile Attribute Set, not the stable OpenTelemetry HTTP conventions

Status: accepted

## Context

OpenTelemetry stabilised its HTTP client conventions in semconv 1.23: `http.request.method`,
`url.full`, `server.address`, `http.response.status_code`. The native EDOT agents predate this and
emit the older Elastic mobile vocabulary. The organisation's React Native SDK deliberately emits the
older set "for parity with apm-agent-ios / apm-agent-android", tracking the semconv migration
separately.

A reader arriving at this code will recognise the old names as deprecated and be tempted to "fix" them.

## Decision

Emit the Elastic Mobile Attribute Set, matching the React Native SDK exactly:

| Concern | Attributes |
|---|---|
| HTTP | `http.method`, `http.url`, `http.target`, `http.scheme`, `http.status_code`, `http.request_body.size`, `http.response_body.size`, `http.client` |
| Network peer | `net.peer.name`, `net.peer.port` |
| Screens | `screen.name`, `screen.id`, `last.screen.name` |
| Errors | `event.name`, `exception.type`, `exception.message`, `exception.stacktrace`, `error.source` |
| Identity | `user.id` |

Note `screen.name` / `screen.id` specifically. Upstream OpenTelemetry has a registered
`app.screen.name` attribute, and OpenTelemetry Android's `ScreenAttributesSpanProcessor` uses it —
but the React Native SDK uses `screen.name`, and `screen.id` (the Screen Span's identifier) has no
upstream equivalent at all.

`last.screen.name` appears on Screen Spans only, and only when the screen changed. `event.name` is
`exception` on every error record. Neither has an upstream equivalent either; both are on this list
because the React Native SDK emits them and a dashboard filtering on them has to find both fleets.

## Consequences

- **Do not migrate these piecemeal.** Any move to semconv 1.23 must happen in lockstep with the React Native SDK, or the two fleets stop sharing dashboards — which is the whole point of Fleet Alignment.
- The Plugin emits attributes marked deprecated upstream. This is deliberate; leave them alone.
- **`screen.id` carries the same key as the React Native SDK's but not the same kind of value.** There it is the Screen Span's real OpenTelemetry span id, because its native module returns one. Here span creation is fire-and-forget and Dart never learns a span id (ADR-0002), so the Plugin mints its own per-visit identifier. Both fleets can be grouped by `screen.id`, and a query filtering or grouping on it works across both — but a dashboard joining `screen.id` to a span's `span_id` field resolves on the React Native fleet only. Join on the attribute on both sides instead.
- `http.url` carries the full URL including its query string, which routinely contains tokens and PII. Redaction must therefore operate on the URL itself, not merely drop whole attributes — hence the URL sanitizer hook in the config surface rather than an attribute-key deny list.
- **The Plugin strips more from a URL than the React Native SDK does**, before either sanitizer hook runs: the query string, the fragment, and any credentials written into the authority. The React Native SDK's `sanitizeUrl` removes only the query. This is a deliberate divergence, not drift — all three can carry a secret, and none of them names the resource that was requested. It does not affect Fleet Alignment, because it changes what a value contains rather than which attributes exist or what they are called: a dashboard grouping by `http.url` works on both fleets, and the Flutter fleet simply has fewer distinct values. Anything relying on a query parameter being present in `http.url` would break here — deliberately.
