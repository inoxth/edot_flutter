# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to what they actually are in this repo's tracker ([Linear](issue-tracker.md), team **DELI Dev Tasks**).

| Canonical role    | In our tracker                  | Meaning                                  |
| ----------------- | ------------------------------- | ---------------------------------------- |
| `needs-triage`    | label `needs-triage`            | Maintainer needs to evaluate this issue  |
| `needs-info`      | label `needs-info`              | Waiting on reporter for more information |
| `ready-for-agent` | label `ready-for-agent`         | Fully specified, ready for an AFK agent  |
| `ready-for-human` | label `ready-for-human`         | Requires human implementation            |
| `wontfix`         | state **Canceled**              | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding entry from this table. `wontfix` is a workflow state in Linear rather than a label, so set it with `save_issue`'s `state`, not `labels`.

Two notes on applying labels:

- `save_issue`'s `labels` **replaces the whole set**. Read the issue's current labels and pass the full intended list, or the others are silently dropped.
- The team has `needs-triage`, `needs-info` and `ready-for-agent` already; `ready-for-human` does not exist yet and must be created (`create_issue_label`, `teamId: 9f0817c4-0993-4303-b88b-0acf7968acd4`) the first time it is needed.

Claiming an issue is **not** a label: assign yourself and move the state to `In Progress` (see [`issue-tracker.md`](issue-tracker.md)).

Edit the right-hand column to match whatever vocabulary you actually use.
