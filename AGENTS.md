# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> This file is `AGENTS.md`; `CLAUDE.md` is a symlink to it, so both agent tools read one source. Edit `AGENTS.md`.

`inoxth_edot_flutter` is a Flutter plugin that wraps the pinned native EDOT mobile Agents (Elastic's OpenTelemetry distribution) for iOS and Android. It is a pub workspace of four packages driven by melos; the consumer-facing package is `packages/inoxth_edot_flutter`. Full layout is in `CONTRIBUTING.md`.

## Commands

melos is a workspace dev-dependency and is **not on PATH** - invoke it as `dart run melos ...` from the repo root.

- `dart run melos run verify` - the single gate CI runs: format-check -> analyze -> Seam 1 tests. Run before every commit.
- `dart run melos run analyze` - `dart analyze --fatal-infos` across every package.
- `dart run melos run format-check` - `dart format --set-exit-if-changed`.
- `dart run melos run test --no-select` - Seam 1 (hermetic) tests. **The `--no-select` flag is required**, or melos prompts for a package and fails on a non-interactive shell.
- Single test file: from a package directory, `flutter test test/<name>_test.dart`.
- Run/build on a device: from `packages/inoxth_edot_flutter/example/navigator`, `flutter run -d <device>`, or `flutter build apk` / `flutter build ios`. The plugin has no runnable target of its own.
- Seam 2 (real collector; needs Docker + a device/emulator): from `packages/inoxth_edot_flutter/example/navigator`, `dart run tool/verify_<name>.dart -d <device>`. See `CONTRIBUTING.md` for the full list and per-platform notes.

Analysis is strict on purpose: `strict-casts`/`strict-inference`/`strict-raw-types` and `public_member_api_docs` are on, so an **undocumented public member fails `verify`**. Only the example apps and the test harness opt out of the docs lint (they are not published libraries).

## Architecture

The pipeline is **native-authoritative** (ADR-0002): the Agent owns real spans, sessions, buffering and export. Dart never sees a real span id - it mints a **Shadow Span** identifier and the Agent maps it to the real span. Everything crosses one method channel (`edotChannelName`).

The native side has two implementations that must stay in lockstep: `InoxthEdotFlutterPlugin.kt` (Android, Kotlin) and `InoxthEdotFlutterPlugin.swift` (iOS, Swift), each under `packages/inoxth_edot_flutter/{android,ios}/`. A change to the channel protocol - a new method or argument - is a three-place edit: the Dart sender plus both handlers. **Seam 1 mocks the channel, so it stays green even if a native handler is missing; only Seam 2 catches that.**

Consequences that shape most of the code:

- **Dart owns timestamps** (ADR-0005), so spans can be created from synchronous code (build/paint) without awaiting the Agent. Telemetry produced before `Edot.start` is **Held Telemetry**: kept in a bounded queue and replayed on start.
- **Screen enrichment happens in Dart** (ADR-0004). Navigation produces Screen Spans and sets the Active View; every signal is tagged with the Active View's attributes in Dart, not by a native interceptor.
- **One shared request trace** (ADR-0013): `EdotRequestTrace` (in `lib/instrumentation.dart`) backs `EdotHttpClient`, the Dio interceptor, and app-wide `dart:io` tracing alike, so the URL sanitizer, exclusion rules and propagation decision live in one place. App-wide tracing de-duplicates against the wrapped transports via the **Traced Marker** header (ADR-0014).
- **The Tracking Consent gate is in Dart** (ADR-0015): refused telemetry is dropped before the channel, never handed to the Agent.

Hard constraints a change must respect:

- **The Agents are pinned** (ADR-0001); the platform floors (iOS 15.6, Android minSdk 24) are a consequence. Bumping a pin can raise the floors *and* silently change the timing constants the ADRs measured (flush, exporter-gate, persistence windows). Several ADRs name what to re-check - don't bump casually.
- **Fleet Alignment** (see `CONTEXT.md`): emitted wire names are the **Elastic Mobile Attribute Set** (ADR-0003) - deliberately the legacy Elastic vocabulary, *not* stable OpenTelemetry semconv - so one Kibana dashboard serves this fleet and the organisation's React Native fleet. Renaming a wire attribute breaks that.
- **Crash reporting is asymmetric** (ADR-0009): opt-out on iOS, unavailable on Android (the crash artefact is deliberately not bundled). **Dart Errors are non-fatal** (ADR-0008) and are never crashes.

`docs/adr/` holds all 15 decisions; read the relevant one before touching the area it governs. `CONTEXT.md` is the domain glossary - use its vocabulary (Agent, Plugin, Shadow Span, Active View, Screen Span, Held Telemetry, ...) in code and docs, and prefer the terms it lists over the ones it marks _Avoid_.

## Testing - two seams

- **Seam 1**: hermetic Dart with the platform channel mocked. Where most logic is proven; this is `dart run melos run test`.
- **Seam 2**: the Agent exports real OTLP to a collector the `edot_collector_harness` package runs; the host half (`example/navigator/tool/verify_*.dart`) owns the assertions, the device half emits. Two gotchas: `flutter test` uninstalls the app when a run ends, and the collector's `file` exporter truncates on container start - so a suite cannot assume state survives a restart. A suite that cannot prove a platform's behaviour says so out loud rather than passing green.

Prefer the highest seam a change can be proven at. Test external behaviour, not implementation. Running Seam 2 is documented in `CONTRIBUTING.md`.

## Conventions

- **Docs are single-source.** The limitations list lives once, in `packages/inoxth_edot_flutter/README.md`; do not duplicate it into the root README or elsewhere. Record architectural decisions as ADRs and keep `CONTEXT.md` in step.
- **Doc prose uses hyphens, not em-dashes.**
- **Ticket-driven workflow**: work is tracked as Linear issues (below); claim an issue by assigning yourself and moving it to `In Progress`, and close it with a comment mapping the change to its acceptance criteria.

## Agent skills

- **Issue tracker** - issues and PRDs are Linear issues in the `inox` project **EDOT SDK Multi Platform**, titled with a `[Flutter] ` prefix, driven by the Linear MCP tools. See `docs/agents/issue-tracker.md`.
- **Triage labels** - the five canonical triage roles and their Linear labels/states. See `docs/agents/triage-labels.md`.
- **Domain docs** - single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
