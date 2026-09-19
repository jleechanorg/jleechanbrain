---
name: babysit-ao-pr-loop
version: 1.10.0
description: "Run a recurring cron-tick babysit loop that watches a single GitHub Actions run id OR AO worker driving a PR. v1.10.0 (2026-08-06) adds the 'all-gates' gate-check contract and the `actions/runs/<id>/timing` 0-billable-duration diagnostic to the runner-pool sub-class — never trust the cron prompt's enumerated gate list as exhaustive (always iterate ALL check-runs on the live head SHA), and use the timing endpoint to distinguish 'CI ran and failed' (real bug, premise lifted) from 'CI never started' (infra, premise intact). v1.9.0 adds the 'premise-mismatch self-cancel' protocol. v1.8.0 adds the runner-pool sub-class. v1.7.0 adds 'stale thread_ts'. v1.6.0 adds 'run id drift'. v1.5.0 adds Phase -0.5 pre-create dedup. v1.4.0 added deploy-run sub-class."
trigger:
  - babysit wa-
  - watch PR <num>
  - tick loop on PR <num>
  - smoke test PR <num> deploy
  - cron job babysitting an AO worker
  - cron job waiting on a deploy run + smoke test
changelog:
  - "1.9.0 (2026-08-06): Add the 'premise-mismatch self-cancel' protocol to the runner-pool sub-class (new subsection below). When the structural-not-fixable premise lifts mid-loop (pool drains AND CI runs and fails for code-actionable reasons), the cron prompt's 'do NOT propose code fixes' instruction is no longer authoritative — the babysit is observe-only by design and cannot drive fixes. Verified PR #8794 cron `b6c8887f546e` first tick 2026-08-06 11:52Z: pool 152/3 → 1/0, head drifted a3c3c19e → 930210ca, CI on new head had 5 fixable failures (Tests Required Gate, Directory tests core-tests + core-mvp-1/2/3 self-hosted, Playwright auth browser tests, Mobile Auth Same-Origin Regression, beads-jsonl-validation). Correct action: post ONE premise-divergence notification listing the 5 fixable failures, self-cancel, let drive-pr-to-green take over. Also corrected Phase 0.5 primary self-cancel to `hermes cron remove <id>` (cronjob CLI is not installed on this host; verified 2026-08-06 — `cronjob action=remove` returns 'command not found', `hermes cron remove b6c8887f546e` returned `Removed job: babysit-pr-8794-share-url-phase1-ci-pool (b6c8887f546e)` on first try)."
  - "1.10.0 (2026-08-06): Two corrections to the runner-pool sub-class, both verified PR #815 (cost-monitor self-hosted rates, head `d176fba541`), 2026-08-06. (1) 'All-gates' gate-check contract — never trust the cron prompt's enumerated gate list as exhaustive. The merge-readiness check MUST iterate ALL check-runs on the live head SHA (`commits/<HEAD_SHA>/check-runs`) and treat any non-success terminal state (failure/cancelled) as blocking. The cron prompt named three gates (Green Gate, Staging Canary Gate, Staging Canary Full) but a 4th — 'Example discipline' — had failed with `status=completed, conclusion=failure, billable duration=0ms` (queued on ubuntu-latest, never executed, then cancelled by 15-min platform timeout). The prompt's gate list was incomplete. The fix: the merge-readiness predicate is `ALL(check_runs[].conclusion in {success, skipped, neutral} for name in check_runs) AND no queued/in_progress`, not `the gates the prompt named are success`. (2) `actions/runs/<id>/timing` reveals 0-billable-duration failures — when `billable.<OS>.job_runs[].duration_ms == 0` AND `run_duration_ms > 0`, the job was queued and never started (runner-pool exhaustion or platform cancellation). Distinct from a real code failure (where duration_ms > 0). Add this as a Phase 1.5 diagnostic probe to distinguish 'CI ran and failed' (premise lifted — hand off to drive-pr-to-green) from 'CI never ran' (infra, premise intact)."
  - "1.8.0 (2026-08-06): Add the runner-pool / CI-clearance babysit sub-class. A structurally-not-fixable PR has no AO worker to nudge and no code path to fix — the only thing the babysit can do is observe the runner pool and surface meaningful state changes (queue drain, head drift, queue growth). Verified PR #8794 (feat/campaign-share-url-phase1, head 930210ca, branch tip 77652b09, 7 unpushed-to-PR commits), 2026-08-06. The PR's headRefOid lags behind the actual branch tip because the takeover worker force-pushed without re-advancing the PR ref — the babysit must use the LIVE `gh api repos/<owner>/<repo>/pulls/<N>` head + the live branch-tip commit list (via `/pulls/<N>/commits`) to detect drift, not just the SHA baked into the cron prompt. Documented new sub-class, working example, and the GH CLI GraphQL→REST fallback for rate-limited basic-auth sessions."
  - "1.7.0 (2026-08-06): Add 'stale thread_ts in cron prompt' recipe. When the cron prompt hardcodes a `thread_ts` that returns `thread_not_found` across the obvious channels, run the side-channel ladder (C0AUXSVFSA2 → ${SLACK_CHANNEL_ID} → C0AJQ5M0A0Y → ${SLACK_CHANNEL_ID} → C0BA4MCBPFB → C0AQJT7KSP2) before declaring the thread unreachable. C0AUXSVFSA2 is the canonical home for PR #8787-class verification threads (wa-cloud-logging-diag v1.2.0). When the prompt's thread_ts is unrecoverable, fall back to the existing related thread (e.g. `1785998369.940599` for PR #8787) and document the fallback in the post body. Verified PR #8787 final cron tick 2026-08-06."
  - "1.6.0 (2026-08-06): Add 'run id drift' recipe to the deploy-run babysit sub-class. When a worker force-pushes between cron creation and first tick, the original `actions/runs/<id>` becomes `completed/cancelled` (replaced by a new run on the same branch with a larger id). Naively polling the original id produces either 'completed/cancelled' forever (silently parked) or — worse — a false-positive 'completed' that triggers the smoke test against the OLD bundle from the previous deploy. The fix: each tick, after probing the original run id, if status is `completed/cancelled` AND `conclusion=cancelled` AND `created_at` is significantly older than the PR's `updated_at`, treat it as drift and re-discover the current deploy run for the branch via `actions/runs?branch=<branch>&name=Deploy PR Preview (Rotating Pool)&status=queued|in_progress`. Verified PR #8787 cron, 2026-08-06: original run 31072371181 was cancelled at 05:44:04Z by a force-push (head da1d95fe9d → 0a9d234a); new run 31075008771 was discovered and is now being monitored. Cancel-detection recipe is detailed in the new 'Run id drift (force-push between cron creation and first tick)' subsection under the deploy-run sub-class."
  - "1.5.0 (2026-08-06): Add Phase -0.5 pre-create dedup check. Before `cronjob create`, filter `cronjob list` by PR number / thread_ts; if an existing cron already covers the target, reuse it (or `cronjob update` its prompt) instead of creating a duplicate. Verified PR #8787 — caught a duplicate-spawn before the cron was created. Adds two SHA-survival recipes for prompts that must reference a specific SHA (live-fetch by PR number, or self-fetch on each tick)."
  - "1.4.0 (2026-08-06): Add the 'deploy-run babysit' sub-class (Section §Deploy-run babysit sub-class). Same cron shape as AO-worker babysits, but the wait condition is `actions/runs/<id>` status transition (queued→in_progress→completed) and on-completion the cron must execute a payload against the deploy artifact (smoke test, bundle grep, Cloud Logging verification). Adds queue-position estimation recipe (`gh api actions/runs?status=queued&page=N` paginated count + `id <= target_id` filter → position + ETA). Adds cron-context Path B fallback for `slack-thread-routing-investigation` Failure 5f: when `mcp__slack__conversations_add_message` is not in the runtime tool list AND `SLACK_BOT_TOKEN` is not in env but `SLACK_BOT_TOKEN` IS in env AND the target channel is the bot's home workspace (e.g. #worldai = C0AH3RY3DK6, bot home = T09FXQ4LCQP), use Path B curl with `SLACK_BOT_TOKEN` directly — no xoxp fallback needed. Verified on PR #8787 deploy-run smoke-test cron, 2026-08-06, Slack post at ts 1785994442.274029 in thread 1785990587.321239 (correctly threaded, ok:true)."
  - "1.2.0 (2026-07-05): Add the executable self-cancel contract — every babysit prompt MUST invoke `babysit.py poll` (or `babysit.py babysit`) with `--cron-job-id $CRON_JOB_ID`. babysit.py gained a `cronjob_remove(job_id)` helper + `--cron-job-id` CLI arg + integration in the `is_pr_terminal` branch. Regression suite `skills/ao-babysit/scripts/test_babysit_self_cancel.py` (11 tests) enforces the contract. Bug-ref: 2026-07-05 thread C0AH3RY3DK6/p1783279995 — even after the v1.1.0 fix landed, babysit cron spam continued because the prompt-level self-cancel clause was unreachable: babysit.py had no way to know its own job_id."
  - "1.1.0 (2026-07-05): Add Phase 0.5 — terminal-state SELF-CANCEL via `cronjob action=remove job_id=$CRON_JOB_ID` (or `launchctl bootout` for launchd-managed babysits). Reference the `babysit-stale-watchdog` companion (every 30 min launchd watchdog at scripts/babysit_stale_watchdog.py) which catches stale babysits even if the in-script check is broken. Document the failure mode the 2026-07-05 babysit-wa-2403-PR7711 leak exposed: 251 polls over 9 days after PR #7711 merged because the original `babysit.py` only recognized 'PR created' as terminal, not 'PR MERGED on GitHub'. Bug-ref: thread C0AH3RY3DK6/p1783240445.370119."
  - "1.0.0 (2026-07-04): Initial authoring (existed on dirty staging branch dev1783194285; first landed on origin/main via cherry-pick of commit 7690435707 in PR replay b2ad00770d)."
