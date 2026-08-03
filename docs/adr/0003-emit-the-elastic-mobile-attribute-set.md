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
| Screens | `screen.name`, `screen.id` |
| Errors | `exception.type`, `exception.message`, `exception.stacktrace`, `error.source` |
| Identity | `user.id` |

Note `screen.name` / `screen.id` specifically. Upstream OpenTelemetry has a registered
`app.screen.name` attribute, and OpenTelemetry Android's `ScreenAttributesSpanProcessor` uses it —
but the React Native SDK uses `screen.name`, and `screen.id` (the Screen Span's identifier) has no
upstream equivalent at all.

## Consequences

- **Do not migrate these piecemeal.** Any move to semconv 1.23 must happen in lockstep with the React Native SDK, or the two fleets stop sharing dashboards — which is the whole point of Fleet Alignment.
- The Plugin emits attributes marked deprecated upstream. This is deliberate; leave them alone.
- `http.url` carries the full URL including its query string, which routinely contains tokens and PII. Redaction must therefore operate on the URL itself, not merely drop whole attributes — hence the URL sanitizer hook in the config surface rather than an attribute-key deny list.
