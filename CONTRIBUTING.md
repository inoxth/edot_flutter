# Contributing

This plugin wraps the pinned EDOT mobile Agents, and almost every constraint you will meet
traces back to that. Before changing anything, it is worth knowing three things bind the whole
repo:

- **The Agents are pinned** (`apm-agent-ios` 1.2.1, `co.elastic.otel.android:agent-sdk` 1.1.0),
  and the platform floors - iOS 15.6, Android API 24 - are a direct consequence. Bumping a pin
  is not a routine dependency update; see [What not to do](#what-not-to-do).
- **Emitted wire names are the Elastic Mobile Attribute Set**, the vocabulary the native Agents
  themselves emit. They are deliberately not the stable OpenTelemetry conventions.
- **Every non-obvious decision is written down** in `docs/adr/`, with the domain vocabulary in
  `CONTEXT.md`. Read the relevant ADR before touching the area it governs.

## Prerequisites

- **Flutter 3.44+** (Dart SDK ^3.12.0). SPM is default-on from 3.44, which the iOS build needs.
- **melos 8** - `dart pub global activate melos`.
- Your app / example's **iOS deployment target set to 15.6** or higher.
- For the **Seam 2** tests only: **Docker**, and a connected device or running emulator.

## Repository layout

A pub workspace driven by melos:

| Path | What it is |
|---|---|
| [`packages/inoxth_edot_flutter`](packages/inoxth_edot_flutter/README.md) | The plugin: Dart API, both native implementations, `package:http` tracing |
| [`packages/inoxth_edot_flutter/example/`](packages/inoxth_edot_flutter/example/README.md) | Container for the flavor demo apps - `basic`, `navigator`, `go_router`, and the `shared` screens they reuse |
| `packages/inoxth_edot_flutter/example/navigator/` | The `Navigator` flavor, and home of the Seam 2 tests (`example/navigator/tool/verify_*.dart`) |
| [`packages/inoxth_edot_flutter_dio`](packages/inoxth_edot_flutter_dio/README.md) | Dio interceptor, shipped separately |
| [`packages/edot_collector_harness`](packages/edot_collector_harness/README.md) | Seam 2 test harness - runs a collector, reads telemetry back. Never published |
| `tool/collector/` | The OpenTelemetry Collector definition the harness runs |
| `docs/adr/` | Every architecture decision, numbered. The rationale behind the limitations |
| `docs/agents/` | Issue-tracker, triage-label and domain conventions |
| `CONTEXT.md` | Domain glossary - the terms in the docs have precise meanings here |
| `CLAUDE.md`, `AGENTS.md` | Guidance for agent contributors |

## Commands

```bash
flutter pub get          # resolves the pub workspace
melos run verify         # what CI runs: format-check, analyze, then the Seam 1 test tier
```

`verify` is the single gate. Its steps also run on their own:

```bash
melos run format-check   # dart format --set-exit-if-changed
melos run analyze        # dart analyze --fatal-infos across every package
melos run test --no-select
```

The `--no-select` flag on `test` is required: the script is package-filtered, so without it melos
prompts for a package and fails on a non-interactive shell.

The analyzer is strict on purpose - `strict-casts`, `strict-inference`, `strict-raw-types`, and
`public_member_api_docs` are on, so an undocumented public member fails `verify`. The example apps
and the harness opt out of the docs rule only (they are not published libraries); every other
deviation needs a comment saying why.

## Testing - the two seams

Tests target external behaviour, not implementation details, and they live at one of two seams.
Prefer the highest seam a change can be proven at.

**Seam 1 - the platform channel.** Fast, hermetic, no native code and no collector: the platform
channel is mocked and the Dart side is asserted directly. This is `melos run test`, and it is what
`verify` runs. Most logic belongs here.

**Seam 2 - exported telemetry at a real collector.** The Agent exports real OTLP to a collector
the harness runs, and the test asserts on what actually landed. Needs Docker and a device or
emulator.

Each Seam 2 contract is **two halves**: a device half that emits (runs under `integration_test`,
on the device) and a host half (`example/navigator/tool/verify_*.dart`) that starts the collector, drives
the device half and **owns the assertions**. They are split because the device cannot see the
collector's output file. Run the host half - it brings the collector up and down itself:

```bash
cd packages/inoxth_edot_flutter/example/navigator
dart run tool/verify_tracer_bullet.dart -d <device>
dart run tool/verify_span_enrichment.dart -d <device>
dart run tool/verify_span_parenting.dart -d <device>
dart run tool/verify_screen_attribution.dart -d <device>
dart run tool/verify_navigation.dart -d <device>
dart run tool/verify_inpage_view.dart -d <device>
dart run tool/verify_network.dart -d <device>
dart run tool/verify_trace_context.dart -d <device>
dart run tool/verify_collector_host_exclusion.dart -d <ios-device>  # iOS only
dart run tool/verify_platform_config.dart -d <device>               # runs the device half 4x
dart run tool/verify_signals.dart -d <android-device>               # Android only
dart run tool/verify_error.dart -d <android-device>                 # Android only
dart run tool/verify_disk_buffering.dart -d <android-device>        # Android only
dart run tool/verify_consent.dart -d <android-device>               # Android only
```

`verify_disk_buffering.dart` is the one suite that stops the collector mid-run - the only way to
create the offline period disk buffering exists for. Expect a few minutes: the outage has to
outlast the exporter's in-memory retry to prove anything.

Each host half **exits 2 with an explanation** when Docker is absent, rather than passing. A
silently skipped Seam 2 tier reads as coverage it does not have - keep it that way. Where an
assertion genuinely has no teeth on a platform (a timing the Agent will not let us pin), the suite
says so out loud rather than reporting a green that means nothing.

## Change workflow

Work is tracked as **Linear issues** in the `inox` project
[EDOT SDK Multi Platform](https://linear.app/inox/project/edot-sdk-multi-platform-5590ec245322),
titled with a `[Flutter] ` prefix (the project is shared with the React Native SDK). The
conventions - creating, reading, labelling, closing, and the triage vocabulary - are in
[`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md) and
[`docs/agents/triage-labels.md`](docs/agents/triage-labels.md). Code review happens in GitHub pull
requests on `github.com/inoxth/edot_flutter`; the issue, not the PR, is where a change's status is
read from.

1. Claim the issue (assign yourself, state `In Progress`).
2. Branch with a semantic name: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/`.
3. Build it, test-first at the appropriate seam.
4. When the change is bound by, or changes, an architectural decision, record it as an ADR under
   `docs/adr/` and keep `CONTEXT.md` in step. Use the glossary's vocabulary in code and docs; flag
   any conflict with an existing ADR rather than quietly diverging (see
   [`docs/agents/domain.md`](docs/agents/domain.md)).
5. Close the issue (state `Done`) with a comment that maps the work to its acceptance criteria.

Keep documentation single-source: the limitations list lives once, in the package README. Do not
copy it into the root README or here.

## Pre-commit verification

`melos run verify` must be green before every commit - format-check, analyze and the Seam 1 tier.
Fix the cause of a failure; do not silence it. Run the relevant Seam 2 host half too when the
change touches exported telemetry.

## Commit messages

Conventional commits: `type: imperative subject`, where `type` is `feat`, `fix`, `chore`, `docs`,
`refactor` or `test`. Reference the tracker item by its bare Linear identifier on its own line
(`DEV-1231`), and a pull request as `PR #42`. Do not mint a bare `#N` - that form belongs to the
frozen GitLab issues the pre-2026-08 commits reference, and reusing it makes the two
indistinguishable. Explain *why* in the body when the change is not self-evident - the ADRs hold
the deep rationale, so the commit can point at them rather than restate them.

## Releasing

Both packages ship under **one version and one tag** - why is in
[ADR-0017](docs/adr/0017-publish-both-packages-in-lockstep.md). `melos version` is not used; it
cannot cut this release, and that ADR records what it does instead.

Four edits, then a tag. To release `0.2.0`:

1. `packages/inoxth_edot_flutter/pubspec.yaml` - `version: 0.2.0`
2. `packages/inoxth_edot_flutter_dio/pubspec.yaml` - `version: 0.2.0` **and**
   `inoxth_edot_flutter: ^0.2.0`
3. Write both `CHANGELOG.md` entries by hand, in the prose style already there.
4. Verify, score, commit, tag:

```bash
dart run melos run verify        # the lockstep guard fails if step 2 was half-done

# What verify cannot see. Must report 160/160.
dart pub global activate pana    # once per machine
dart pub global run pana packages/inoxth_edot_flutter

git add -A
git commit -m "chore: release v0.2.0"
git tag v0.2.0
git push && git push --tags
```

**Only the core package can be scored here.** pana resolves against pub.dev, not the
workspace, and the Dio package's freshly bumped `inoxth_edot_flutter: ^0.2.0` matches nothing
there until core is published - so scoring it now reports `50/160` and a version-solving
failure, not a defect in the package. Score it *after* core is live:

```bash
dart pub global run pana packages/inoxth_edot_flutter_dio
```

Do not "fix" that failure by loosening the constraint. The release path already handles the
ordering: `await-core` blocks the Dio publish until pub.dev serves the new core version, and
only then does the Dio dry-run resolve.

**Run pana, and do not skip it because `verify` is green.** The two look at different things:
`verify` analyses the working tree, pana analyses the *extracted archive*. A defect that exists
only once the package is unpacked - a path that escapes the package root, a file the tarball does
not carry - is invisible to `verify` by construction. That is not hypothetical: every shipped
`analysis_options.yaml` once inherited the repo-wide config by relative path, which resolves in a
clone and dangles in the archive, crashing `dart format` and costing 10 points. `verify` was green
throughout.

pana is deliberately not in CI. Its score moves with dependency freshness, SDK releases and pana's
own version, so a threshold gate on every push would fail for reasons unrelated to the change. Here,
immediately before the tag, is the last moment a deduction is still free to fix.

**Push before you publish**, which the ordering above already does. pub.dev verifies the
`repository` URL by finding a pubspec there whose name *and version* match what is being published.
Publish while the pushed tree still says the old version and that check fails - 10 points on both
packages, permanently, for the version people actually install.

The tag is what publishes. `verify` gates the pipeline, a reviewer approves the `pub.dev`
environment, then the core package publishes and the Dio package follows - it has to wait, because
its constraint cannot resolve until core is live on pub.dev.

**Expect to approve twice, not once.** Each publish job declares `environment: pub.dev`, so each
creates its own deployment and each waits for a reviewer - once before core, and again before Dio.
Approving the first and walking away leaves the release half-published: core live, Dio not, and
nothing on pub.dev saying so. Stay with the run until both are green.

**A published version cannot be deleted or overwritten.** pub.dev allows retraction and nothing
more, so treat the tag push as final. If you are unsure about an artefact, publish a prerelease
(`0.2.0-dev.1`) first: prereleases do not become the latest stable, so nobody installs one by
accident.

## What not to do

- **Do not weaken or delete a failing test to make it pass.** Fix the cause, or ask if the test
  itself is wrong.
- **Do not bump the pinned Agent versions casually.** A bump can raise the platform floors, and it
  can quietly change the timing constants the ADRs measured (the flush, exporter-gate and
  persistence windows). Several ADRs name exactly what to re-check first - read them, and re-verify
  at Seam 2.
- **Do not rename the emitted wire attributes.** They match what the native Agents emit; renaming
  them here splits the plugin's telemetry from the Agents' and breaks any dashboard built on the
  native names.
- **Do not bundle native crash reporting on Android.** It is deliberately left out; the asymmetry
  with iOS is recorded and intended.
- **Do not let a Seam 2 suite skip silently.** Absent Docker or an untestable timing is reported,
  never passed over as green.