---

# babysit-ao-pr-loop

A scheduled cron job ticks every N minutes on a single PR + AO worker pair. Each tick observes (does NOT modify or push) and posts a concise status update to a pre-known Slack thread. The loop is finite — it must terminate cleanly when the work is done, and stay quiet when nothing changed.

## When to load

- A scheduled cron job is targeting a single PR + worker session (e.g. `babysit wa-2403 on PR #7711`).
- A user asks you to "watch PR N", "tick loop on PR N", or "babysit worker wa-NNNN".
- You are inheriting an existing babysit loop mid-life and need to keep its cadence without re-creating its contract.

Do NOT load for: one-shot `agento_report` aggregations (use `agento_report`), PR bring-to-green interactive loops (use `drive-pr-to-green` / `finish-the-job`), full-time babysitting of a launched dev server or browser session (different domain).

## The contract (each tick)

Each tick has exactly five phases. Do them in this order, every tick:

### Phase 0 — Pre-flight (early-exit; run BEFORE composing any output)

Run these three checks. If ANY short-circuits the loop, do NOT post, do NOT nudge — produce the single suppression token or the single terminal message and exit.

1. **Is the work already done?**
   ```bash
   gh pr view <PR> --repo <OWNER>/<REPO> --json state,mergedAt,closedAt 2>&1
   ```
   - `state == "MERGED"` → terminal: post ONE single-line final message to the thread (e.g. `✅ PR <N> merged on <mergedAt>. Loop closing.`) and exit. Do not run subsequent ticks.
   - `state == "CLOSED"` (not merged) → terminal: post ONE escalation asking the user whether to keep the loop alive or stop it (your call: which is more useful here is up to the operator, but default to "stop, ask user"). Do not re-tick on your own.
2. **Is the worker session still alive?**
   ```bash
   ao session ls 2>&1 | grep -E "wa-<id>|<session_label>"
   ```
   - If the worker is gone AND the PR is not yet merged → terminal: post ONE final message noting the worker died, worker session no longer in `ao session ls`, and the loop is closing pending operator direction. Do not auto-respawn.
   - If the worker is gone AND the PR is already merged → terminal: post ONE final message acknowledging both ends and exit.
3. **Did anything actually change since the last tick?**
   - Compare current `git log origin/<base>..HEAD --since="<last_tick_ts>" --oneline` to the last-tick reading. If empty AND no new commit lands on `origin/<branch>` AND no new `ao` state change AND no CI rerun finished → suppress the full status update. Reply with the literal token `HEARTBEAT_OK` (the cron playbook contract) — do NOT post to Slack. If the cron also says "if absolutely nothing new, reply [SILENT]" and you have an empty commit delta AND no in-thread message is required → reply exactly `[SILENT]` per the cron playbook SILENT contract.

   ⚠️ **Pitfall — duplicate closeouts.** A common failure mode is two consecutive babysit ticks each independently noticing "work is done" and each posting a full closeout. After the FIRST tick posts the terminal message, every subsequent tick MUST short-circuit at Phase 0 step 1 even if `mergedAt` was already reported. Do not "refresh" a closeout. The first tick owns the close; subsequent ticks own silence.

### Phase -0.5 — Pre-create dedup check (added 2026-08-06, PR #8787)

**Before creating a new babysit cron**, verify no existing cron is already covering the same PR / thread. Hot PRs (driven to green across multiple sessions) often have 1-3 crons already targeting the same thread at different cadence. Adding another creates duplicate Slack posts per tick (operator calls this "noise") and multiplies `gh api` rate-limit load.

```bash
# Filter crons by the target PR or thread
hermes cron list --json | jq -r '.jobs[]
  | select((.deliver | test("<PR_NUMBER>|<THREAD_TS>"; "i"))
        or  (.name   | test("<PR_NUMBER>"; "i"))
        or  (.prompt_preview | test("<PR_NUMBER>|<thread_ts>")))
  | {id, name, schedule, deliver, last_run_at, enabled, state}'
```

**Decision matrix:**

