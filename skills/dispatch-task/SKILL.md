---
name: dispatch-task
version: 2.1.0
description: Dispatch a task via ao spawn/ao send with a GitHub Issue for tracking, and ack in Slack thread. AO opt-in path — for ordinary coding work, use `claude-code-claudem` (`bash -lic 'claudem -p …'`) on a clean worktree instead.
---

# dispatch-task

> **DEFAULT vs OPT-IN.** As of 2026-08-03 (`feat/default-claudeminimax-coding`), this skill is the **AO opt-in path**, not the default. The default for ordinary coding work (any task that writes/edits files, creates a PR, or runs multi-step implementation) is `claude-code-claudem` via `bash -lic 'claudem -p "<task>"' --max-turns <N>` on a clean worktree (see `skills/claude-code-claudem/SKILL.md` and `workspace/SOUL.md` Agent Dispatch Policy). This `dispatch-task` / `ao` path is correct only when:
> 1. The user explicitly typed `/af` or `/auto-factory` in the current message, OR
> 2. The user is invoking a slash command whose documented contract intentionally routes through AO (e.g. `/green`, `/drive-to-green`, `/af-fanout`).
>
> No other slash command, alias, or natural-language override (`/a`, `/agento`, "use AO", "use agento", "spawn an AO worker") routes here by default. Bare `make a PR` / `open a PR` / `drive to green` in a regular coding request do NOT route here by default anymore — they route via claudem. See `tests/test_routing_default_claudem.py` for the contract.

Use this skill when jleechan explicitly asks for an AO worker AND the criterion above is met.

## When to use

- jleechan explicitly invoked `/af` or `/auto-factory`
- The task explicitly belongs to the AO pathway (long-running PR remediation across multiple CI/review cycles, mctrl supervised work, etc.)
- The request is an imperative dispatch trigger (any of "make a PR", "create a PR", "open a PR", "/green", "bring to green", "and merge", "drive to merge") AND the user explicitly opted into AO
- This applies regardless of how the request arrived: Slack, HTTP gateway, cron, or inline prompt

## NEVER use `sessions_spawn` for coding tasks

`sessions_spawn` is hermes's internal nested-agent tool. It does NOT create a git worktree, does NOT handle PR lifecycle, pastes prompts without auto-submitting Enter, and allows silent task rewriting. **It is banned for any task involving code, files, or PRs.**

For ordinary coding tasks (the default), use `claude-code-claudem` via `bash -lic 'claudem -p "<task>"' --max-turns <N>` from a clean worktree. Use this skill and the `ao` CLI (agent-orchestrator) only when the AO opt-in trigger above has been met.

## Within AO scope — always use `ao spawn` for these triggers

Within AO scope (the user explicitly invoked `/af` or `/auto-factory`, OR a slash command whose contract intentionally routes through AO), if the user's message is an **imperative** request (not a read-only question) containing ANY of these patterns, `ao spawn` is mandatory — do not continue inline:
- "and /green" / "bring to green" / "make it green"
- "create a PR" / "open a PR" / "make a PR"
- "and merge" / "drive to merge" / "drive this to merge"
- "change X and /green" (scope pivot mid-conversation)
- A standalone "/green" follow-up in an existing thread

Scope pivots count too, when AO scope is in effect. If an inline conversation that started as Q&A/investigation receives a follow-up with any of the above patterns AND the user has already opted into AO for this thread, post "Spawning AO worker — this needs worktree isolation" and dispatch. Outside AO scope the same imperative triggers pivot to a claudem delegation on a clean worktree instead (see `workspace/SOUL.md` `## COMMIT: scope-pivot-to-claudem`). Do NOT continue inline past the pivot in either case.

Read-only questions ("how do I create a PR?", "why did create a PR fail?", "show me the diff") do NOT trigger this rule — answer inline.

## Task description: preserve + expand, never condense

Build the task body you pass to `ao send` (via `--file`) in two parts:
1. **User's original text verbatim** — copy it exactly, do not shorten or paraphrase
2. **Memory expansion** — append relevant findings from `/mem-search` or the memory MCP: past failures, known gotchas, patterns that apply to this task

