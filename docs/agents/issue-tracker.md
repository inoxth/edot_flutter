# Issue tracker: Linear

Issues and PRDs for `inoxth_edot_flutter` live in **Linear**, workspace `inox`:

| | |
| --- | --- |
| Team | **DELI Dev Tasks** (`9f0817c4-0993-4303-b88b-0acf7968acd4`), issue key `DEV` |
| Project | **EDOT SDK Multi Platform** (`db141f0c-11f5-4ea7-a571-a01545f5a019`) - [open it](https://linear.app/inox/project/edot-sdk-multi-platform-5590ec245322) |
| Title prefix | `[Flutter] ` |

The project is shared with the organisation's React Native SDK, whose issues carry a `[React-Native] ` prefix. **Always prefix a Flutter title with `[Flutter] `** so one project serves both fleets without ambiguity - the same Fleet Alignment reasoning that governs the wire attributes.

Operations go through the **Linear MCP tools** (`mcp__claude_ai_Linear__*`), not a CLI. There is no `glab`/`gh` equivalent to shell out to.

## Conventions

- **Create an issue**: `save_issue` with `title` (prefixed), `description` (Markdown, literal newlines), `team: "DELI Dev Tasks"`, `project: "EDOT SDK Multi Platform"`. Omit `id` when creating.
- **Create a sub-issue**: the same call plus `parentId: "<DEV-nnn>"`. A PRD or spec is a parent issue; each work item is a sub-issue of it.
- **Read an issue**: `get_issue` with the identifier (e.g. `DEV-1194`). Pass `includeRelations: true` for blocking/related links. Comments come from `list_comments`.
- **List issues**: `list_issues` with `project: "EDOT SDK Multi Platform"`, plus `label`, `state`, `assignee`, or `parentId` filters. Pass `fields` to keep the response small (`["title", "status", "labels", "parentId", "url"]`).
- **Comment on an issue**: `save_comment` with `issueId` and `body`.
- **Apply / remove labels**: `save_issue` with `labels: ["..."]`. This **replaces the whole label set** - read the current labels first and pass the full intended list, or you will silently drop the others.
- **Move state**: `save_issue` with `state`. The team's states are `Backlog`, `Todo`, `In Progress`, `In Review`, `Commented`, `Done`, `Canceled`, `Duplicate`.
- **Claim**: `save_issue` with `assignee: "me"` and `state: "In Progress"`. This replaces the old `in-progress` label - in Linear, claiming is a state plus an assignee, not a label.
- **Close**: post the explanation with `save_comment` first, then `save_issue` with `state: "Done"`. Use `Canceled` for work that will not be done and `Duplicate` (with `duplicateOf`) for a repeat.
- **Blocking**: native relations. `save_issue` with `blockedBy: ["DEV-nnn"]` or `blocks: [...]`; both are append-only, and `removeBlockedBy` / `removeBlocks` undo them. Do not write "Blocked by" prose in the description - the relation is the canonical, UI-visible form.
- **Cross-reference an issue** in prose by writing its bare identifier (`DEV-1194`); Linear turns it into a live mention automatically.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(`/triage` reads this flag.)_

Code lives on GitHub (`github.com/inoxth/edot_flutter`) and code review happens in GitHub pull requests, but pull requests are **not** a tracker surface: they carry no triage labels and no triage state. Link a PR to its Linear issue with `save_issue`'s `links` field, and keep the issue as the single place a change's status is read from.

**GitHub Issues are enabled but are not a tracker surface either.** Linear is the sole tracker. Do not file work there, and do not read status from it.

Because the tracker and the code host are different systems - and because GitHub shares one number sequence between issues and pull requests - a bare `#42` is ambiguous. Refer to tracker items by their Linear identifier (`DEV-42`) and to pull requests as "PR #42". A bare `#N` in a commit written before 2026-08 means a frozen GitLab issue, not anything on GitHub.

## When a skill says "publish to the issue tracker"

Create a Linear issue in the project above, with the `[Flutter] ` title prefix.

## When a skill says "fetch the relevant ticket"

Run `get_issue` on the identifier, then `list_comments` for the discussion.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **sub-issues** as tickets.

- **Map**: an issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body.
- **Child ticket**: a **sub-issue** of the map (`parentId`) labelled `wayfinder:<type>` (`wayfinder:research` / `wayfinder:prototype` / `wayfinder:grilling` / `wayfinder:task`). Sub-issues replace the old `Part of #<map>` prose line. Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: `save_issue` with `blockedBy`. A ticket is unblocked when every blocker is in a completed or canceled state.
- **Frontier query**: `list_issues` with `parentId: "<map>"`, then drop any ticket with an unfinished blocker (`get_issue ... includeRelations: true`) or an assignee; first in map order wins.
- **Claim**: `save_issue` with `assignee: "me"` and `state: "In Progress"` - the session's first write.
- **Resolve**: `save_comment` with the answer, `save_issue` with `state: "Done"`, then append a context pointer (gist + link) to the map's Decisions-so-far.

## History: the GitLab era

Until 2026-08 both the tracker and the code lived on `gitlab.inox.co.th/nonth/edot_flutter`. They moved separately, and the repo still carries traces of both moves.

**The tracker moved first.** It was GitLab issues, driven by `glab`. All 35 issues and PRDs were migrated to the Linear project above, each with its comments and a provenance footer naming its GitLab origin. Every GitLab issue carries a pointer note to its Linear identifier and is frozen as history - do not reopen or comment on one. A `#N` reference inside a migrated body means the GitLab issue it was written against.

**The code host moved second**, to `github.com/inoxth/edot_flutter`. The GitLab project is archived and read-only: still browsable, so a bare `#N` in any of the pre-migration commits can still be resolved to the issue it names, but it accepts no pushes and no new issues. Nothing should be added there.
