# Inter-Instance Communications Design

**Status:** design draft (2026-07-07)
**Owners:** orch-6tms + orch-fnpe (jleechanorg/jleechanbrain)
**Repo context:** jleechanbrain / sidekick / multi-agent orchestration layer above Claude Code sessions

This document grounds the inter-instance comms protocol in **two real production incidents** from 2026-07-07:
1. **Multi-sidekick collision** — two parallel sidekick orchestrators running the same hardening mission.
2. **STATE.md Edit-conflict** — independent teammates writing to the same sidekick state file without locking.

It is intended as the canonical answer to "how do sidekicks, AO workers, and Hermes daemons avoid stepping on each other?"

## TL;DR

- **All long-running missions get a single owner** (a `orch-*` bead) and a single persistent sidekick.
- **State checkpoints are the source of truth**, not chat history.
- **File-based state uses owner-tag + append-only journal**, never shared rewritable files.
- **Git branches are per-mission worktrees**, never the host checkout.
- **Token busses and Slack bridges carry bounded payloads only**; LLM-on-LLM routing is forbidden (ZFC).

## Why this matters

On 2026-07-07 at 13:00 UTC, a hardening sprint budgeted 12h ran four lanes in parallel:
`orch-kgfp`, `orch-beks`, `orch-auo0`, plus a docs lane combining `orch-6tms` and `orch-fnpe`. Two distinct incidents surfaced:

### Incident A — Multi-sidekick collision
Two sidekick orchestrators inherited the same `orch-hrdn` mission bead via respawn and began dispatching the same four coder lanes. Each spawned its own pair-coder, both produced independent branches diverging from the same parent (the second branch name was not preserved in the captured reflog — only the surviving `feat/slack-gate-failopen-breaker` shows up in `git branch -a`; the second was rejected during `git push` and never made it to a remote-tracking ref). The collision was only visible because the second sidekick's branch push was rejected with "Everything up-to-date" against the first's prior push. **Time wasted: ~40 min of coder dispatch + 10 min of git push diagnostics.**

### Incident B — STATE.md Edit-conflict
The first sidekick wrote `/tmp/sidekick-hardening/STATE.md`. A teammate then appended via `cat >>` against the same shared file. A second sidekick respawn tried to overwrite with `Write` — harness `File has not been read yet` blocked it. The required workaround (read-then-write) burns a round-trip and is fragile under tight time budgets. **Time wasted: ~3 min and a re-attempt per respawn.**