Final task = original text + appended memory context. Never replace the user's words with a summary. If the original is long, that is intentional.

## ⚠️ COMMON CONFUSIONS — AO HAS NO WORKER-COUNT CAP

**There is no AO worker-count cap.** `ao spawn` is unbounded by config — bounded only by host tmux/process capacity, load average, and disk. Verified 2026-06-23: `ao status --project worldarchitect` showed 17 active `wa-*` sessions running concurrently with no spawn rejection. `ao spawn --help` has no `--max-workers`, `--max-concurrent`, or `--cap` flag; `~/.smartclaw_prod/agent-orchestrator.yaml` has no `max_*` keys.

**If you find yourself reasoning "the cap is N, spawn will be blocked"** — you have read one of these and projected it onto AO. None of them is the AO worker ceiling:

| Source | What it actually is | Why it is NOT the AO worker cap |
|---|---|---|
| `~/.smartclaw/roadmap/VALUE_ROUTER_DESIGN.md:14` (`MAX_CONCURRENT_AGENTS = 5` in `services.ts`) | **Proposed design** for a future value-router service | Roadmap future-plan, not live code |
| `~/.smartclaw/skills/jleechanbrain-eloop.md:133` ("if active sessions >= 5, skip dispatching this cycle") | **Per-loop dispatch throttle** for the jleechanbrain kanban eloop | Local heuristic for one orchestrator, not AO |
| `agents.defaults.maxConcurrent=10` in `~/.smartclaw_prod/config.yaml` | **Hermes gateway agent slots** — not AO workers | Different system entirely (Slack/Discord bot, not the thing that spawns `wa-*` tmux sessions) |
| `delegation.max_concurrent_children=3` | **Hermes subagent fan-out per parent agent run** | Nested subagent limit inside a single Hermes run, not an AO ceiling |

**Verification recipe when in doubt:**

```bash
# Live AO worker count
ao status 2>/dev/null | grep -cE '\b(wa|cc|jc|co)-[0-9]+'

# Active only (excluding dead/stopped/done)
ao session ls 2>/dev/null | grep -E '\b(wa|cc|jc|co)-[0-9]+' | grep -vcE 'dead|stopped|done'

# AO config — should be NO max_* keys
grep -E "max_(concurrent|workers|spawn)" ~/.smartclaw_prod/agent-orchestrator.yaml || echo "no cap (expected)"

# ao spawn CLI flags — should be NO --max-workers / --max-concurrent / --cap
# (--max-depth is fine; it's decomposition depth, not worker count)
ao spawn --help 2>&1 | grep -E -- "--max-(workers|concurrent|count|cap|sessions)" && echo "FOUND WORKER CAP (unexpected)" || echo "no worker cap flag (expected)"
```

**Hermes ↔ AO mental model (do not confuse):**

- **Hermes gateway** (`~/.smartclaw/config.yaml`): the Slack/Discord bot you are talking through right now. Has `agents.defaults.maxConcurrent=10` for top-level agent runs and `delegation.max_concurrent_children=3` for subagent fan-out per parent. These ARE real caps — but they are on Hermes, not AO.
- **Agent-Orchestrator** (`~/.smartclaw_prod/agent-orchestrator.yaml`): the orchestrator that spawns `wa-*` / `cc-*` / `jc-*` tmux worker sessions to drive PRs and beads. **No worker-count cap in config.** Runs as standalone tmux processes, not through Hermes.

**Bug-ref (2026-06-23, thread C0AH3RY3DK6 / 1782231742.048439, "why does everything think we have a cap of 5 AO workers"):** an agent read `MAX_CONCURRENT_AGENTS = 5` from the value-router roadmap doc, conflated it with the AO worker ceiling, and stalled a dispatch with "Cap of 5 means spawn will likely be blocked" while `ao status` simultaneously showed 17 alive `wa-*` sessions. The user had to correct it inline ("The cap is not 5 just keep going, that's a wrong cap"). This section exists to prevent the same projection mistake in dispatch-task too.

