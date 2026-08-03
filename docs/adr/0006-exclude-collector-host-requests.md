# Exclude requests to the Collector Host from tracing

Status: accepted

## Context

`apm-agent-ios` routes its own traffic through `URLSession.shared`, which its own instrumentation
swizzle traces — so exporting a span produces another span, which is exported, and so on. Under
ADR-0001 the pinned iOS Agent also instantiates a central-config poller internally with no
configuration hook to disable it, so that traffic happens regardless of what the Plugin exposes.

The organisation's React Native SDK worked through this twice
(`inoxth/react-native-edot-sdk`, `docs/adr/0003-self-tracing-exclusion-by-collector-host.md`).
A raw URL-prefix guard over-matched lookalike hosts and missed the export URL when the Agent stripped
`:443`/`:80`. Narrowing to host plus a `/v1/` path filter then leaked the central-config `GET`,
because `/config/v1/agents` is not under `/v1/`. The root failure was enumerating the Agent's
endpoints and hoping the list was complete. It never was.

## Decision

Exclude a request from tracing when its **host equals the Collector Host** — nothing more. No path
condition, no port condition. The Collector Host is the host component of the configured server URL.

Host-only is complete by construction: it covers signal export, central config, and any endpoint the
Agent gains in future, and it is immune to port normalisation because the port is never compared.

Apply the same predicate in the Dart instrumentation, so the two layers cannot disagree.

## Considered options

- **Host plus a known-path allowlist.** Rejected — precise but brittle; this is exactly the enumeration approach that leaked twice.
- **Host plus port.** Rejected — spares other services on the same host at a different port, but reintroduces the effective-port normalisation that caused the original miss, for a benefit that does not apply to a dedicated APM host.
- **Disable central config in the Agent.** Not possible on the pinned iOS version.

## Consequences

- **Over-exclusion, accepted.** Application requests to the same host, at any path or port, are not traced. Negligible for a dedicated APM host, and the deliberate trade for completeness.
- On iOS the Agent's built-in `URLSession` instrumentation is on/off only, so the Plugin replaces it with a filtered instrumentation carrying this predicate. Keeping it enabled matters: it is the only thing tracing native-origin plugin traffic.
