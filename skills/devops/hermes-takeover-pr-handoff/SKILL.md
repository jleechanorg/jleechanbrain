---
name: hermes-takeover-pr-handoff
description: 'Use when an agent hands off a PR to babysit'
---

# Hermes PR Takeover Handoff

When another agent (or a prior Hermes session) finishes work on a PR and hands it off with a "take over / babysit / drive to green" message, the **default Hermes action** is:
1. Verify live state against the handoff claim (do NOT trust the report).
2. Install (or confirm) a self-cancelling babysit cron that watches the gates.
3. Post **one** consolidated Slack ack in-thread with: live-state vs. report, cron ID + contract, named follow-ups, silence contract.
4. Do not double-post. Do not narrate intermediate tool calls into Slack.

This skill defines that contract.

## When this skill fires

- Inbound Slack message saying "take over", "babysit PR #N", "monitor PR #N", or a "Phase complete" handoff claiming a PR is "done from my side" with a follow-up gate still open.
- Self-handoff across long-running sessions: a prior session left a babysit cron and a new session must inherit it cleanly.
- Ironclad-style ":checkered_flag: Final status — takeover complete" messages that surface real open follow-up beads.

## Handoff handshake: 5-step verification

Run these in parallel BEFORE posting the in-thread ack. Do not trust the handoff's stated head/check state.

| # | What | Command / Tool |
|---|------|----------------|
| 1 | PR head SHA | `gh pr view <N> --repo <repo> --json headRefOid,headRefName,author,state,mergeable,isDraft,additions,changedFiles` |
| 2 | Check rollup | same call's `statusCheckRollup[]` → tally by `(status, conclusion)` |
| 3 | Existing babysit cron | `hermes cron list \| grep -B0 -A8 "<N>"` |
| 4 | PR comments (CR/Bugbot) | `gh api repos/<owner>/<repo>/issues/<N>/comments --jq '...'` |
| 5 | Local artifact paths referenced in handoff | only verify if handoff names explicit absolute paths; otherwise just `ls` the parent |

If any field diverges from the handoff claim, surface it in the ack — do not silently overwrite.

## Self-cancelling babysit cron — mandatory install

If no active babysit cron exists for this PR, install one. Required shape:

```
hermes cron create "<schedule>" \
  --name "babysit-pr-<N>-<topic>-<gate>" \
  --deliver "slack:<channel>:<thread_ts>" \
  --repeat <count>
```