For the full version with cross-references and Hermes-gateway WS-budget math, see `~/.smartclaw/skills/agento/SKILL.md` → `## ⚠️ COMMON CONFUSIONS — AO HAS NO WORKER-COUNT CAP`.

## Steps

### 1. Create a GitHub Issue for tracking

GitHub Issues are the canonical tracking surface — visible in the repo, linkable in Slack, no local bead store required.

```bash
# Resolve the correct repo from the task context (default: jleechanorg/jleechanbrain)
REPO="jleechanorg/<repo>"

ISSUE_URL=$(~/.smartclaw/scripts/gh-safe-publish issue create \
  --repo "$REPO" \
  --title "[P1] short task description" \
  --body "## Task
<one paragraph — what, why, acceptance criteria>

## Dispatched
Session: TBD — updated after spawn" \
  --jq '.url')
# Note: omit --label unless you've verified the label exists in the repo.
# To create a label first: gh label create "task" --color 0075ca --repo "$REPO" --force

ISSUE_NUM=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
echo "Issue: $ISSUE_URL"
```

**Priority prefix in title:** `[P0]` / `[P1]` / `[P2]` — matches PR convention.

**If the task maps to an existing open issue:** just note the existing URL; do not create a duplicate.

### 2. Ack in Slack thread (REQUIRED)

**This is the Deterministic Slack Thread Response Contract.**

Record the Slack context from jleechan's original message:
- `SLACK_TRIGGER_TS` = the `ts` field from jleechan's message (e.g. `1772857900.668299`)
- `SLACK_TRIGGER_CHANNEL` = the channel ID (e.g. `C0AH3RY3DK6`)

Reply to jleechan's original Slack message in the same thread:

> On it. Spawning agent for GH issue **#<issue-num>** — will reply here when done. (<issue-url>)

While the dispatched task is active, supervisor/nudge automation must post progress in-thread at least every 5 minutes until done (or blocked).

**Proof-First Requirement**: When the supervisor posts completion, it MUST include at least one reviewable proof URL (PR, commit, or artifact):
- PR URL: `https://github.com/OWNER/REPO/pull/NUMBER`
- Commit URL: `https://github.com/OWNER/REPO/commit/SHA`
- Artifact URL: durable build/test/deploy artifact link
It SHOULD include multiple proof URLs when available (for example, PR + commit). No "task done" without at least one proof URL. See SOUL.md "Autopilot Policy" for the full contract.

### 3. Before dispatching: Search memories

**Always search memories before writing the task prompt.** Use `/mem-search` or the memory MCP to find:
- Past successes/failures for similar tasks
- Specific gotchas or patterns for this type of work
- Any injected context from previous failures

Inject relevant learnings into the task prompt to prevent repeat failures.

### 4. Dispatch via ao

**Before dispatching — verify PR number + project ID.** Always run, do not guess:

```bash
# 1. Resolve PR number (do NOT trust memory — `gh pr view N` returns "Could not resolve" for stale refs)
gh pr view <N> --repo <OWNER>/<REPO> --json number,title,state,headRefName,baseRefName

# 2. Resolve project ID — `ao projects list` does NOT exist (2026-06-28). The working command is:
ao status 2>&1 | grep -E "configKey" | head -10
# OR
grep -E "configKey" ~/.smartclaw_prod/agent-orchestrator.yaml
```

Example IDs: `jleechanbrain`, `worldarchitect`, `mctrl`, `agent-orchestrator`. Always confirm via `ao status` output, not memory.

**Bug-ref 2026-06-28:** in one dispatch I claimed PR #8036 twice without checking. The actual PR was #8023. This burned 2 tool calls and a full task-file rewrite. **Always `gh pr view <N>` first.**

If jleechan explicitly requests Codex (or another agent CLI), use the override flags (`ao spawn --help`); defaults live under `defaults.agent` in `agent-orchestrator.yaml`. Do not fall back to `sessions_spawn`.

Spawn using the GH issue number as the task label, then send the full task body:

