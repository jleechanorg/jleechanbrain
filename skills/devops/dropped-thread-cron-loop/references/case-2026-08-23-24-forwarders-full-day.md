# Case: 24 forwarders into one daily-thread (2026-08-22 → 2026-08-23)

## Summary

Across ~22 hours, a single daily-thread in `#all-jleechan-ai`
(`${SLACK_CHANNEL_ID}/1787386595.347729`) accumulated **24 per-thread
forwarders** from MCP Agent Mail (`U0A4G7LDJ4R` / `bot_id=B0A3MS7G08P`).
Each forwarder cited a DIFFERENT underlying thread; the daily-thread
itself is just the transport channel. The per-thread-forwarder recipe
scaled linearly across:

- **3 channels**: `#worldai` (`C0AH3RY3DK6`), `#jleechanbrain`
  (`C0AJ3SD5C79`), and `#all-jleechan-ai` itself (`${SLACK_CHANNEL_ID}`).
- **6 triage classes**:
  - `done / merged` (PR #9098, #9206)
  - `done / shipped` (PR #9101, #9132-superseded, #9150, #9203,
    #9261, #9270)
  - `done / no-op` (synthetic E2E alert threads #13/#14/#15,
    "Check cmux" thread #17)
  - `done / awaiting decision` (PR #9132 design-doc-gate thread #16;
    Google gog/gws research threads #10/#11)
  - `done / superseded + new finding` (PR #9132 → #9272/#9273
    thread #24 — agent found undefined `CAMPAIGN_PATCH_IMMUTABLE_FIELDS`
    bug in operator's successor PR)
  - **In-flight sub-task** (PR #9227 CI repair — forwarders #19/#20;
    the original goal IS done, the sub-task is a separate operator
    decision)
- **2 real harness bugs surfaced in-thread**:
  1. `_is_automated_report` self-quoting recursion in
     `~/.smartclaw/scripts/dropped-thread-followup.sh` (lines 720 + 1396
     both lack the `Ack:` skip rule that `mcp-mail-ack-format`
     documents).
  2. PR #9273 undefined `CAMPAIGN_PATCH_IMMUTABLE_FIELDS` constant
     (3 Directory tests core-mvp-3 failing).

## Triage recipe (5 steps, scales linearly)

1. **Extract the underlying channel + ts from the forwarder URL.**
   Pattern: `https://jleechanai.slack.com/archives/<CHAN>/p<TS>` →
   `<CHAN> = "C0..."`, `<TS> = "1787...".DDDDDD`. The
   `${SLACK_CHANNEL_ID}_<daily_ts>` key in `dropped-thread-state.json` is
   for the daily-thread itself; the underlying-thread key is
   `<CHAN>_<TS>` and lives in the same JSON.

2. **Read the underlying thread.** Use
   `mcp__slack__conversations_replies(channel_id=<chan>,
   thread_ts=<ts>, limit=15)`. For cross-workspace bots, fall back to
   `slack-cross-workspace-fallback-xoxp` (xoxp user token). The MCP
   tool normalizes ts to compact form which Slack rejects — use the
   dotted decimal-string form.

3. **Classify the underlying thread** via the triage classes in
   `SKILL.md`. Each class has a distinct ack template. Most common
   in this 24-forwarder batch: `done / shipped` (10/24) and
   `done / no-op` (5/24). Rarest: `done / superseded + new finding`
   (1/24).

4. **Reply once per underlying thread in-thread** with the
   appropriate closed-proof / status message. Do NOT reply in the
   daily-thread itself — the gateway auto-threads your reply per
   `slack-never-hand-post-your-own-reply`, and hand-posting breaks
   the auto-thread path.

5. **Update the daily-thread key** in
   `~/.smartclaw/logs/dropped-thread-state.json`:
   - Increment `count`.
   - Append a `| Nth per-thread forwarder (C.../p...)` line to
     `reason_extra` recording the cited thread + classification.
   - Keep `gave_up:true` so future forwarders from this same daily
     thread skip silently.

   **For duplicates** (forwarder body byte-identical to a prior
   forwarder): append `| Nth per-thread forwarder — DUPLICATE of
   Mth (same thread, same template)`. Keep the reply short.

   **For OUT-OF-BAND messages** (`[OUT-OF-BAND USER MESSAGE …]`
   wrapper): per `never-hallucinate-no-new-content`, verify the
   body matches the prior forwarder template before acting. If yes,
   follow the same recipe; do NOT spawn a 4th investigation lane.

## Sub-case: superseded PR + successor-PR bug

The rare `done / superseded + new finding` class. The cron keeps
firing on the original thread until the daily-thread key hits its
max-count. Recipe:

1. **Verify the CLOSED state explicitly** — do NOT assume CLOSED
   from the closing comment alone. Run
   `gh pr view <N> --json state,mergedAt,mergedBy,closedAt,closed`
   and confirm `state=CLOSED, mergedAt=null, closed=true`.

2. **Acknowledge the supersession explicitly** — paste the
   operator's closing comment verbatim. This is the proof the
   original goal is genuinely obsolete.

3. **Clean up any orphan worktree** — when the prior session
   force-pushed onto a branch like `fix/pr9132-merge-conflicts` that
   was NOT the actual PR head, delete the orphan worktree + local
   branch immediately. Per `pr-clean-branch-from-main-no-history-bloat`.

4. **During the read, you may discover a real bug in the successor
   PR.** Surface it as a NEW finding in the ack — paste the failing
   test names + the 1-line fix recipe — but **do NOT push to the
   operator's successor PR branch** per
   `never-push-onto-someone-elses-pr-head`. Offer instead to
   dispatch a claudem worker on a fresh `feat/<topic>-fix` worktree.

5. **Mark the daily-thread key `gave_up:true`** per the standard
   recipe. The cron will keep probing the original thread, but each
   forwarder into this daily-thread is now a no-op.

**Verified case (2026-08-23):** PR #9132 closed at
`2026-08-23T04:40:24Z` by `${GITHUB_USER}` with comment *"Superseded
by #9272 action_resolution bug fix and #9273 refactors schema
cleanup. The 24-commit history on this branch is preserved in both
successor PRs. Ironclad contract at ."*. During the read, agent
discovered `mvp_site/main.py:2871` references
`constants.CAMPAIGN_PATCH_IMMUTABLE_FIELDS` which is **undefined**
(actual: `CAMPAIGN_PATCH_ALLOWED_FIELDS`), causing 3 Directory tests
core-mvp-3 to fail:
- `test_campaign_patch_field_whitelist.py`
- `test_share_lifecycle_composed_integration.py::test_composed_share_mint_fork_forgery_rejection_and_expiry_flow`
- `test_share_routes.py::TestShareRoutesUnchanged::test_flask_route_expiry_profile_handle_and_patch_security_e2e`

The fix is 1-line: add alias OR rename reference. Agent offered
to dispatch a claudem worker on a fresh
`feat/9273-immutable-fields-fix` worktree (NOT pushing to the
operator's `pr9132-other-stuff-new` branch).

## Sub-case: in-flight sub-task vs. cron probe cited goal

When the underlying thread contains both a DONE-cited-goal AND a
separate IN-FLIGHT sub-task, the cron probe will echo only the
ORIGINAL goal. Recipe:

1. **Classify the cited goal first** — if the cited goal is
   genuinely done, the ack template is `done / shipped`.

2. **Then surface the in-flight sub-task separately** — note the
   babysit cron ID, the current head SHA, the failing CI checks,
   and the operator decision required. Do NOT claim "work is
   complete" for the cited goal AND hide the in-flight sub-task;
   surface both in the same table with distinct rows.

3. **The cron probe echoes the cited goal, NOT the sub-task.**
   Hold two truths: (a) the cron probe is correctly answered as
   `done / shipped`, AND (b) there's a live operator-facing
   sub-task that still needs attention. Don't conflate.

**Verified case (2026-08-23):** PR #9227
(`feat/uc-streak-gate-lw-tone-24h-cd14`). Original goal "LW
tuning: gate on combat successes + non-antagonistic tone +
once-per-day + antagonist-every-2-weeks" shipped end-to-end.
Babysit cron `73ff43b4c59b` armed, every 10m, self-cancels on
MERGED/CLOSED. Head `23557214`, 1 NEW PR-related CI failure
(Design Doc Grep Gates LOC 12438 vs threshold 12435 — 3 lines
over), 1 known pre-existing failure
(`test_god_mode_output_contract_is_final_instruction` same-SHA
verified on `origin/main`). Operator decision: (a) shrink
`mvp_site/world_logic.py` by 4 net lines, OR (b) bump the gate
threshold in `.github/workflows/design-doc-grep-gates.yml`.

## Sub-case: `_is_automated_report` self-quoting recursion

Surfaced on forwarder #17 (`${SLACK_CHANNEL_ID}/p1787447685478169` "Check
cmux" thread) and on synthetic-probe threads #13/#14/#15
(`C0AH3RY3DK6/p1787296665156669` and `p1787297316799179`).

**Mechanism:** `~/.smartclaw/scripts/dropped-thread-followup.sh` defines
`_is_automated_report()` in TWO copies (~line 720 and ~line 1396).
Neither recognizes the `Ack: <thread-id> ... action needed: <yes|no>`
format that `mcp-mail-ack-format` documents as the canonical
self-acknowledgment header. Each agent ack is treated as a fresh
human message; each probe nests the prior ack as the new "Original
request:" → recursion at depth 3+ confirmed.

**Fix (do NOT apply inline — `~/.smartclaw/` self-mod requires operator
opt-in via `/meta` / explicit `patch the cron`):**

```bash
# Add to BOTH _is_automated_report copies (~line 720 and ~line 1396)
if re.match(r'^Ack:\s+\S+\s+.*action needed:\s+(yes|no)\b', t, re.IGNORECASE):
    return True
if re.match(r'^Ack-of-ack:\s+\S+', t, re.IGNORECASE):
    return True
```

**Companion fix for synthetic-probe class** (regex skip for
`Automated E2E Alert Test` / `Verdict: VERIFIED`):

```bash
# Skip synthetic-probe threads entirely
if 'Automated E2E Alert Test' in t and 'Verdict: VERIFIED' in t:
    return True
if t.startswith(':test_tube: Dark Factory'):
    return True
```

## Cross-channel `done / merged` ack pattern

When a forwarder cites a thread where the PR is **MERGED on
`origin/main`** (not just OPEN/MERGEABLE), the ack template is
`done / merged` and MUST include the `mergedAt` + `mergedBy` proof
line. Verified cases this session:

- **PR #9098** (god-mode narrative placeholder) — `state=MERGED,
  mergedAt=2026-08-21T05:23:44Z, mergedBy=${GITHUB_USER}, merge
  commit 3651b5d31`. Commit `530d4f92a8` (2026-08-21T04:52 UTC,
  31 min before merge) shipped the interpretation-2 fix
  (narrative == god_mode_response → replace with placeholder). PR
  is in production; cron probe echoes the original pre-merge
  goal.

- **PR #9206** (mobile UX fix for "Du" inside Duplicate button,
  Choose Theme panel clipping, horizontal scroll on iOS) —
  `state=MERGED, mergedAt=2026-08-22T20:59:16Z, mergedBy=${GITHUB_USER}`.
  Playwright iPhone 14 Pro emulation reproduced all 3 bugs
  BEFORE; minimal CSS fix to `mvp_site/frontend_v1/style.css`
  media max-width:575.98px AFTER; 3 new regression tests in
  `testing_ui/core_tests/test_my_campaigns_mobile_ux.py`. **Note:**
  this thread ALSO contains a post-merge follow-up ask from
  Jeffrey at `ts=1787432379` ("make a followup PR to move
  evidence to PR desc and lets clear out / delete checked in
  evidence in general") which is a separate work item NOT what
  the cron probe is asking about — don't conflate.

## End-of-day class distribution (2026-08-22 → 2026-08-23)

| # | Forwarder | Cited thread | Class | Cross-channel? |
|---|---|---|---|---|
| 1 | p1787218494789569 | PR #9242/#9243 | done / shipped (blocked on pre-existing origin/main CI debt) | #worldai |
| 2 | p1787205681983699 | PR #9150 | done / shipped | #worldai |
| 3 | p1787242310815029 | PR #9203 | done / shipped (CR re-review re-pinged) | #worldai |
| 4 | p1787242833516949 | PR #9101 | done / shipped (3 duplicate cron probes same morning) | #worldai |
| 5 | p1787261209775249 | PR #9206 | done / merged | #worldai |
| 6 | (duplicate of 5) | same | done / merged (no-op dup) | #worldai |
| 7 | p1787264020542439 | PR #9098 | done / merged | #worldai |
| 8 | p1787427880161399 | gog vs gws research | done / shipped (gws banned, gog upgraded to v0.37.0) | #jleechanbrain |
| 9 | (duplicate of 8) | same | done / shipped (no-op dup) | #jleechanbrain |
| 10 | p1787427895844229 | "Use /ms" Google CLI research | done / awaiting decision (3 implementation moves gated on "do it") | #jleechanbrain |
| 11 | (duplicate of 10) | same | done / awaiting decision (no-op dup) | #jleechanbrain |
| 12 | p1787294865360509 | PR #835 wiki-ingest fix | done / shipped + in-flight sub-task (/ready blocked on CR) | #worldai |
| 13 | p1787296665158349 | dark-factory E2E alert VERIFIED | done / no-op (synthetic probe, not a real goal) | #worldai |
| 14 | p1787297316799179 | dark-factory E2E alert VERIFIED | done / no-op (synthetic probe) | #worldai |
| 15 | (duplicate of 14) | same | done / no-op (no-op dup) | #worldai |
| 16 | p1787296781666669 | "should we delete design-doc-gate?" PR #9132 | done / awaiting decision (3-option table: keep / keep+fix / delete) | #worldai |
| 17 | p1787447685478169 | "Check cmux" status query | done / no-op (lookup done; surfaced `_is_automated_report` harness bug) | #all-jleechan-ai (SELF) |
| 18 | p1787341025098629 | "Improve agent readiness" PR #9270 | done / shipped | #worldai |
| 19 | p1787299543490919 | "LW tuning" PR #9227 | done / shipped (cited goal) + in-flight sub-task (Design Doc Grep Gates LOC FAIL) | #worldai |
| 20 | (duplicate of 19) | same | done / shipped + in-flight sub-task (no-op dup) | #worldai |
| 21 | p1787341314616599 | "Where's mobile slow load thread?" lookup | done / no-op (lookup done; retry-storm fix is separate work item) | #worldai |
| 22 | (duplicate of 21) | same | done / no-op (no-op dup) | #worldai |
| 23 | p1787430681405239 | Red-team worldarchitect.ai | done / shipped (PR #9261 OPEN/MERGEABLE) | #worldai |
| 24 | p1787377695501619 | "Fix CI / bring #9132 to /ready" | done / superseded + new finding (PR #9132 CLOSED by operator; discovered undefined `CAMPAIGN_PATCH_IMMUTABLE_FIELDS` in successor PR #9273) | #worldai |

**Distribution:** shipped 9/24 (37.5%) + shipped-with-subtask 2/24
(8.3%) + merged 3/24 (12.5%) + no-op 6/24 (25%) + awaiting decision
2/24 (8.3%) + superseded 1/24 (4.2%) + synthetic-probe no-op 3/24
(12.5%). Duplicates: 5/24 (20.8%).

## Lessons

1. **The recipe scales linearly.** 24 forwarders, 24 underlying-thread
   reads, 24 in-thread acks, 24 daily-thread-key bumps. The forensic
   ledger (`count` + `reason_extra`) is the only way to recover the
   forwarder history at end-of-day — it must be appended on EVERY
   forwarder including duplicates.

2. **Cross-channel is invisible to the recipe.** `#all-jleechan-ai`
   daily-thread citing `#worldai` or `#jleechanbrain` or itself
   (forwarder #17). Extract URL → read underlying thread via
   `conversations_replies` → classify → reply in underlying thread →
   update daily-thread key. Same recipe, regardless of cross-channel
   hop.

3. **The cron probe echoes the CITED goal, not the sub-task.** This
   is the most common reason an agent produces a "stale" reply:
   they answer the cron probe correctly, but the operator's
   mid-thread pivot to a different scope (e.g. forwarder #12's PR
   #835 fix request) is a separate live work item. Surface both in
   the same table with distinct rows.

4. **The cron has TWO mechanisms for false positives.** (a)
   per-THREAD cooldown doesn't honor MCP Agent Mail forwarders whose
   cited thread already has `gave_up:true` (forwarder #4 → #5 → #6
   on PR #9206 shows the cron will re-fire on the same thread
   indefinitely); (b) `_is_automated_report` recursion on synthetic-
   probe threads (forwarders #13 → #14 → #15 nest depth 3+).

5. **The right "stop the loop" action is sometimes FIX THE
   UNDERLYING WORK, not just `gave_up=true`.** Forwarder #24's
   PR #9132 is closed, but the operator's successor PR #9273 has a
   real bug. The bug is the leverage: dispatch the fix, the
   successor PR clears, the cron stops firing on the original
   thread (because the operator is now actively working the
   successor).

6. **json.load / json.dump is more robust than jq for shell-quoting
   hot spots.** When the `reason_extra` text contains nested quotes
   (`"Obviously still not working"` inside an existing quoted
   string), jq's `-r` flag fights the bash quoting. Fall back to
   `python3 - <<'PYEOF'` heredoc with `json.load` + `json.dump` —
   verified on forwarder #10 (jq syntax error → python3 fallback
   succeeded).