Contract the cron prompt MUST include verbatim:
- Tick rate: every 10m (matches the agent cadence + ironclad skill's "5-min progress" cadence)
- Ceiling: 144 ticks (= 24h)
- Self-cancel: on every tick run `gh pr view <N> --json state`; if `state in {MERGED, CLOSED}` (not merged), run `hermes cron remove <job_id>` (script must receive `--cron-job-id` in `enabled_toolsets` args or via prompt body) + post a single closeout message + return `[SILENT]` thereafter
- Compact target: deliver to the originating user thread; **never** channel-root when there's a thread context, AND **never** home-channel (`#ai-general`) for a PR that originated in another channel

## Ack template — non-negotiable shape

Post ONE message via `slack_post_message "CHANNEL" "$(cat /tmp/ack.txt)" "THREAD_TS"` from `~/.smartclaw/scripts/lib-slack-post.sh`. Do not post via raw `curl … chat.postMessage` — the secret-gate shell block will reject the bearer token construction.

```
:white_check_mark: *Takeover-final ack — PR #N <one-line topic> — <gate-state summary>*

*Live state (verified <HH:MMZ>):*
• PR <STATE> / <MERGEABLE> / <DRAFT|READY>, head `<short-SHA>` (matches handoff: yes/no)
• Author: <login>
• Commits on PR: <count> (<short-SHA-1> impl, <short-SHA-2> evidence, …)
• Checkrollup: <PASS>/<SKIPPED>/<QUEUED>/<FAIL> — call out skipped as "correctly skipped", not failed
• CodeRabbit / Bugbot: <state>

*Babysit cron:* `<job_id>` — `<name>`, every 10m × 144 ticks (24h ceiling), delivers to this thread. Self-cancels on PR MERGED/CLOSED. Next tick <HH:MM TZ>.

*<N> follow-ups I am NOT auto-fixing (per handoff):*
1. :large_yellow_circle: <gate name> (`<bead-id>`) — <blocking reason>; only post on transition
2. :large_yellow_circle: <other real-bug follow-up> (`<bead-id>`) — <one-line description>

*Silence contract:* I only ping this thread on (a) check transition, (b) head SHA drift, (c) queue drain, (d) PR MERGED/CLOSED. All other ticks → `[SILENT]`. No more intermediate bot posts.

*<Optional: single concrete decision question OR "no open asks">*
```

**Hard rules:**
- ONE Slack post per turn. No cron-create output echo, no cron-update echo, no separate "let me check that" posts. Cron tool output goes to stdout for the agent log only.
- Each tick of the babysit cron posts AT MOST ONE ping. Multiple state changes in one tick collapse into one ping.
- If the user asked "should I do X?", reply with a "should I do X?" question and a default — DO NOT pick-one-menus with 2-4 options (per SOUL.md `no-pick-one-menus`).

## Posting the ack — the right way

```bash
cat > /tmp/<pr>-final-ack.txt <<'TXT'
... ack body ...
TXT
source ~/.smartclaw/scripts/lib-slack-post.sh 2>/dev/null
slack_post_message "<CHANNEL_ID>" "$(cat /tmp/<pr>-final-ack.txt)" "<THREAD_TS>"
```

The script handles SLACK_BOT_TOKEN resolution via the launchd-env-wrapper contract. Raw `curl -H "Authorization: Bearer $(grep … .bashrc | sed …)"` is BLOCKED at the shell layer (outbound-secret-publication-gate). The MCP `mcp__slack__conversations_add_message` may or may not be loaded in the current runtime — fall back to `lib-slack-post.sh` when it isn't.

## Pitfalls

1. **5b-leak misroute** — sending to home channel (`#ai-general`) when the user is in a different thread. The babysit cron `deliver` arg MUST be the user's originating channel + thread_ts (`slack:CHAN:THREAD_TS`). Do not omit thread_ts.
2. **Babysit cron never cancels** — when the cron prompt lacks the verbatim self-cancel clause (per `babysit-cron-self-cancel-discipline`), the cron keeps ticking after merge, spamming the thread. Always include the clause AND pass `--cron-job-id` so the script's `cronjob_remove()` is callable from tick code.
3. **Trusting handoff state** — agents (and prior sessions) lie or are stale. Always re-run the 5-step verification in parallel BEFORE posting the ack. Divergence = call it out in the ack, don't paper over it.
4. **Double-posting bot noise** — intermediate cron-create / cron-update output leaking as separate Slack posts. The fix is one consolidated final reply, not 3-5 acks. Cron tool output should go to agent stdout, not Slack.
5. **Pick-one menus in the ack** — "want me to A, B, or C?" when the handoff has open follow-ups violates `no-pick-one-menus`. Use the ack template's optional "single concrete decision question" slot, OR list the open asks as "I am NOT auto-fixing" with one named operator-decision question at the bottom.
6. **Recurring cron without ceiling** — bare `--every 10m` (no `--repeat`) creates an indefinitely-repeating cron. For PR babysits, use `every 10m × 144 ticks`. The 144 ceiling prevents indefinite tick spam if the PR just sits open past merge.
7. **Cron list empty after install** — `hermes cron list` is eventually consistent; immediately after `create`, the job may not appear for a few seconds. Don't loop trying to verify. Trust the `create` return value's `cron_job_id`.

## Pre-stop self-audit

Before sending the ack, verify against the ironclad skill's "structurally unreachable" rule:
- If the gate is a runner pool / external dep the agent cannot unblock, surface that EXPLICITLY in the ack. Do not pretend CI is "green enough".
- If the PR has a real prod bug in the handoff's open-follow-up list, surface it but DO NOT auto-fix without explicit user "go" — it's part of the handoff's deferral.

## Companion skills

- `babysit-stale-watchdog` — detects enabled babysits whose referenced PR is MERGED/CLOSED; reaps them within 30 min.
- `slack-thread-routing-investigation` — for the case where a Slack reply "didn't go to the right thread" (5b-leak class).
- `evidence-attach-to-slack` — required if the takeover ack needs to attach screenshot/PDF evidence.

## When YOU (the agent) just opened the PR and discover the infra block (added 2026-08-06, PR #815)

Distinct from the handoff-from-other-agent case above: the PR's branch is your own, the head SHA is your own, no prior session handed it off. The classic trigger shape: you pushed a small fix → opened the PR → CI is queued forever → `gh api orgs/jleechanorg/actions/runners` reveals the runner pool is 9/10 offline. The fix is sound; the merge is blocked by infrastructure you don't own.

**Why this is NOT a takeover.** Takeover assumes someone else's handoff claim needs verification. Here there is no handoff claim — you're the author. You already know the head SHA, the diff, and the intent. The handoff skill's 5-step verification handshake is overkill (steps 1+3 still apply: confirm PR is open and confirm no existing cron covers it; steps 2+4+5 don't add signal when you wrote the code).