| Existing cron state | Action |
|---|---|
| **No match** | Create new cron (this skill's normal path) |
| **Match, prompt still relevant** | Leave it; do NOT create a duplicate |
| **Match, prompt bakes old head SHA** | `cronjob action=update job_id=<existing>` to refresh prompt with the new SHA — do not spawn a 2nd |
| **Match, prompt stale / wrong target** | `cronjob action=remove job_id=<existing>` THEN create new |

**Anti-pattern (verified 2026-08-06, PR #8787):** on a hot PR being driven to green, the assistant spawned a fresh `cronjob create` for "PR 8787 funnel-diag rerun poll (5m)" without first checking `cronjob list`. An existing cron `e0a42c31dce5` ("PR 8787 retry: smoke test on runner pickup") was already running on the same thread at 10-min cadence. Creating the duplicate would have produced two Slack posts per tick + double the `gh api` load. Caught at the dedup check (added in this patch) before the duplicate was created.

**Two recipes that survive SHA changes** (so the prompt does not go stale on the next force-push):

1. Reference the PR number, not the SHA — let the cron read live state. Example: `gh api repos/<owner>/<repo>/pulls/<N>` returns the current `head_sha` each tick.
2. Self-fetch the head on each tick: `gh pr view <N> --json headRefOid -q .headRefOid` before any wait-condition check.

**If the prompt MUST reference the SHA** (e.g. it documents a specific run id like a deploy-run babysit), include both the SHA AND the live-fetch recipe in the prompt so the cron can refresh itself on each tick rather than baking the stale SHA into every post.

### Phase 0.5 — SELF-CANCEL on terminal state (added 2026-07-05, v1.1.0)

After posting the terminal closeout in Phase 0 step 1 or step 2, the cron MUST also remove itself so no further ticks fire. The 2026-07-05 babysit-wa-2403-PR7711 incident exposed the failure mode: the cron reported MERGED every tick for 9+ days but never called `cronjob action=remove` on itself, producing 251 polls of duplicate closeouts to the same Slack thread.

**Mandatory self-cancel clause** — every babysit cron prompt MUST include this verbatim (the agent prompt, not just the skill):

```
After posting the Phase 0 terminal closeout, immediately call:

  hermes cron remove $CRON_JOB_ID

If `hermes cron remove` is unavailable (older environment, launchd-managed babysit), fall back to:

  cronjob action=remove job_id=$CRON_JOB_ID

If neither command is available, fall back to:

  launchctl bootout gui/$(id -u)/<label>

If none of the above work, set Disabled=true in the plist template
and notify the operator to remove it manually. Then emit [SILENT] on
all subsequent ticks.
```

**Verified 2026-08-06 (PR #8794 cron `b6c8887f546e`):** `cronjob action=remove job_id=b6c8887f546e` returns `bash: line 1: cronjob: command not found` (the cronjob CLI is NOT installed on this host); `hermes cron remove b6c8887f546e` returned `Removed job: babysit-pr-8794-share-url-phase1-ci-pool (b6c8887f546e)` on first try. **Use `hermes cron remove` as the primary path on this host.** The historical v1.1.0 documentation that listed `cronjob` first was correct for environments that ship the cronjob CLI; it is wrong for the current `/Users/jleechan` host.

**Executable contract (added 2026-07-05, v1.2.0)** — the prompt-level clause above is necessary but not sufficient. The babysit MUST invoke `babysit.py poll` (or `babysit.py babysit`) with `--cron-job-id $CRON_JOB_ID` so the script can issue `cronjob action=remove` itself on terminal-PR detection. Without `--cron-job-id`, the prompt's "issue cronjob action=remove" instruction is unreachable from the script and the cron will leak past terminal-state until the watchdog catches it (up to 30 min).

Canonical prompt excerpt:

```bash
# Find this babysit's cron job_id once, then pass it to babysit.py on every tick
JOB_ID=$(cronjob list | jq -r '.jobs[] | select(.name=="<this babysit name>") | .id')
python3 ~/.smartclaw/skills/ao-babysit/scripts/babysit.py poll \
    --session "$SESSION_ID" \
    --slack-channel "$CHANNEL" \
    --slack-thread-ts "$THREAD_TS" \
    --task-summary "<task summary text including PR URL or PR #NNNN>" \
    --cron-job-id "$JOB_ID"
```

**Regression contract:** `skills/ao-babysit/scripts/test_babysit_self_cancel.py` enforces the executable side — that `babysit.py` defines `cronjob_remove()`, exposes `--cron-job-id` on both subcommands, and `poll()` invokes `cronjob_remove(cron_job_id)` in the terminal-PR branch. 11/11 tests pass; any future regression to babysit.py that drops the self-cancel plumbing fails the suite.

**Companion watchdog:** `~/.smartclaw/skills/babysit-stale-watchdog/SKILL.md`
ships a launchd plist (`ai.smartclaw.schedule.babysit-stale-watchdog`)
that runs every 30 min and disables any babysit cron whose referenced
PR is MERGED/CLOSED, even if the in-script Phase 0.5 self-cancel is
broken, missing, or running against an old prompt version. The
watchdog is the safety net; the in-script Phase 0.5 is the fast path.
Both layers are required.

**Audit recipe** for existing babysit crons that pre-date Phase 0.5
(the v1.0.0 babysit cron registry may have un-self-cancelled jobs):

```bash
cronjob list | jq '.jobs[] | select(.enabled and (.name|test("babysit|wa-[0-9]")))'
# For each match: gh pr view <PR-ref> --json state,mergedAt
# If MERGED or CLOSED, run: cronjob action=remove job_id=<id>
```

### Phase 1 — Observe (only if Phase 0 did NOT early-exit)

Run these and only these. Do NOT modify code; do NOT push; do NOT amend commits; do NOT call `ao send` or `git commit`.

1. **`git log origin/<base>..HEAD --oneline`** — what has the worker committed?
2. **`git status`** — any uncommitted work? (Untracked artifacts in the worktree like `.beads/.write.lock`, `specs/skeptic-report.json`, `ADVERSARIAL_REVIEW_*.md` are NORMAL residue from prior ticks, not new work. Do not flag them as "uncommitted work" unless they are fresh files on the fix-related paths.)
3. **`ao session ls | grep <session>`** — worker state (`working` / `pr_open` / `spawning` / `killed`).
4. **`gh pr view <PR> --repo <OWNER>/<REPO> --json headRefName,state,mergeable,commits,mergedAt`** — PR state.
5. **`gh pr checks <PR> --repo <OWNER>/<REPO>`** — CI state (only if Phase 0 didn't early-exit AND worker has pushed since last tick).
6. **`git log origin/<base>..HEAD --stat`** — only if there are new commits this tick.

Run these as a single parallel fan-out of `terminal` calls to keep ticks fast. NOT serial.

### Phase 2 — Decide nudges (only if Phase 0 didn't early-exit AND state has changed)

- If worker has NOT pushed in 30+ min AND state is still `spawning` or `working` → call `ao send <session> "STATUS?"` (the canonical nudge). Wait, do not inline-Enter; the manual Enter is the cron-playbook convention. After nudging, post a one-line note in the thread: `Nudged wa-NNNN at HH:MMZ — no push in N min.`
- If CI is red → summarize the failing check name + run URL in one line. Do not propose fixes; do not edit code. The babysit does not fix.
- If worker pushed new commits since last tick → summarize what landed (commit count + headline + one-line behavior delta), then run `gh pr checks` and post a 1-line green/red summary.
- If state == `pr_open` AND CI fully green AND reviewer-ready (no unresolved CodeRabbit CHANGES_REQUESTED, no Bugbot error-severity comments, mergeable=true) AND no skeptic request on the current head SHA yet → post `/skeptic` to the PR (NOT to the babysit thread) per the project's skeptic-cron contract. Verify with `gh pr comments` first.

### Phase 3 — Post the status update to the Slack thread (only if Phase 0 didn't early-exit)

Use the cron-deliverable template. Post ONE message per tick. Keep it under 12 lines.

```
:large_green_circle: _PR <N> babysit tick — HH:MMZ_
  • Worker state: <ao_session_state> | Branch: <branch> | HEAD: <short_sha>
  • Activity since last tick: <commit count> commits, headlines: <h1>; <h2>; ...
    OR "no new commits in <N> min"
  • CI: :white_check_mark: green OR :x: <failing check name> (<run_url>) OR :hourglass: pending
  • Reviewers: CodeRabbit <approve|request-changes|pending>; Bugbot <clean|errors|skipping>
  • Action taken this tick: <nudge / status-only / none>
  • Next checkpoint: <merge-ready / awaiting CI / awaiting CR / awaiting user>
```

If the worker has gone silent for a full 30 min window with no commits and no state change → reply `HEARTBEAT_OK` and DO NOT POST to Slack. This is the cron playbook's silence contract.

If the cron delivery instructions say "respond with exactly [SILENT]" AND there is genuinely nothing new to report AND no nudge needed → reply exactly `[SILENT]` per that contract.

## Deploy-run babysit sub-class (added 2026-08-06, v1.4.0)

A related cron pattern: **smoke-test retry on a queued deploy run**. The cron watches a single GitHub Actions run id (typically `pr-preview.yml` for a PR) until it transitions out of `queued` → `in_progress` → `completed`, then executes a smoke-test payload against the deploy artifact (verify served bundle contains expected event names, run a headless-Chrome flow, capture Cloud Logging entries proving all events fired, etc.) and posts a one-line PASS/FAIL back to the originating Slack thread.

**Difference from the AO-worker babysit:**

| Aspect | AO-worker babysit (1.0.0) | Deploy-run babysit (1.4.0) |
|---|---|---|
| **Wait condition** | AO worker liveness + PR state transition | `actions/runs/<id>` status transition (queued → in_progress → completed) |
| **On-completion action** | Status report only | Smoke-test payload against deploy artifact |
| **End-state** | PR MERGED/CLOSED, or worker gone | Smoke test PASSED/FAILED, or 24h self-cancel timeout |
| **Tick budget** | 100s of ticks (days) | 144 ticks × 10 min = 24h ceiling |
| **Failure mode** | Worker died | Deploy bundle rotated out / preview URL stale |

**The tick contract is the same:** observe → if state changed → decide → post. Same Phase 0 pre-flight (terminal-state check), same Phase 0.5 self-cancel, same Phase 1 observe. The only differences are (a) the Phase 1 observation probes a different system (GitHub Actions API vs `ao session ls`), and (b) the post-tick action on terminal-state is heavier (smoke test + Cloud Logging query, not just a status line).

### Stale `thread_ts` in cron prompt (added 2026-08-06, v1.7.0, PR #8787 final tick)

The cron prompt hardcodes `thread_ts` as the Slack reply target. Three failure shapes observed:

1. **Thread_ts belongs to a different channel** — verified 2026-08-06, PR #8787 final tick: prompt said `thread_ts=1785990587.321239`, expected channel `C0AH3RY3DK6` (`#worldai`), but the thread actually lives in `C0AUXSVFSA2` (a side channel). `conversations.replies?channel=C0AH3RY3DK6&ts=1785990587.321239` returns `thread_not_found` across 5 plausible channels (`C0AH3RY3DK6`, `${SLACK_CHANNEL_ID}`, `C0AJQ5M0A0Y`, `${SLACK_CHANNEL_ID}`, `C0AQJT7KSP2`). The side channel `C0AUXSVFSA2` is the canonical home for `1785990587.321239` and is documented in `wa-cloud-logging-diag` v1.2.0 as the PR #8787 verification thread.
2. **Thread_ts is stale (parent message deleted / channel archived)** — `conversations_replies` returns `thread_not_found` everywhere. The right action is silent self-cancel: do not invent a different thread; emit `[SILENT]` per the cron playbook SILENT contract.
3. **Thread_ts has no replies yet (HERMES-bot's prior top-level status post, not a real thread)** — `conversations_replies(thread_ts=<bot_self_msg>)` returns `thread_not_found` because there is no parent. Same mitigation as #2.

**Verification recipe (run BEFORE composing the Slack reply):**

```bash
# 1. Probe the documented channel first
TOKEN="${SLACK_BOT_TOKEN:-${SLACK_BOT_TOKEN:-${SLACK_USER_TOKEN}}}"
curl -fsS -H "Authorization: Bearer ${TOKEN}" \
  "https://slack.com/api/conversations.replies?channel=C0AH3RY3DK6&ts=${THREAD_TS}&limit=2"

# 2. If thread_not_found, try the side-channel ladder (C0AUXSVFSA2 MUST be in the ladder
#    for PR #8787-class verification threads — see wa-cloud-logging-diag v1.2.0)
for CHAN in C0AUXSVFSA2 ${SLACK_CHANNEL_ID} C0AJQ5M0A0Y ${SLACK_CHANNEL_ID} C0BA4MCBPFB C0AQJT7KSP2; do
  RES=$(curl -fsS -H "Authorization: Bearer ${TOKEN}" \
    "https://slack.com/api/conversations.replies?channel=${CHAN}&ts=${THREAD_TS}&limit=2")
  if echo "$RES" | grep -q '"ok":true'; then
    echo "FOUND in $CHAN"
    break
  fi
done

# 3. If still not found, run conversations.history on the operator's most-likely channel
#    (C0AH3RY3DK6 for WA-class PRs, ${SLACK_CHANNEL_ID} for personal-direct), filter for messages
#    referencing the PR number or the cron name, and use THAT row's thread_ts as the
#    reply target. Document the discovery in the post body so the operator can audit.

# 4. If still not found after 3 minutes of probing, emit [SILENT] per cron playbook.
#    Do NOT invent a thread; do NOT post to a different unrelated thread.
```

**Anti-pattern (verified 2026-08-06):** blindly posting to `C0AH3RY3DK6` (the obvious channel) when the prompt's `thread_ts` belongs to `C0AUXSVFSA2`. The post lands at channel root as an orphan and confuses the operator reading the wrong channel. Always run the verification recipe above; do not skip even when the channel name "looks right."

**Fallback ladder when verification succeeds but the original `thread_ts` does NOT:** post to the existing related thread where prior cron context lives (verified pattern: post to `1785998369.940599` — the PR #8787 PASSED thread — when the prompt's `1785990587.321239` doesn't resolve). Include a one-line note in the post body: *"Note on cron prompt's `thread_ts=<X>`: that thread_ts doesn't resolve in any channel (`thread_not_found` for ...). Replying to `<fallback>` to preserve thread continuity with the existing PR #N smoke-test conversation in #<channel>."*

This is a class-level pattern distinct from `slack-thread-routing-investigation`'s Failure 5 (which covers user-message routing in interactive sessions). Cron prompts have a different failure surface: the `thread_ts` is BAKED INTO the prompt at cron-creation time, so when the prompt was authored days/weeks ago and the thread has moved (deleted, archived, or migrated channels), the prompt's `thread_ts` is stale by definition. The fix is **probe-then-fallback at runtime**, not "trust the prompt."

### Run id drift (force-push between cron creation and first tick) — added v1.6.0

The original cron prompt typically hard-codes a specific run id (e.g. `actions/runs/31072371181`). Between cron creation and the first tick, the worker may force-push — and **force-push cancels all queued runs for the branch**. When the next tick probes the original run id, it returns:

```json
{
  "status": "completed",
  "conclusion": "cancelled",
  "runner_name": null,
  "run_started_at": "<started before force-push>",
  "updated_at": "<force-push timestamp>"
}
```

**This is NOT the smoke-test target.** The worker is now on a new head SHA, and a new deploy run has been spun up on the same branch with a larger id. Naively polling the old run id produces "cancelled" forever (silently parks the cron) OR — far worse — a false-positive "completed" that triggers the smoke test against the **previous deploy's bundle** (which doesn't contain the new code's event names), producing a spurious FAIL.

**Cancel-detection recipe (Phase 1.0 for deploy-run babysits, replaces the simple `gh api actions/runs/<id>` probe):**

```bash
REPO="<OWNER>/<REPO>"
RUN_ID="<original run id from cron prompt>"
BRANCH="<branch name, e.g. fix/funnel-diag-5-events>"

# Step 1: probe the original run id
RES=$(curl -sS -H "Authorization: token $GITHUB_PAT_TOKEN" \
  "https://api.github.com/repos/$REPO/actions/runs/$RUN_ID")
STATUS=$(echo "$RES" | jq -r '.status')
CONCLUSION=$(echo "$RES" | jq -r '.conclusion')
RUN_UPDATED_AT=$(echo "$RES" | jq -r '.updated_at')

# Step 2: get the PR's updated_at (force-push bumps it)
PR_UPDATED_AT=$(curl -sS -H "Authorization: token $GITHUB_PAT_TOKEN" \
  "https://api.github.com/repos/$REPO/pulls/<PR_NUMBER>" | jq -r '.updated_at')

# Step 3: detect drift. Three signals, any one is enough:
#   (a) status == "completed" AND conclusion == "cancelled"
#   (b) RUN_UPDATED_AT is within ~30s of PR_UPDATED_AT (force-push synchronized)
#   (c) PR head SHA has changed since cron creation (compare to the SHA baked in the prompt)
DRIFT=$( [[ "$STATUS" == "completed" && "$CONCLUSION" == "cancelled" ]] \
       || [[ "$RUN_UPDATED_AT" > "$PR_UPDATED_AT" ]] \
       && echo "true" || echo "false" )

if [ "$DRIFT" = "true" ]; then
  # Re-discover the current deploy run for this branch
  NEW_RUN=$(curl -sS -H "Authorization: token $GITHUB_PAT_TOKEN" \
    "https://api.github.com/repos/$REPO/actions/runs?per_page=30&branch=$BRANCH" \
    | jq -r '.workflow_runs[] | select(.name == "Deploy PR Preview (Rotating Pool)") | select(.status == "queued" or .status == "in_progress") | .id' \
    | head -1)
  
  if [ -n "$NEW_RUN" ]; then
    echo "DRIFT: original run $RUN_ID was cancelled; new deploy run is $NEW_RUN"
    # Set RUN_ID=$NEW_RUN for the rest of this tick. The cron can also
    # self-update the prompt to lock onto the new id for subsequent ticks.
    RUN_ID=$NEW_RUN
  else
    echo "DRIFT: original $RUN_ID cancelled, no new deploy run yet — wait for next tick"
  fi
fi
```

**Verified on PR #8787 (jleechanorg/worldarchitect.ai), 2026-08-06 05:46Z:**
- Original run: `31072371181` (created 04:50:30Z, queued ~40 min)
- Force-push at 05:44:03Z — head moved from `da1d95fe9d` → `0a9d234a`, run 31072371181 cancelled at 05:44:04Z
- New deploy run discovered: `31075008771` (created 05:44:03Z, queued)
- Both the cancel-detection (`(a)`) and the synchronized `updated_at` (`(b)`) signals fired

**Where to put the drift detection in the deploy-run babysit prompt:**

Replace the simple Phase 1 probe:

```bash
# OLD (v1.4.0):
gh api "repos/<OWNER>/<REPO>/actions/runs/<RUN_ID>" --jq '{status, conclusion, runner_name}'

# NEW (v1.6.0): wrap with the drift-detection block above. If drift detected,
# replace <RUN_ID> with the new run id discovered via:
#   curl -sS .../actions/runs?branch=<branch>&name=Deploy+PR+Preview+(Rotating+Pool)
```

**Optional: lock the new run id into the prompt for subsequent ticks.** A long-lived deploy-run babysit that hits drift more than once (multiple force-pushes mid-tick-budget) can self-update via `cronjob action=update job_id=$CRON_JOB_ID prompt="... RUN_ID=$NEW_RUN ..."` so future ticks don't re-run drift detection. Trade-off: this couples the cron to a specific run id again, re-introducing drift risk on the next force-push. **Default: leave the original run id in the prompt and re-run drift detection every tick** — the recipe is cheap (~2 API calls) and the re-discovery is deterministic.

**Anti-pattern (verified 2026-08-06):** Treating `status=completed, conclusion=cancelled` as "the run is done, do the smoke test anyway" — this triggers the smoke test against the bundle from the previous deploy, which **always fails** (the new code's event names aren't served), and posts a spurious RED to the thread. Always run the drift-detection block first.

### Wait-condition probe recipe (Phase 1.1 for deploy-run babysits, after drift detection)

```bash
# 1. Check the target run id (after drift detection has set RUN_ID to the current one)
gh api "repos/$REPO/actions/runs/$RUN_ID" \
  --jq '{id, status, conclusion, runner_name: (.runner_name // null), name, created_at, updated_at}'

# 2. If status == "queued" → poll queue depth and position, do NOT proceed to smoke test
# 3. If status == "in_progress" → still wait; log "moving" tick
# 4. If status == "completed" → proceed to Phase 1.5 (extract preview URL + smoke test)
```

**Queue-position estimation recipe (for the yellow-tick update):**

```bash
# Total queued + position of target run, paginated (default page size 100; verify if more)
for p in 1 2 3 4 5; do
  count=$(gh api "repos/$REPO/actions/runs?per_page=100&status=queued&page=$p" \
    --jq '.workflow_runs | length' 2>/dev/null)
  echo "page $p: $count"
  [ "$count" = "0" ] && break
done

# Position = count of queued runs whose id <= target run id
gh api "repos/$REPO/actions/runs?per_page=100&status=queued" \
  --jq '[.workflow_runs[] | select(.id <= '"$RUN_ID"')] | length'

# ETA = position / (in_progress rate). Conservative estimate: 1 in_progress run per ~5 min
# given ~14-16 self-hosted runners and typical PR workflow runtime.
```

**Verified on PR #8787 (jleechanorg/worldarchitect.ai), 2026-08-06 05:30Z:**
- Target run: `31072371181` (created 04:50:30Z, queued ~40 min)
- Total repo queued: 171 across 100+ branches (saturated self-hosted pool)
- Position: ~59/171
- pr-preview queued: 2; pr-preview in_progress: 0
- All pr-preview runs blocked behind Green Gate / WorldArchitect Tests / Self-Hosted MVP Shards from other PRs

**On-completion payload (Phase 1.5 — smoke test execution):**

1. **Extract preview URL** from the latest `pr-preview-comment:mvp-site` bot comment on the PR. The URL pattern `<service>-app-s7-<hash>-<region>.a.run.app` is stable per (PR, slot) — both deploy comments on PR #8787 (commit 6138d3e) used `https://mvp-site-app-s7-i6xf2p72ka-uc.a.run.app`. The slot is `pr.slot_id` derived from `commit_sha[0:7]`, not from PR number; **the URL persists across re-deploys on the same commit but changes when the head commit changes** (a retrigger commit like da1d95fe9d → 6138d3e will reuse the slot).
2. **Verify the served bundle contains expected strings** (catches the "deploy was rotated out before the smoke test ran" race):
   ```bash
   curl -fsS <preview_url>/<asset_path> 2>&1 | grep -cE '<expected-event-name-1>|<expected-event-name-2>|...'
   # Must return N (one match per expected string). If 0, the deploy was rotated out — wait for next run.
   ```
3. **Run the smoke test** via headless Chrome (`browser-headless-default` skill), driving the user flow that produces each event.
4. **Capture Cloud Logging entries**:
   ```bash
   gcloud logging read 'jsonPayload.event_name=~"<evt1>|<evt2>|<evt3>|<evt4>|<evt5>"' \
     --limit=50 --project=<PROJECT> --format=json | jq '.[] | {ts, event_name: .jsonPayload.event_name, user_id: .jsonPayload.user_id}'
   ```
   Verify all N expected event_names appear in the output. If any are missing, the smoke test is a PARTIAL PASS — surface the missing events by name.
5. **Post the result to the originating Slack thread** with the canonical shapes:
   - `:large_green_circle: PR N smoke test PASSED — Cloud Logging captured all N events at <preview_url>. See <commit_sha>.` then exit, do not run again.
   - `:large_yellow_circle: PR N smoke test retry tick K/144 — run <id> still queued (~X min in self-hosted runner pool). Repo-wide queue: ~Y queued, Z in_progress, W pr-preview in_progress. ... Continuing to monitor.`
   - `:red_circle: PR N smoke test FAILED — bundle at <preview_url> did not contain event names.` (partial failure, continue)
   - `:red_circle: PR N smoke test retry timed out (24h, no runner pickup).` (final, exit)

**Cron-context Path B fallback for Slack posting (added 2026-08-06, v1.4.0):**

The cron's prompt will typically reference `mcp__slack__conversations_add_message` for the post. If that tool is NOT surfaced in this runtime's tool list (Failure 2 from `slack-thread-routing-investigation`), apply the Path B curl fallback — but for a cron context, the **token source is simpler** than Failure 5f's xoxp user-token dance:

```bash
# Cron context check (in order, take the first match):
# 1. SLACK_BOT_TOKEN in env → use as-is (preferred)
# 2. SLACK_BOT_TOKEN in env → use as-is (works when target channel is bot's home workspace)
# 3. SLACK_USER_TOKEN in env → Failure 5f fallback (cross-workspace); identity-disclose in body
# 4. None of the above → launchd-env-wrapper.sh source from ~/.bashrc

# CRITICAL: in a cron context, /tmp is the safe writable dir;
# write the JSON body via heredoc to /tmp/<name>.json, then curl --data-binary @<file>
# (heredoc survives the cron shell; --data-binary is the durable shape)

cat > /tmp/slack-post.json <<EOF
{"channel":"C0XXXXXXX","thread_ts":"1234567890.123456","text":"..."}
EOF

curl -fsS -X POST "https://slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" \
  --data-binary @/tmp/slack-post.json | jq .
```

Verified on PR #8787 cron, 2026-08-06: `SLACK_BOT_TOKEN` was in env, channel C0AH3RY3DK6 is the bot's home workspace (`T09FXQ4LCQP`), no xoxp needed. Post landed at `ts 1785994442.274029` in thread `1785990587.321239`, `ThreadTs` correctly matching parent. Response: `{"ok":true,"channel":"C0AH3RY3DK6","ts":"1785994442.274029"}`. **The Failure 5f xoxp fallback is NOT needed in this case** — the rule of thumb is: if the target channel is in the bot's home workspace (`team == bot's home team`), Path B with bot token works; only fall to xoxp if the bot returns `missing_scope`/`not_in_channel`.

## Runner-pool / CI-clearance babysit sub-class (added 2026-08-06, v1.8.0, PR #8794)

A structurally-not-fixable PR has **no AO worker session to babysit** and **no code path the agent can fix** — the takeover worker is gone (silent or vaporized after a force-push), and the only thing keeping the PR from green is the self-hosted runner pool draining the queue. The babysit's job is reduced to: observe the pool, observe the PR head, and post ONLY when something meaningful changes (queue drain ≥ 20, head drift, new CI on a new head, or a 12h staleness escalation).

**Difference from the AO-worker and deploy-run sub-classes:**

| Aspect | AO-worker (1.0.0) | Deploy-run (1.4.0) | Runner-pool (1.8.0) |
|---|---|---|---|
| **Has an AO worker?** | Yes | N/A | **No** — worker is gone |
| **Fixable by changing code?** | Maybe | No (smoke test only) | **No** — purely infra |
| **Wait condition** | Worker liveness + PR state | `actions/runs/<id>` status | Pool queue depth + head SHA + CI on latest head |
| **On-stalled action** | `ao send <session> "STATUS?"` | Re-discover run id | Post escalation asking operator for force-push trigger or manual runner nudge |
| **Tick budget** | Days | 24h (144 ticks) | 12h silent ceiling; 24h total (144 ticks) |
| **Allowed per-tick output** | Full status | Full status | **Sparse** — only on state change, otherwise `[SILENT]` |

**Phase 0 — terminal-state check.** Same as the AO-worker sub-class. `gh pr view <N> --json state,mergedAt,closedAt` (or the REST `gh api repos/<owner>/<repo>/pulls/<N>` equivalent when GraphQL is rate-limited) — `MERGED` triggers closeout + self-cancel, `CLOSED` (not merged) triggers escalation + self-cancel.

**Phase 1 — observe pool-and-PR, NOT code.** Fan-out parallel probes:

```bash
# 1. PR head (live, not baked into the prompt) — REST avoids GraphQL rate limits
gh api repos/<OWNER>/<REPO>/pulls/<N> \
  --jq '{state, head_sha: .head.sha, mergeable, draft, updated_at, closed_at, merged_at}'

# 2. Branch tip in chronological order (most recent first) — detects PR-head-vs-branch-tip drift
gh api repos/<OWNER>/<REPO>/pulls/<N>/commits?per_page=10 \
  --jq '.[] | .sha'

# 3. CI on the actual head SHA (the one from #1, not the SHA baked in the prompt)
gh api repos/<OWNER>/<REPO>/commits/<HEAD_SHA>/check-runs \
  --jq '[.check_runs[] | {name, status, conclusion}]'

# 4. Queue depth — repo-wide (not just this PR)
gh api "repos/<OWNER>/<REPO>/actions/runs?per_page=100&status=queued" --jq '.total_count'
gh api "repos/<OWNER>/<REPO>/actions/runs?per_page=100&status=in_progress" --jq '.total_count'

# 5. CI runs on the branch
gh api "repos/<OWNER>/<REPO>/actions/runs?per_page=30&branch=<BRANCH>" \
  --jq '.workflow_runs[] | select(.status=="queued" or .status=="in_progress") | {id, name, status, head_sha: .head_sha}'
```

**Phase 1.0 — head drift detection.** Compare `pulls/<N>.head.sha` (PR head) to the SHA baked into the cron prompt. If they differ, the takeover worker has force-pushed on the branch without re-advancing the PR ref OR the previous head has been re-recorded. CRITICAL: ALSO compare the PR head to the *first* commit in `/pulls/<N>/commits?per_page=10` (the branch tip). If the branch tip is NEWER than the PR head, the branch has unpushed-to-PR commits — this is the most common drift shape for a "takeover worker gone silent" scenario. The current PR's CI ratchet is stuck on the OLD head, and the new branch tip has no CI runs yet.

**Phase 1.1 — rate-limit fallback.** If `gh pr view <N> --json ...` returns `GraphQL: API rate limit already exceeded for user ID <id>`, do NOT retry the GraphQL endpoint — switch to the REST endpoints (`gh api repos/<owner>/<repo>/pulls/<N>` and `gh api .../pulls/<N>/commits`) which use a different quota bucket. Verified PR #8794, 2026-08-06: GraphQL blocked at 09:40Z, REST returned state + head + mergeable in ~0.5s.

**Phase 2 — decide and post sparsely.** Post ONE message per tick ONLY when:
- A check that was `queued`/`in_progress`/`pending` transitioned to a terminal state (success/failure/skipped), OR
- A new commit landed on the head SHA (compare `pulls/<N>.head_sha` to the value from the last tick), OR
- Queue depth changed by ≥ 20 (meaningful pickup or backlog growth), OR
- Branch tip moved relative to the PR head (force-push drift detected in Phase 1.0).

Otherwise → emit `[SILENT]` (do not post, do not poll noisily). The cron playbook SILENT contract is mandatory — noise is worse than silence.

**Phase 2 status post template (under 12 lines):**

```
:hourglass: _PR <N> babysit tick — HH:MMZ_
  • Head: <short_sha> (PR) / branch tip <short_sha> (drift — N commits ahead of PR head)
  • State: open | mergeable: <mergeable> | draft: <isDraft>
  • Queue: <queued> queued / <in_progress> in_progress (repo-wide)
  • CI on <head_sha>: <N> failures (<names>) ; <N> skipped — OR no runs yet
  • Action: <none | operator nudge needed | head drift detected>
  • Next checkpoint: <PR head advance | Evidence Gate clear | operator force-push trigger>
```

**If queue depth drops to < 50 OR the Evidence Gate check transitions to success**, escalate by noting *"PR now reachable for /green pending remaining checks"* in the next post. This is the override signal that the structural blocker has cleared.

**12h staleness ceiling.** If the loop has been silent (no operator force-push, no CI movement, queue depth unchanged) for 12h, post ONE escalation: *"PR #N still structurally blocked at <queue> queued. Operator action needed (force-push trigger commit / manual runner nudge)."* Then continue but flag the staleness in each subsequent post. Tick budget is 144 ticks × 10 min = 24h ceiling — past that, the cron self-cancels.

**Anti-patterns (added 2026-08-06, v1.8.0):**
- ❌ Posting every tick. The cron playbook SILENT contract is mandatory — noise is worse than silence.
- ❌ Proposing code fixes. The PR is structurally blocked, not failing for a fixable reason. There is no worker to fix; there is no diff to patch.
- ❌ Treating the SHA baked into the cron prompt as authoritative. After takeover-worker force-pushes, the PR head lags behind the branch tip. ALWAYS live-fetch the head via `pulls/<N>`.
- ❌ Trusting the GraphQL endpoint when `gh pr view --json` returns `rate limit exceeded`. REST API has a separate quota; switch to `gh api repos/<owner>/<repo>/pulls/<N>` and `gh api .../pulls/<N>/commits`.
- ❌ Treating zero in_progress runs as "the babysit succeeded." Zero in_progress + N>0 queued means the pool is still saturated; the babysit is still structural-waiting.

**Verified PR #8794 worked example (2026-08-06):**
- Cron: `b6c8887f546e`, started 2026-08-06T07:00Z, target thread C0AH3RY3DK6/1785996838.635219
- Branch: `feat/campaign-share-url-phase1`, original head SHA `a3c3c19e1416f473e9ae98febb2c5cfc21827cc3`
- Live state observed at 11:40Z: PR head `930210cab680558191c8ac0f65e44678dfc665ff`, branch tip `77652b0926b3cb561d0777d3c96955b7e24b4a98` (7 commits ahead of PR head)
- Queue depth: 1 queued / 0 in_progress (was 152 queued / 3 in_progress at 07:00Z — pool drained 99%)
- CI on PR head `930210ca`: 5 failures (Tests Required Gate, Playwright auth, Directory tests core-tests + 3 self-hosted, beads-jsonl-validation); 7 skipped
- CI on branch tip `77652b09`: zero runs (no PR head advance, no CI seeded)
- Action posted: tick update with drift signal + operator nudge needed + next checkpoint labeled correctly

### Premise-mismatch self-cancel (added 2026-08-06, v1.9.0, PR #8794 first tick 11:52Z)

The runner-pool sub-class is built on a structural premise: **the PR is not fixable by the babysit**, only by external operators or the runner pool draining. That premise can lift mid-loop — when the pool drains AND CI actually runs, the failures on the latest head may be **code-actionable** (real bugs, flaky tests, integration drift) rather than **structural** (pool blockage, missing PR-ref advance). When that happens, the cron prompt's "do NOT propose code fixes" instruction is **no longer authoritative** — the babysit cannot fix because it is observe-only by design, but the work itself IS now fixable. Continuing to tick on the assumption that the PR is structural wastes the operator's time and creates noise.

**Detection (run after Phase 1 observe, before Phase 2 decide):**

```
PREMISE_INTACT = ALL of:
  (a) queue depth ≥ 50 (pool is still saturated, structural wait is real), OR
      no CI runs exist for the current head (CI hasn't started — still structural)
  (b) PR head === SHA baked into cron prompt (no takeover-worker drift), OR
      branch tip is newer than PR head (drift, but no new CI on the drift)
  (c) no check on the current head has `conclusion == "failure"` from a fixable cause
      (Tests Required Gate, Directory tests, Playwright tests, lint/typecheck, etc.)

PREMISE_LIFTED = ANY of:
  (a) queue depth < 50 AND CI runs exist for the current head AND at least one has failed
      for a fixable reason (test failure, lint error, typecheck failure, regression)
  (b) the new head's failures are reproducible from the diff (the takeover worker
      may have introduced a regression that another worker can fix)
  (c) Evidence Gate + Green Gate both passed but other checks (Tests Required, Directory
      tests, Playwright) failed — the structural-wait cleared, the work is now a
      normal /green-bring loop
```

**Action when PREMISE_LIFTED:**

1. Post ONE premise-divergence notification to the thread (under 12 lines, do NOT propose the fix). The post MUST:
   - State the lift explicitly: *"Playbook premise no longer holds for PR #N — handing off."*
   - Show the live evidence that proves the lift: pool depth now vs. cron-prompt-baked, PR head SHA now vs. baked, the N failed check names.
   - State the right next step: *"This is now a /green-bring babysit with code-actionable failures, not a no-fixable structural block. Recommend relaunching with `drive-pr-to-green` from <current_head_sha>."*
   - Name the current babysit's id (`$CRON_JOB_ID`) and that it has no fix authority.
2. Self-cancel via `hermes cron remove $CRON_JOB_ID` (see Phase 0.5 — primary path on this host).
3. Emit `[SILENT]` on all subsequent ticks. The cron is inert; `drive-pr-to-green` (or a fresh AO worker) takes over.

**Verified PR #8794 first tick (2026-08-06 11:52Z):**
- Premise inputs: queue 1/0 (was 152/3 — drained 99%), PR head `930210ca` (drifted from baked `a3c3c19e`), CI on `930210ca` had 5 failures (Tests Required Gate, 4 Directory tests, Playwright auth browser tests, Mobile Auth Same-Origin Regression, beads-jsonl-validation).
- Premise LIFTED on all three conditions: pool drained, head drifted, CI failed for code-actionable reasons.
- Posted premise-divergence notification to thread `1785996838.635219` (Slack ts `1786017124.478359`, `ok:true`, verified threaded).
- Self-cancel: `hermes cron remove b6c8887f546e` → `Removed job: babysit-pr-8794-share-url-phase1-ci-pool (b6c8887f546e)`. First-try success.
- Subsequent ticks: `[SILENT]`.

**Anti-patterns (verified 2026-08-06):**

- � **Continuing to tick on the lifted premise.** The cron prompt said "do NOT propose code fixes" — that was true at creation time (pool saturated, no CI ran). Once CI fails for code-actionable reasons, the prompt's instruction becomes misleading. Continuing under it produces posts like "pool is drained but PR is still red, awaiting operator action" — the operator reads this and assumes the pool is the bottleneck, but the pool is fine; the bottleneck is now code quality. The premise-divergence post corrects this.
- ❌ **Proposing the actual fix in the premise-divergence post.** The babysit is observe-only; it does not have the context to write a safe fix (no worktree, no test harness, no `/es` evidence). The right output is *"recommend drive-pr-to-green from <sha>"*, not a fix sketch. The operator (or the next worker) decides whether to relaunch.
- ❌ **Self-cancelling BEFORE the post lands.** Order matters: post first (verify `ok:true` AND `thread_ts == <correct_thread>`), THEN self-cancel. Reversing the order risks the cron dying before the operator sees the divergence notification.
- ❌ **Re-running the runner-pool sub-class on a different head SHA without a fresh premise check.** If the operator (or another worker) re-launches a fresh runner-pool babysit after the CI runs green, the premise check will catch a SECOND divergence at the next tick and self-cancel again. This is correct behavior — the second self-cancel is not a leak, it's a feature. If the operator wants a long-running CI-clearance loop, they should relaunch with `drive-pr-to-green` (which has fix authority), not with another runner-pool babysit.

### All-gates gate-check contract + 0-billable-duration diagnostic (added 2026-08-06, v1.10.0, PR #815)

Two operational corrections verified on a runner-pool babysit watching PR #815 (jleechanorg/jleechanbrain, branch `fix/cost-monitor-self-hosted-rates`, head `d176fba541b391a7ffae2b17bb57a9928fa4e0a7`), 2026-08-06 18:26Z.

**Problem 1 — incomplete gate enumeration.** The cron prompt listed three required CI gates: *Green Gate, Staging Canary Gate, Staging Canary Full*. The babysit was correctly monitoring those three (all queued, self-hosted runner outage). But the PR also had a 4th check — `Example discipline` (a separate workflow triggered by every `pull_request` event, runs on `ubuntu-latest` hosted, executes `tests/test_example_placeholder_discipline.sh`) — and that check had **already failed** with `status=completed, conclusion=failure` by the time the first tick ran. The babysit's naive "the three gates the prompt named are queued → don't merge" reasoning missed the 4th failed gate entirely. If the pool had drained and the three self-hosted gates had gone green, the babysit would have merged a PR with `Example discipline = failure` — violating the project's own gate contract (`gh-safe-merge` checks ALL check-runs, not the prompt's named subset).

**Fix 1 — gate-readiness predicate uses the full check-runs surface, not the prompt's named subset.**

```bash
# WRONG (v1.9.0): trust the prompt's gate list
gh api "repos/$REPO/commits/$HEAD_SHA/check-runs" \
  --jq '[.check_runs[]
        | select(.name as $n |
                 ["Green Gate","Staging Canary Gate","Staging Canary Full"]
                 | index($n))
        | select(.conclusion != "success")] | length'

# RIGHT (v1.10.0): iterate ALL check-runs, treat any non-success terminal as blocking
gh api "repos/$REPO/commits/$HEAD_SHA/check-runs" --jq '
  [.check_runs[]
   | . as $c
   | select($c.status == "completed"
            and ($c.conclusion != "success" and $c.conclusion != "skipped" and $c.conclusion != "neutral"))
   | {name, conclusion, html_url}]
'
# If the array is non-empty → a gate has failed (regardless of whether the prompt listed it).
# If the array is empty AND no check-runs are queued/in_progress → ALL gates green (merge-ready).
```

The new predicate is **"every check-run is in a green-class terminal state, AND no check-run is queued/in_progress"** — not "the gates the prompt named are green." This catches the prompt-staleness failure mode (a repo adds a new required gate, the prompt doesn't update; the babysit must catch the new failure from the live API).

**Problem 2 — `failure` vs `cancelled-without-run` ambiguity.** `Example discipline` had `status=completed, conclusion=failure` but a deeper probe showed it had been queued for 15 minutes with **zero billable duration** (the runner never picked it up; GitHub Actions platform cancelled it on the 15-min queue timeout). The naive "conclusion=failure → premise lifted" reasoning would have incorrectly concluded the structural wait had cleared and handed off to `drive-pr-to-green`. In reality, the failure was infrastructure-side (hosted-runner saturation), not code-side.

**Fix 2 — `actions/runs/<id>/timing` 0-billable-duration diagnostic.**

```bash
# For every check-run with conclusion=failure (or cancelled), probe the timing endpoint
# BEFORE deciding the failure is code-actionable.
TIMING=$(gh api "repos/$REPO/actions/runs/$RUN_ID/timing")
BILLABLE_MS=$(echo "$TIMING" | jq '[.billable | to_entries[] | .value.job_runs[]
                                    | .duration_ms] | add // 0')
RUN_DURATION_MS=$(echo "$TIMING" | jq '.run_duration_ms')

# If billable_ms == 0 AND run_duration_ms > 0 (typically > 60_000), the job never started.
# It was queued, runner-pool/platform cancelled it, and the workflow conclusion defaulted
# to "failure" because no job produced a success signal. This is INFRA, not code.
if [ "$BILLABLE_MS" -eq 0 ] && [ "$RUN_DURATION_MS" -gt 60000 ]; then
  echo "INFRA failure: queued $((RUN_DURATION_MS/1000))s, never executed"
  # Re-queue via the rerun endpoint (does not require a new commit)
  curl -fsS -X POST "repos/$REPO/actions/runs/$RUN_ID/rerun"
  # Premise remains INTACT — the babysit continues to wait for the runner pool to drain
else
  echo "CODE failure: ran for $((BILLABLE_MS/1000))s, exited with non-success"
  # Premise LIFTED — hand off to drive-pr-to-green (existing v1.9.0 protocol)
fi
```

**Verified PR #815 timing probe (2026-08-06 18:17Z):**

```json
{
  "billable": { "UBUNTU": { "total_ms": 0, "jobs": 1, "job_runs": [{"job_id": 92693418623, "duration_ms": 0}] } },
  "run_duration_ms": 902000
}
```

`total_ms=0` + `duration_ms=0` + `run_duration_ms=902000` (15 min) = job was queued the entire time, never executed. Platform cancelled on the queue-timeout. NOT a code failure. Re-queued via `actions/runs/31124896276/rerun` (200 OK), then re-monitored as `status=queued`.

**Anti-patterns (verified 2026-08-06):**

- ❌ **Treating the cron prompt's named gates as exhaustive.** Verified PR #815: prompt named 3 gates; PR had 4 check-runs; one of the unnamed ones (`Example discipline`) had failed with 0-billable-duration. The prompt's enumeration was stale relative to the repo's actual gate set. Use the full `check-runs` surface, not the prompt's list.
- ❌ **Treating `conclusion=failure` as a code failure without the timing probe.** A `failure` conclusion can come from a job that never started (infra), from a job that started and exited non-zero (code), or from a job that ran successfully but the workflow-level conclusion defaulted to failure because a required job was skipped (config). The timing endpoint distinguishes these: `billable_ms == 0` = infra, `billable_ms > 0` and `conclusion == "failure"` = code, `billable_ms > 0` and `conclusion == "success"` but workflow conclusion = `failure` = config. Run the probe BEFORE handing off to drive-pr-to-green — handing off an infra failure wastes a worker spawn.
- ❌ **Re-running a cancelled run without checking if it was cancelled by a force-push.** The Phase 1.0 cancel-detection recipe (deploy-run sub-class) is the same shape: a cancelled run on a stale head SHA is NOT the same as a cancelled run on the current head SHA. If the PR head SHA has changed since `created_at`, do NOT rerun — wait for the next push to seed a fresh run.

## Termination rules (loop closure)

When ANY of these are true, the loop is done:

1. PR state is `MERGED` (Phase 0 catches this).
2. PR state is `CLOSED` without merge, AND the operator has confirmed to stop.
3. Worker session is gone from `ao session ls`, AND the operator has confirmed to stop.
4. The cron schedule itself has been disabled (e.g. one-time cron fired + `--delete-after-run` completed).
5. The PR has been open > N days (configurable, default 14) with no movement AND no recent owner action → ask the operator.

When terminating:
- Post ONE final summary to the thread.
- Disable or self-delete the cron (one-time crons with `--delete-after-run` handle this automatically).
- If the cron is launchd-managed and meant to keep ticking, set `Disabled=true` in the plist template and `launchctl bootout gui/$(id -u)/<label>`.

## Anti-patterns (do NOT do)

- ❌ Reposting the same closeout message every tick after the work is done. **One tick owns the close; later ticks own silence.**
- ❌ Posting to Slack when nothing changed and the playbook says `HEARTBEAT_OK` / `[SILENT]`. Noise is worse than silence — the human inbox is the precious resource.
- ❌ Inlining `Enter` after `ao send "STATUS?"`. The cron-playbook convention is the literal newline-less stream; the worker ITSELF consumes the manual Enter as a session-input boundary.
- ❌ Editing code, even to fix a CI red. The babysit is observe-only. Drive-to-green goes to `drive-pr-to-green` or `finish-the-job`, which is a different loop.
- ❌ Auto-respawning the worker when it disappears. The operator decides.
- ❌ Treating untracked worktree files (`.beads/.write.lock`, `specs/*.json`, `ADVERSARIAL_REVIEW_*.md`) as "uncommitted work" — they are harness residue from prior ticks, not the fix's scope.
- ❌ Post-merge commits on the branch tip are NOT the babysit's problem. Drift accumulated after `mergedAt` belongs to a different audit; ignore it for status purposes.
- ❌ **Picking the wrong cron shape at `cronjob create` time (added 2026-08-05, PR #8787).** The four valid shapes are: (a) one-shot 20m followup — `schedule=20m`, `repeat=once`; (b) tight repeating babysit — `every 5m`, `repeat=forever`, MUST have self-cancel-in-prompt + `--cron-job-id`; (c) recurring heartbeat — `every 30m`, `repeat=forever`; (d) launchd plist. **NEVER mix `every X` + a high `repeat: 120`** as a fake one-shot. `repeat: 120` + `every 5m` = 120 × 5 min = 10 hours of polls. The operator's `COMMIT: one-time-status-cron-after-every-task` rule bans `--every` for one-shots; `--at Xm` + `--delete-after-run` is the only one-shot recipe. Created exactly once on 2026-08-05; caught and removed before first tick.
- ❌ **Forgetting the read-before-update step after `cronjob create` (added 2026-08-05).** After `cronjob create` returns a `job_id`, immediately call `cronjob update` to embed the `job_id` in the prompt body so the babysit knows its own handle and can call `cronjob action=remove job_id=...` on its own when the PR is `MERGED`/`CLOSED`. Without that update, the prompt runs as a generic worker with no self-cancel handle. Verified 2026-08-05: babysit `ae25dbbb2aac` needed `cronjob update` with `prompt=... job_id=ae25dbbb2aac ...` to thread the handle into the body.
- ❌ **Inline-polling a self-hosted CI rerun from the gateway (added 2026-08-05, PR #8787).** The "<2 min CI" heuristic in `drive-pr-to-green` is wrong for self-hosted runner jobs. Verified end-to-end on PR #8787 attempt 1: queued 22:50:18Z → completed 23:15:40Z = 25 min, with the three `core-mvp-1/2/3` shards sitting in `queued` for ~13 min before any moved to `in_progress`. So when a babysit is watching a rerun that includes a self-hosted job, do NOT inline-poll from the gateway turn — hand off to a `cronjob create` babysit before posting the next status. The same rule applies to any CI run with expected runtime >5 min: gateway sessions cap at ~25 tool calls, but a `cronjob` runs forever at zero token cost. Held the gateway 800s on a queued CI before handing off to a babysit on 2026-08-05; the babysit caught the state in 5-min ticks at zero token cost. New rule: if the rerun includes a self-hosted runner job OR has expected runtime >5 min, post one interim status + create a babysit cron + exit. Do not inline-poll a queued CI run.
- ❌ **Treating `status=completed, conclusion=cancelled` as "the run is done, smoke test now" (added 2026-08-06, v1.6.0, PR #8787).** When the worker force-pushes between cron creation and first tick, the original run id is cancelled and replaced by a new run on the same branch. Naively polling the old id returns "cancelled" — the smoke test will then run against the previous deploy's bundle (which lacks the new event names), producing a spurious RED. Always run the cancel-detection block (Phase 1.0 above) before proceeding to the smoke test payload.
- ❌ **Trusting the cron prompt's premise at face value (added 2026-08-06, v1.9.0, PR #8794).** A cron prompt's structural premise ("no AO worker", "pool is saturated", "do not propose code fixes") was true when the prompt was authored. The premise can lift mid-loop — pool drains, head drifts onto a fixable CI failure, etc. Every tick MUST re-check the premise; if it has lifted, post ONE premise-divergence notification + self-cancel + hand off to `drive-pr-to-green`. Verified PR #8794 cron `b6c8887f546e`: first tick at 11:52Z detected that the 152/3 queue had drained to 1/0, head had drifted from `a3c3c19e` to `930210ca`, and CI on `930210ca` had 5 fixable failures. Continuing to tick would have produced "still red, operator nudge needed" posts that mislead the operator into thinking the pool is still the bottleneck. The premise-divergence notification corrects this in one post, then the cron self-cancels. See the "Premise-mismatch self-cancel" subsection under the Runner-pool sub-class for the full detection recipe.
- ❌ **Trusting the cron prompt's named gate list as exhaustive (added 2026-08-06, v1.10.0, PR #815).** The merge-readiness predicate MUST iterate ALL check-runs on the live head SHA (`commits/<HEAD_SHA>/check-runs`), not the subset the prompt happened to name. Verified PR #815: prompt named 3 gates (Green Gate, Staging Canary Gate, Staging Canary Full); the PR actually had 4 check-runs; the unnamed `Example discipline` had failed with `billable_ms=0` (queued 15 min, never executed). A "the named gates are green" merge would have shipped a PR with a 4th gate in `failure` state. Always use the full check-runs surface.
- ❌ **Treating `conclusion=failure` as code-actionable without the timing probe (added 2026-08-06, v1.10.0, PR #815).** A `failure` conclusion can come from a job that never started (`billable_ms=0`, runner-pool/platform cancellation) — that's INFRA, not code. Handing off an infra failure to `drive-pr-to-green` wastes a worker spawn. Probe `actions/runs/<id>/timing` BEFORE deciding the failure is premise-lifted. See the "All-gates gate-check contract + 0-billable-duration diagnostic" subsection for the recipe.

## Tool usage notes

- Use `terminal` for `git`, `gh`, `ao` — fan-out parallel, not serial. A tick should not take more than 6 sequential tool calls.
- Use `mcp__slack__conversations_add_message` for thread replies. The cron invocation will pre-populate `channel_id` + `thread_ts`; verify before posting (per `slack-reply-inherit-thread-ts`).
- Use `mcp__slack__conversations_replies` once per tick if you need to confirm whether earlier ticks already posted a closeout.
- Do NOT use `mcp__slack__conversations_history` in full — paging through the channel is wasteful and may surface unrelated threads. The thread is the unit of work.

## Verification

Before posting the first tick of a new babysit loop, confirm:

- The cron is correctly delivering to the channel + thread configured by the operator. (The cron prompt usually specifies these.)
- The branch name + base branch + PR number are correct. (`gh pr view <N> --json headRefName,baseRefName`.)
- The worker session id is correct. (`ao session ls | grep <pattern>`.)
- If you inherit a mid-loop babysit, READ THE LAST 3 THREAD REPLIES before posting — if a recent tick already announced completion, post `[SILENT]` (do NOT duplicate the closeout).
- **For deploy-run babysits specifically (added v1.6.0):** verify the original run id is still the current one. If the worker has force-pushed since cron creation, the original run id is cancelled — discover the new run id via the Phase 1.0 recipe before proceeding.

## Support files

- `references/mid-loop-handoff.md` — pattern for inheriting a babysit loop from a previous session and confirming the thread state before posting.
- `references/cron-prompt-anatomy.md` — anatomy of a babysit cron task prompt (channel, thread_ts, branch, PR, worker session, beat) and how to extract them safely.
- `references/queue-position-estimation.md` (added 2026-08-06, v1.4.0) — paginated `gh api actions/runs?status=queued` recipe for computing queue length + position + ETA in a yellow-tick update. Worked example from PR #8787 deploy-run cron with 171 queued / 7 in_progress / position ~59/171.
- `references/cron-context-slack-post.md` (added 2026-08-06, v1.4.0) — Path B curl fallback for cron-context Slack posting when `mcp__slack__conversations_add_message` is not in the runtime tool list. Token-source decision tree (SLACK_BOT_TOKEN → SLACK_BOT_TOKEN → SLACK_USER_TOKEN → launchd-env-wrapper). When to use bot token vs xoxp based on channel workspace. Verified on PR #8787 cron, ts 1785994442.274029.
- `references/run-id-drift-detection.md` (added 2026-08-06, v1.6.0) — drop-in Phase 1.0 recipe for the deploy-run babysit sub-class: detects when a force-push between cron creation and first tick has cancelled the original `actions/runs/<id>`, and re-discovers the current deploy run for the branch. Self-healing (no cron-edit races). Worked example: PR #8787 cron 2026-08-06, original 31072371181 → new 31075008771.
- `references/runner-pool-clearance-babysit.md` (added 2026-08-06, v1.8.0) — drop-in worked example + REST-vs-GraphQL rate-limit fallback recipe + PR-head-vs-branch-tip drift detection recipe + sparse-poster decision tree for the runner-pool / CI-clearance babysit sub-class. Verified PR #8794, 2026-08-06: cron `b6c8887f546e`, original head `a3c3c19e` → live head `930210ca` / branch tip `77652b09` (7 unpushed-to-PR commits), queue drained 152/3 → 1/0, GraphQL rate-limited → REST fallback succeeded.
- `references/stale-thread-ts-fallback.md` (added 2026-08-06, v1.7.0) — worked example for the "Stale `thread_ts` in cron prompt" section. Documents the C0AUXSVFSA2 canonical-home verification for thread `1785990587.321239` (PR #8787), the `thread_not_found` ladder probe, and the cross-tick pattern for crons inheriting stale prompts. Read this when authoring a new cron with a hardcoded `thread_ts` and you want to verify the channel before the prompt lands.
- `references/runner-pool-clearance-babysit.md` (added 2026-08-06, v1.8.0) — worked example, decision tree, and edge cases for the runner-pool sub-class. PR-head-vs-branch-tip drift recipe, REST-vs-GraphQL rate-limit fallback, sparse-poster decision tree, edge cases (cron-prompt-baked SHA stale, trailing-comma force-push shape, dual-state diagnostic zone, pool drain victory condition, head advance victory condition, ao session ls surprise worker). Verified PR #8794 first tick 2026-08-06.
- `references/runner-pool-premise-mismatch.md` (added 2026-08-06, v1.9.0) — premise-mismatch self-cancel protocol for the runner-pool sub-class. Detection recipe (when does the structural premise lift?), post template (under 12 lines, no fix proposal), self-cancel sequence (post-then-cancel, primary `hermes cron remove`), three-option operator decision matrix, prompt-baking checklist. Verified PR #8794 cron `b6c8887f546e` first tick 11:52Z — premise lifted on all three signals (pool 152/3 → 1/0, head a3c3c19e → 930210ca, 5 fixable CI failures); posted divergence notification to thread `1785996838.635219` (ts `1786017124.478359`), self-cancelled, [SILENT] thereafter.
- `references/all-gates-0-billable-diagnostic.md` (added 2026-08-06, v1.10.0) — the all-gates predicate (`commits/<HEAD_SHA>/check-runs`, not the prompt's named subset) + the `actions/runs/<id>/timing` 0-billable-duration diagnostic. Worked example from PR #815: prompt named 3 gates, PR had 4 check-runs, `Example discipline` failed with `billable_ms=0` and `run_duration_ms=902000` (queued 15 min, never executed). Re-ran via `actions/runs/<id>/rerun` (200 OK), re-monitored as queued. Three test cases for extending `tests/test_babysit_runner_pool_subclass.py` if it exists.