```bash
TASK_FILE=$(mktemp)
trap 'rm -f "$TASK_FILE"' EXIT
cat > "$TASK_FILE" <<'TASK'
<full task description enriched with memory learnings>

GH Issue: <issue-url>
TASK

# 1. Create worktree + session (issue number goes into the branch name)
SESSION=$(ao spawn "GH-${ISSUE_NUM}" -p <project-id> | grep -oP '(?<=session: )\S+' || ao spawn "GH-${ISSUE_NUM}" -p <project-id>)

# 2. Send task verbatim (auto-submits — no manual Enter needed)
ao send "${SESSION}" --file "$TASK_FILE"
```

If ao spawn or ao send fails, report the exact error instead of claiming the task was queued.

**Cold-start timeout is normal.** `ao spawn` may time out at the gateway (90–180s) but the session is being created. After a timeout, ALWAYS poll `ao status` to confirm the session exists before retrying:

```bash
# Verify the session actually spawned (do not just retry blindly)
ao status 2>&1 | grep -iE "<issue-num>|<branch-name>"
```

A second spawn while the first is mid-creation can claim the worktree twice.

**Claiming an existing PR (when one is already open):** if the branch and PR already exist (e.g. diagnostic + RED tests are already pushed), use `--claim-pr`:

```bash
# Existing PR — claim it instead of creating a new worktree
ao spawn --project worldarchitect --claim-pr 8023
# Cold-start may take 90-180s; gateway timeout is normal
# Then send the task:
ao send wa-2971 --file /tmp/ao_task_8023.md
```

Use `--claim-pr` when:
- A branch is already on `origin/<headRefName>` and you want to drive the existing PR to green.
- You do NOT want a fresh worktree (the existing worktree has RED tests, references, and prior commits).

Use plain `ao spawn` (no `--claim-pr`) when:
- This is a new task that doesn't have a branch yet.
- The current branch is unrelated and you need an isolated worktree.

For GitHub/PR automation, the lifecycle lane should map directly into this
dispatch path. `comment-validation`, `fix-comment`, and `fixpr` are mctrl
lanes, not Mission Control board tasks.

### Cross-repo PRs

When the task involves making a PR to a different repo than the worktree:
- DO NOT clone the target repo into a subdirectory
- Use `gh pr create --repo owner/repo --base main --head <branch>` to PR cross-repo
- Example: for mctrl_test repo, use `gh pr create --repo jleechanorg/mctrl_test --base main`

Ensure the task text instructs the agent to push before it stops. Include wording like:

> After making and committing the change, run `git push origin <branch>` and only then stop.

### 5. Confirm dispatch

The `ao spawn` command prints the session name. Note it, then update the GH issue body with the session name so anyone looking at the issue sees the live tracking link:

```bash
~/.smartclaw/scripts/gh-safe-publish issue comment "$ISSUE_URL" \
  --body "Dispatched to AO session \`${SESSION}\`.
slack_trigger_ts=${SLACK_TRIGGER_TS} slack_trigger_channel=${SLACK_TRIGGER_CHANNEL}
Supervisor watching."
```

The mctrl supervisor reads `slack_trigger_ts` and `slack_trigger_channel` from the GH issue comment to post the completion reply in the correct Slack thread. Always include the GH issue URL in the Slack ack so jleechan can click through to see full task context.

## What happens next (automatic)

The mctrl supervisor loop (`ai.mctrl.supervisor` launchd agent) runs every 30s and:
1. Checks if the tmux session is still alive
2. When session ends: checks `git log start_sha..HEAD` for commits and verifies the branch is reachable on a configured remote
3. Posts DM to jleechan + thread reply under the original Slack message; during long runs, periodic in-thread progress updates should be emitted at least every 5 minutes
4. Sends MCP Agent Mail notification to Hermes

**You do not need to poll.** The supervisor handles completion notification, but it will only classify the task as finished if the review surface exists on remote.

## Notes

- `ao spawn` creates an isolated git worktree for each task automatically (configured in `agent-orchestrator.yaml`)
- Finished means remote-reviewable on a configured remote, not merely committed locally inside the worktree
- If `ao spawn` fails, check that `ao` is on PATH and agent-orchestrator is properly configured