**The 5-step self-arm recipe (verified PR #815, 2026-08-06, branch `fix/cost-monitor-self-hosted-rates` head `d176fba541`):**

1. **Confirm the code is sound and the PR is open.** `gh api repos/<owner>/<repo>/pulls/<N> --jq '{state, mergeable, head_sha: .head.sha, draft}'`. `mergeable: true` + `state: open` means the PR is ready to merge once CI clears.

2. **Confirm the blocker is structural, not code-fixable.** `gh api "repos/<owner>/<repo>/actions/runs?head_sha=<HEAD>&per_page=30" --jq '[.workflow_runs[] | {name, status, conclusion, event}]'`. If all CI runs are `queued`/`pending` AND `gh api orgs/<org>/actions/runners --jq '[.runners[] | select(.status=="online")] | length'` is < 2, the pool is structurally saturated — not a code issue. **Do not start editing code to "fix" the CI.** The CI hasn't even run; there is nothing to fix yet.

3. **Open a separate bead for the blocker (P1 if blocking active PRs).** Use `br create` with `--type incident` + provenance: PR number, runner pool state, runbook reference. This separates your PR's code state from the infra incident — the cron will close when your PR merges; the bead closes when the runner pool is back online.

4. **Self-arm the babysit cron — but pass the cron_job_id back into the prompt.** Per `babysit-ao-pr-loop` Phase -0.5 (pre-create dedup), check `hermes cron list` for existing crons on the same PR / thread first. If none, create:

   ```bash
   JOB_ID=$(hermes cron create "10m" \
     --name "babysit pr-<N> <topic>-ci-pool" \
     --deliver "slack:<ORIGINATING_CHANNEL>:<THREAD_TS>" \
     --repeat 1)
   ```

   Then **patch the prompt with the job_id via `cronjob action=update`** so the babysit knows its own handle and can self-cancel on PR MERGED. Without this, the prompt's "issue `hermes cron remove <id>`" clause has no `<id>` to issue against.

   The cron prompt contract MUST include (verified on PR #815):
   - "Watch CI → when all 7 checks are SUCCESS, run `gh pr merge <N> --squash --delete-branch`"
   - "After merge, run `cd ~/.smartclaw && bash scripts/deploy.sh`"
   - "On terminal state, `hermes cron remove $CRON_JOB_ID` (the prompt receives it via update)"
   - "Do NOT spawn subagents, do NOT propose code fixes (this is a structural-wait babysit)"
   - "If infra drains but CI fails for code-actionable reasons, post ONE premise-divergence notification + self-cancel + hand off" (per `babysit-ao-pr-loop` v1.9.0 premise-mismatch protocol)

5. **Post ONE terminal status to the thread. Go silent.** The user explicitly does not want repeat status pings (per memory: "I'll stop replying until you send something new, otherwise I'm just burning turns"). The dropped-thread followup cron will fire if you go fully silent; the right counter is ONE concise message naming the PR, the babysit cron ID, the runner-outage bead, and the structural-vs-code diagnosis. After that: `[SILENT]` until the babysit reports the merge + deploy.

**Anti-patterns (verified PR #815, 2026-08-06):**

- ❌ **Spawning an ops-heal worker to fix the runner pool.** That's scope creep. Open the bead for the operator (or a future ops-heal cron); do not expand your task into "fix the entire CI fleet."
- ❌ **Re-pushing the same commit to "kick" the CI queue.** Force-push resets all queued runs and pushes the green signal further back. Wait for the pool to drain; do not perturb.
- ❌ **Posting 3-5 progress pings as CI ticks from queued → pending → in_progress.** One terminal status, then silence. The dropped-thread followup cron will re-fire every 30 min if you go silent — that's the operator signal, not your signal.
- ❌ **Trusting the GitHub UI's CI status icon.** Green Gate shows a yellow clock icon for self-hosted runners queued >5 min. The real state is in `actions/runs` API; use that.
- ❌ **Merging the PR "anyway" with `--admin` or bypassing checks.** That violates the project's skeptic-cron auto-merge contract. The PR must pass the 7-green criteria before merge — even if the only failing gate is "runner pool is empty."

**What this is NOT a fix for:**

- "The CI failed for a real code reason (test red, lint error, typecheck)." That's `drive-pr-to-green`, not this recipe.
- "The merge-conflict is stale because main has advanced." That's a worktree-rebase fix, not infra.
- "The CR bot left a CHANGES_REQUESTED review that's actually blocking." That's `drive-pr-to-green` Step 8.

**Reference:**

- `references/pr-815-self-arm-infra-block-2026-08-06.md` — worked example for this recipe: PR #815 (cost-monitor fix), branch `fix/cost-monitor-self-hosted-rates`, head `d176fba541`, runner pool 9/10 offline, babysit cron `845b20b295bc`, runner-outage bead `jleechan-rza`. Includes the cron prompt body verbatim (the `--repeat 1` shape, the self-cancel clause, the deploy-sh invocation).

## Reference files

- `references/pr-8794-takeover-session-2026-08-05.md` — live session where this skill was first applied: 8794 takeover with `rev-997f4` runner-pool blocker + `rev-ct16e` race deferral. Use as a worked example for the next takeover — PR state, cron ID, deferred follow-ups, and the lessons captured from this session (cron ID verification, runner-pool saturation language, repo-vs-local queue distinction) are all in the reference doc.
- `references/pr-815-self-arm-infra-block-2026-08-06.md` (added 2026-08-06) — "When YOU just opened the PR and discover the infra block" worked example. PR #815 (`fix/cost-monitor-self-hosted-rates`, head `d176fba541`), runner pool 9/10 offline (only `ez-mac-runner-b-3` online, busy), babysit cron `845b20b295bc` (10m cadence, deliver `slack:${SLACK_CHANNEL_ID}:1785905655.111039`), runner-outage bead `jleechan-rza` (P1). Includes the verbatim cron prompt body, the `cronjob action=update` patch that threads the job_id into the prompt, the one terminal status posted to the parent thread, and the "go silent" reasoning (user explicitly banned repeat pings). Use this when YOU are the PR author and CI is blocked by infra you don't own.
- `references/pr-9150-ready-audit-2026-08-22.md` (added 2026-08-22) — `/ready` audit applied to PR #9150 (drop color-coded `risk_level` from planning block). Captures 4 new pitfalls the canonical `pr-ready-checklist` skill is missing (P1: empty `conclusion` is not a failure; P2: Evidence Gate is N/A when the workflow doesn't trigger; P3: same-name pre-existing reproduction recipe end-to-end; P4: GraphQL `resolveReviewThread` for chatgpt-codex-connector threads with comment-then-resolve ordering). Also documents the prompt-contract-hash refresh substep (`scripts/validate_prompt_tool_contracts.py --update`) that `drive-pr-to-green` Step 5 is missing. Use this when the loaded `pr-ready-checklist` skill returns false-positive Gate 3 / Gate 8 failures.

## Companion harness contracts

- `cron.silence_default` — babysit ticks default to `[SILENT]` unless transition event fires.
- `cron.max_ticks_default` — 144 (= 24h at 10m cadence).
- `cron.deliver_default` — `slack:<originating_channel>:<originating_thread_ts>`, never channel-root.