The shared `/tmp/<repo>/sidekick/STATE.md` (single-file namespacing) was the
root cause; this doc previously recommended that exact path. See the
[learnings-2026-07] retro entry (PR #8191) for the corrected recommendation:
**per-mission path** `/tmp/<project>/sidekick/<mission>/STATE.md` — one file
per mission eliminates clobber races between concurrent sidekicks.

Both incidents share a root cause: **no single-writer invariant on mission-critical shared state.**

## Protocol (per the parent CLAUDE.md zero-framework-cognition rule)

### 1. Mission ownership is one-bead, one-sidekick

- One durable mission bead (e.g. `orch-hrdn`) per workload.
- One persistent sidekick owns that bead at a time. Respawn picks the same identity; if a second sidekick tries to claim, the durable bead `status` field rejects the second claim.
- Sub-lanes (e.g. `orch-kgfp`) are children of the mission bead, not co-equal orchestrators. Their dispatch is mediated by the owner sidekick.

### 2. State checkpointing

Each sidekick checks state to `/tmp/<project>/sidekick/<mission>/STATE.md`
(per-mission path, see [learnings-2026-07] retro entry under PR #8191 —
the previous `/tmp/<repo>/sidekick/STATE.md` shared-file pattern raced
under concurrent sidekicks) at **every green unit of work**, not at
end-of-turn. Format:

```markdown
# <mission> state
## Branch inventory
| Workspace | Branch | Remote HEAD | Local HEAD | Diff | Notes |
## Progress Log
- <ISO-8601 UTC>: <what changed + why>
```

- **Single writer.** Only the owning sidekick writes to STATE.md. Consumers read.
- **Append-only journal section** (`## Progress Log`) tolerates concurrent `cat >>` from teammates during handoff. Full-file rewrites require owner takeover.
- **Heartbeat.** A `last_heartbeat` ISO-8601 line allows a watchdog to detect a stalled sidekick within 5 min.

### 3. Per-mission worktrees

Each lane gets a dedicated worktree:
- Path: `/tmp/<owner>-<lane>-<run-id>` (deterministic, allows re-discovery).
- Branch: `feat/<scope>-<lane-short>` or `refactor/<scope>-<lane-short>`.
- Branch tips pushed to `origin/<branch>` at **every green unit**, never left local.
- **Host checkout is sacred.** No lane edits files in the user's primary worktree.

### 4. Pair-coding discipline

- Coder + verifier are independent agents (separate CLI engines by preference: one Claude, one Codex or Gemini).
- Verifier is **prompted to refute**, not bless.
- Refutations are first-class: a single refutation blocks PR-open until resolved.
- Verifier verdict is recorded in the PR conversation (issue comment), not in chat ephemeral state.

### 5. Cross-model /advice before merge

`/advice` fans out to Opus subagent + `/research` + `/secondo` (multi-model). Final verdict is recorded on the PR. A "needs more eyes" verdict is **not** a refutation — only CONCERN-level findings block.

### 6. Forbidden patterns (explicit non-goals)

- **No keyword/regex classification of LLM-routed messages** (ZFC).
- **No per-mission in-process cache** (multi-instance Cloud Run, no session affinity).
- **No Live Slack posts from coders** — only the bridge daemon (Hermes) posts, on explicit hook-fire.
- **No `git commit` on detached HEAD** — harness-level guard.
- **No edits to `~/.openclaw/` or hermes `.env` files** — `/hermes_secrets_no_env` policy.

## File-to-owner responsibility table

| File / state | Owner | Writers | Readers | Lock |
|---|---|---|---|---|
| `orch-hrdn` bead | sidekick | 1 (sidekick) | all | optimistic via bead status |
| `/tmp/<project>/sidekick/<mission>/STATE.md` | sidekick | 1 (sidekick, full rewrites allowed only) | many (read-only) | append-only journal section; per-mission path (PR #8191 retro) |
| `feat/<lane>` branch tip | coder | 1 (pair-coder) | verifier, /advice | natural git lock |
| PR conversation | coder/verifier | pair (comment-only) | all | GitHub-Locked |
| Slack thread (mission output) | hermes daemon | 1 (daemon) | humans + sidekicks | socket-level |

## When this protocol kicks in

- Any mission with duration > 30 min
- Any mission with > 3 sub-agents
- Any mission that writes to durable state (beads, branches, files, Slack)
- Any mission crossing a CLI-runtime boundary (Codex ↔ Claude ↔ AO)

## Known limitations

- STATE.md single-writer is enforced **conventionally**, not by FS lock. A second sidekick could still race. Mitigation: durable bead `status` field flips to `claimed` with sidekick ID + heartbeat; second claim fails the soft-contract.
- Pair-verifier prompting to refute reduces false-PASS but introduces latency (~3-7 min per cycle). Acceptable for hardening; not for sub-minute loops.
- `/advice` cross-model cost is non-trivial. Used only on PR-ready state, not on every commit.

## References

- `~/.claude/CLAUDE.md` — global baseline
- `~/.claude/skills/sidekick/SKILL.md` — sidekick definition + respawn contract
- `~/roadmap/learnings-2026-07.md` [learnings-2026-07] — 2026-07-07 multi-sidekick collision and per-mission STATE.md path correction (PR #8191 retro)
- PR #744 (orch-kgfp), #745 (orch-beks), #746 (orch-auo0) — exemplars of the four-lane pattern
