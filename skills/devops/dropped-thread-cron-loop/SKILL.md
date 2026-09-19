---
name: dropped-thread-cron-loop
description: Diagnose repeated dropped-thread pings.
---

# Dropped-thread-followup cron loop — class-level diagnostic

## Trigger

`U0A4G7LDJ4R` (MCP Agent Mail bot, `bot_id=B0A3MS7G08P`) repeatedly
posts the same `[Dropped-thread followup] This thread appears to have
gone cold.` on a single Slack thread **multiple times within 30 min**
even though the agent has already replied in-thread with a status /
closure message.

## Root cause (verified 2026-08-18)

`~/.smartclaw/scripts/dropped-thread-followup.sh` decides a thread is "cold"
by scanning `conversations.history` (channel-root view) and checking the
original prompt for an agent reply (`_agent_answered_since_last_user()`).
**It does NOT read `conversations.replies` (thread view).**

Result: any reply the agent posts **in-thread** is invisible to the
cooldown check. Each cron tick sees the channel-root post with no agent
reply, concludes "still cold," and re-nudges. Per-CHANNEL cooldown exists
but no per-THREAD cooldown, so the same thread can be re-pinged
indefinitely.

## Diagnostic fingerprint (run these 3 checks)

1. **Bot identity** — message author `U0A4G7LDJ4R` or
   `bot_id=B0A3MS7G08P` with text starting
   `[Dropped-thread followup] This thread appears to have gone cold.`
2. **Parent** — `parent_user_id` is `U09GH5BR3QU` (Jeffrey), not the agent
3. **Thread already closed** — call `conversations.replies(channel_id=<chan>,
   thread_ts=<thread_ts>)` and confirm ≥1 reply from `U0AEZC7RX1Q`
   (hermes bot) AFTER the user's last message

If all 3 match, this is the cron loop, not a real dropped message.

## Daily-batch triage (10+ escalations in one daily-thread)

When the cron opens a single daily-thread in `#all-jleechan-ai`
(`${SLACK_CHANNEL_ID}`) and fires 3–20+ escalations in succession, post ONE
channel-root reply covering all of them in a table — do NOT reply to each
escalation individually (that fans into 10+ in-thread acks and triggers
more pings).

### Per-thread forwarder into the daily-thread (2026-08-22 sub-case)

When the daily-thread contains **only forwarder messages from MCP Agent
Mail** (`U0A4G7LDJ4R` / `B0A3MS7G08P`) of the form
`@U09GH5BR3QU [Dropped-thread escalation] Gave up after 3 nudges with
no resolution — needs your review: <https://jleechanai.slack.com/archives/<CHAN>/p<TS>>`,
each forwarder points at a DIFFERENT underlying thread. The right
action is:

1. For each forwarder URL, **extract the underlying channel + ts** and
   call `conversations.replies` (or xoxp curl if cross-workspace, see
   `slack-cross-workspace-fallback-xoxp`) on the **underlying thread**.
2. **Classify the underlying thread** via the dropped-thread triage
   classes below.
3. **Reply once per underlying thread** in-thread with the appropriate
   closed-proof / status message.
4. **Do NOT reply in the daily-thread itself** — the daily-thread is a
   transport mechanism, not a conversation to maintain. Replying there
   breaks `slack-never-hand-post-your-own-reply` (the agent was invoked
   from the daily-thread, so hand-posting is the wrong path).
5. Mark the **daily-thread key** (`<chan>_<daily_ts>`) as `gave_up:true`
   in `~/.smartclaw/logs/dropped-thread-state.json` after handling each
   forwarder, so future forwarders from this same daily-thread skip
   silently. **Increment `count` and append to `reason_extra`** so the
   forensic ledger records which underlying threads each forwarder
   pointed at — this is the only way to recover the forwarder history
   later.

**Pitfall (verified 2026-08-22):** If the user (or the cron) sends an
identical forwarder message **as an out-of-band user message** (wrapped
in `[OUT-OF-BAND USER MESSAGE …]`), do NOT treat it as a new
operator ask — it is the SAME bot forwarder being delivered through a
second transport. Per `never-hallucinate-no-new-content`, verify the
message body matches the prior forwarder template before acting. If
yes, follow the same 5-step recipe; do NOT spawn a 4th investigation
lane.

**Pitfall (verified 2026-08-22):** A single underlying thread can be
forwarded into the daily-thread **multiple times in one morning** (4th
copy of `C0AH3RY3DK6/p1787242310815029` observed). The per-THREAD
cooldown in `~/.smartclaw/scripts/dropped-thread-followup.sh` does NOT
block forwarder-to-daily-thread delivery — only direct-to-thread nudges.
This is a real cron bug: the script should suppress MCP Agent Mail
forwarders whose cited thread already has `gave_up:true`. Surface to
operator, do not silently absorb.

**Pitfall (verified 2026-08-22, full-day extension):** Same daily-thread
can collect **12+ forwarders** across a full day, spanning MULTIPLE
channels (`#worldai`, `#jleechanbrain`, etc.) and MULTIPLE triage
classes (`done / no-op`, `done / shipped`, `done / merged`,
`done / awaiting decision`, plus in-flight sub-tasks that are SEPARATE
work items from the cron probe). The 5-step recipe scales linearly —
just iterate. The cross-channel hop is invisible to the recipe:
extract URL → read underlying thread → classify → reply in underlying
thread → update daily-thread key. The forensic-ledger `reason_extra`
field carries the per-class distribution so the operator can audit at
end-of-day.

**Pitfall — `_is_automated_report` self-quoting recursion (verified
2026-08-23, surfaced on `${SLACK_CHANNEL_ID}/p1787447685478169` "Check cmux"
thread, also seen on synthetic-probe threads #13/#14/#15 in daily-thread
`${SLACK_CHANNEL_ID}/1787386595.347729`).** The deeper mechanism behind
recursive probe loops: `~/.smartclaw/scripts/dropped-thread-followup.sh`
defines `_is_automated_report()` in TWO copies — `~/.smartclaw/scripts/`
(both around lines **720** and **1396** as of 2026-08-23). Neither
copy recognizes the `Ack: <thread-id> ... action needed: <yes|no>`
format that `mcp-mail-ack-format` documents as the canonical
self-acknowledgment header. Result: the agent's `Ack:` reply is
treated as a fresh human message, the watcher concludes "still cold,"
fires another probe. Each probe nests the prior `Ack:` as the new
"Original request:" → recursion confirmed at depth 3+ on the
synthetic-probe threads.

**Pitfall — rate-limit empty-body recursion (verified 2026-09-17,
surfaced on daily-thread `${SLACK_CHANNEL_ID}/p1789670857.968959` re-arming 3×
on underlying `C0AH3RY3DK6/p1789662554.752099`).** Distinct mechanism
from the `_is_automated_report` pitfall: the agent *does* reply, so
`_agent_answered_since_last_user()` passes, but the reply text is
empty because the model provider returned the `:stopwatch: The model
provider is rate-limiting requests. Please wait a moment and try
again.` fallback. The cron sees "a reply exists but contains no
status" and re-arms. Recipe:

1. **Diagnose**: pull the underlying thread; look for `text == ""`
   OR text matching `^:stopwatch: The model provider is rate-limiting
   requests` from `U0AEZC7RX1Q` between user messages. If you find
   ≥1 such empty-body reply, this pitfall applies.
2. **Don't just keep acking** — every empty-body ack is invisible to
   the cron AND creates more empty bodies on the next tick.
3. **Post ONE real-status ack** in-thread (via the gateway reply path,
   never hand-post). The ack must contain actual content: PR URL +
   `mergedAt`/`mergedBy` for done sub-goals + worker dispatch proof
   (PID, branch, brief path) for in-flight sub-goals.
4. **Mark the daily-thread key `gave_up:true`** in
   `~/.smartclaw/logs/dropped-thread-state.json` so the next cron tick
   skips. Same `jq` recipe as the `done / merged` class.
5. **Cron-side fix** (operator opt-in, do NOT auto-apply per
   `hermes-deploy-pipeline`): reject empty-body agent replies as
   "still cold" in the cron script — count a rate-limit fallback body
   as no reply, and suppress further nudges after N empty-body
   replies. Companion fix to the `_is_automated_report` regex patch.

Companion recipe: see
`references/case-2026-09-17-rate-limit-empty-body-partial-done.md` —
covers the **partial-done + auto-default-dispatch** pattern that
paired with this recursion (sub-goal A MERGED, sub-goal B is real
new work that the prior agent stalled on with a `commit-no-pick-one-menus`
violation asking "APPROVE B+M3 or alternate?"). Right move per
`/sq` line 26: auto-default to the recommended model split
(`B+M3` design / `M3` impl), dispatch immediately, record the
auto-picked rationale in the brief, DO NOT post a 2+ option menu.

The right fix is in the script, not the agent:

```bash
# Add to BOTH _is_automated_report copies (~line 720 and ~line 1396)
if re.match(r'^Ack:\s+\S+\s+.*action needed:\s+(yes|no)\b', t, re.IGNORECASE):
    return True
if re.match(r'^Ack-of-ack:\s+\S+', t, re.IGNORECASE):
    return True
```

Surface this to operator as a `~/.smartclaw/` self-mod requiring explicit
opt-in (no `/a` / `/finish` / `/af` triggered → `no-confirmation-gate`
does NOT fire → use `harness-postmortem` skill via `/meta` or
explicit `patch the cron` opt-in). Do NOT auto-fix inline; the
`hermes-deploy-pipeline` contract requires staging-repo PR + `deploy.sh`.

A regex-only short-circuit for the synthetic-probe class
(`Automated E2E Alert Test` / `Verdict: VERIFIED`) is a useful
companion fix; documented separately in
`references/case-2026-08-23-24-forwarders-full-day.md`.

**Pitfall — superseded PR + successor-PR bug (verified 2026-08-23,
forwarders #19/#20 + #24 in daily-thread `${SLACK_CHANNEL_ID}/1787386595.347729`,
underlying threads `C0AH3RY3DK6/p1787377695501619` and the PR-lifecycle
companion `C0AH3RY3DK6/p1787299543490919` which transitively cites the
same PR).** When the original cited PR was CLOSED (not merged) by the
operator as "Superseded by #X action_resolution + #Y refactors", the
cron will keep firing on the original thread until the daily-thread
key hits its max-count. Recipe:

1. **Verify the CLOSED state explicitly** — do NOT assume CLOSED from
   the closing comment alone. Run
   `gh pr view <N> --json state,mergedAt,mergedBy,closedAt,closed` and
   confirm `state=CLOSED, mergedAt=null, closed=true`. A "stale but
   CLOSED" PR is a distinct end-state from "merged on main".
2. **Acknowledge the supersession explicitly** — paste the operator's
   closing comment verbatim (e.g. *"Superseded by #X action_resolution
   bug fix and #Y refactors schema cleanup. The 24-commit history on
   this branch is preserved in both successor PRs."*). This is the
   proof the original goal is genuinely obsolete, not "I forgot to
   check on it".
3. **Clean up any orphan worktree** — when the prior session force-
   pushed onto a branch like `fix/pr9132-merge-conflicts` that was NOT
   the actual PR head, delete the orphan worktree + local branch
   immediately. Per `pr-clean-branch-from-main-no-history-bloat`,
   leaving the orphan would trip next-work audit.
4. **During the read, you may discover a real bug in the successor
   PR.** Example from 2026-08-23: PR #9273 (successor to #9132) had
   `mvp_site/main.py:2871` referencing `constants.CAMPAIGN_PATCH_IMMUTABLE_FIELDS`
   which is undefined (actual constant: `CAMPAIGN_PATCH_ALLOWED_FIELDS`),
   causing 3 Directory tests core-mvp-3 failures. Surface this as a
   NEW finding in the ack — paste the failing test names + the
   1-line fix recipe (add alias OR rename reference) — but **do NOT
   push to the operator's successor PR branch** per
   `never-push-onto-someone-elses-pr-head`. Offer instead to dispatch
   a claudem worker on a fresh `feat/<topic>-fix` worktree.
5. **Mark the daily-thread key `gave_up:true`** per the standard
   recipe. The cron will keep probing the original thread, but each
   forwarder into this daily-thread is now a no-op.

The cron probes are correct to keep firing on the original thread —
the underlying `done / superseded + new finding` state IS still
relevant to the operator (because the successor PR has a bug). The
bug is the leverage to actually fix the loop: dispatch the fix, the
successor PR clears, the cron stops firing. This is the rare case
where the right "stop the loop" action is **fix the underlying work**,
not just `gave_up=true` the daily-thread key.

**Pitfall — in-flight sub-task vs. cron probe cited goal (verified
2026-08-23, forwarder #19 — PR #9227 active CI repair).** When the
underlying thread contains both a DONE-cited-goal AND a separate
IN-FLIGHT sub-task (e.g. operator mid-thread pivoted to "add unit
tests and bring to /ready" → worker dispatched, babysit cron armed,
but the original "Just do it directly" goal shipped long ago), the
cron probe will echo only the ORIGINAL goal. Recipe:

1. **Classify the cited goal first** — run the standard 5-step recipe
   on what the cron actually asked. If the cited goal is genuinely
   done, the ack template is `done / shipped`.
2. **Then surface the in-flight sub-task separately** — note the
   babysit cron ID, the current head SHA, the failing CI checks, and
   the operator decision required. Do NOT claim "work is complete"
   for the cited goal AND hide the in-flight sub-task; surface both
   in the same table with distinct rows.
3. **The cron probe echoes the cited goal, NOT the sub-task.** This
   means the agent must hold two truths: (a) the cron probe is
   correctly answered as `done / shipped`, AND (b) there's a live
   operator-facing sub-task that still needs attention. Don't conflate
   them into a single "in-flight" verdict.

Verified case: PR #9227 (`feat/uc-streak-gate-lw-tone-24h-cd14`) —
original goal "LW tuning" shipped, but babysit cron `73ff43b4c59b`
armed, head `23557214`, 1 NEW PR-related CI failure (Design Doc Grep
Gates LOC 12438 vs threshold 12435), 1 known pre-existing failure
(`test_god_mode_output_contract_is_final_instruction` same-SHA
verified on `origin/main`). Operator decision: (a) shrink
`mvp_site/world_logic.py` by 4 lines, or (b) bump the gate threshold
in `.github/workflows/design-doc-grep-gates.yml`.

**Pitfall — synthetic-probe `done / no-op` class (verified 2026-08-23,
daily-thread `${SLACK_CHANNEL_ID}/1787386595.347729` forwarders #13/#14/#15).**
When the underlying thread root is an automated E2E health probe
(`UserID=U0BC138QXUJ hermes_pc`, body text starts `Dark Factory
Automated E2E Alert Test`, contains `Verdict: VERIFIED` + `Timestamp:`
+ `Host: jeff-ubuntu`), there is **no human ask** — the thread root
is a self-verifying signal. Same ack pattern as `done / no-op` but
the blocker is the recursive probe loop, not a stale agent reply.
Triage: (1) confirm the root `UserID` is `U0BC138QXUJ` (not
`U09GH5BR3QU`), (2) confirm body contains `Verdict: VERIFIED` AND
`Automated E2E Alert Test` AND `Timestamp:`, (3) reply with the
`done / no-op` ack template + the synthetic-probe classification,
(4) do NOT file a new work item, do NOT dispatch, (5) surface the
cron-side fix as a `patch the cron` opt-in for the operator.

**Pitfall — `done / merged` vs `done / shipped` in cross-channel
hops (verified 2026-08-23).** When the cited underlying thread
spans a different channel than the daily-thread (e.g. forwarder #5
in `#all-jleechan-ai` cited `#worldai/p1787261209775249`, forwarder
#8 cited `#jleechanbrain/p1787427880161399`, forwarder #17 cited
`#all-jleechan-ai/p1787447685478169` itself), the triage recipe is
unchanged — extract channel + ts from the URL, read the underlying
thread via `mcp__slack__conversations_replies(channel_id=<chan>,
thread_ts=<ts>)` (or xoxp curl if cross-workspace), classify, reply
in underlying thread. Do NOT reply in the daily-thread itself
(same rule as the main recipe — daily-thread is transport, not
conversation).

Full worked examples in
`references/case-2026-08-22-daily-thread-12-forwarders-full-day.md`
and `references/case-2026-08-23-24-forwarders-full-day.md`.

See `references/case-2026-08-22-daily-thread-per-thread-forwarders.md`
for the full transcript + state-file edits + cron-side bug analysis.

**Table columns:** thread link + topic | current state (done / no-op /
awaiting decision / shipped) | action needed from user.

**Triage classes seen so far:**
- **Done / no-op** — thread already closed in prior session; cron is
  looping (most common, ~7/10 in a typical batch)
- **Done / merged** — real PR exists and is **MERGED on `origin/main`**;
  the cited goal is genuinely complete in production. Stronger than
  `done / shipped` (which means OPEN+MERGEABLE; the merge is pending
  operator `/green` or skeptic-cron). Reply with `state: merged —
  action needed: no` and the `mergedAt` + `mergedBy` proof line. See
  the *Pitfall — `done / merged` requires `mergedAt` + `mergedBy` proof
  line* entry below for the required proof fields. Verified cases:
  PR #9098 on 2026-08-22 (god-mode narrative placeholder,
  `mergedAt=2026-08-21T05:23:44Z mergedBy=${GITHUB_USER}`); PR #9206 on
  2026-08-22 (mobile UX fix, `mergedAt=2026-08-22T20:59:16Z
  mergedBy=${GITHUB_USER}`).
- **Done / superseded + new finding** — original PR is **CLOSED (not
  merged)** because operator superseded it with successor PRs. Verify
  with `gh pr view <N> --json state,mergedAt,mergedBy,closedAt,closed`
  — when `state=CLOSED, mergedAt=null, closed=true`, the cited goal
  is genuinely obsolete. Reply with the closing comment verbatim +
  the successor PR URLs. **If during the read you discover a real bug
  in a successor PR** (e.g. undefined constant, broken test fixture,
  wrong reference), surface it as a NEW finding — do NOT push to the
  operator's successor PR branch per `never-push-onto-someone-elses-pr-head`;
  instead offer to dispatch a claudem worker on a fresh
  `feat/<topic>-fix` worktree. Verified cases: PR #9132 superseded by
  PR #9272 + #9273 on 2026-08-23T04:40:24Z; agent discovered
  `mvp_site/main.py:2871` references `constants.CAMPAIGN_PATCH_IMMUTABLE_FIELDS`
  which is undefined (actual: `CAMPAIGN_PATCH_ALLOWED_FIELDS`), causing
  3 Directory tests core-mvp-3 failures. Fix is 1-line: add alias OR
  rename reference. See *Pitfall — superseded PR + successor-PR bug*
  below.
- **Shipped** — real PR exists and is OPEN/MERGEABLE; user just needs
  to review (rare, ~1/10)
- **Awaiting decision** — analysis on record but build not dispatched
  because the user hasn't picked a winner; reply with a single-word
  trigger (`ship X` / `close`) instead of a 2+ option menu
  (`no-pick-one-menus`)
- **Real new work** — genuine unfinished task surfaced by the
  escalation; route via `finish-the-job` (dispatch, apply inline, or
  hand off with explicit blocker)
- **Done / partial — paste-ready handoff** — deliverable produced via
  automation up to the platform's wall; user needs to perform 1 manual
  step (Cmd+V, click-to-confirm, OAuth-grant) to finish. The work is
  not "shipped" but it is "done-as-far-as-the-agent-can-do." Do NOT
  mark `gave_up=true` for this class — see
  `references/dropped-thread-paste-ready-handoff-2026-08-21.md` for
  the full recipe (verified case: Google Docs kix-canvas wall on
  `${SLACK_CHANNEL_ID}/p1787222330.239339`).

**Why channel-root:** Slack mobile does NOT load threaded replies by
default. A 10-row table at the surface is more useful than 10 invisible
in-thread one-liners.

**End-state for the daily-batch ack:** state that all threads are
covered, list the durable fix bead (`rev-d63nu`), offer
`PATCH dropped-thread cooldown` as a single dispatch trigger if the user
wants the cron fixed.

## Recommended agent-side action

- **Do NOT keep replying** in-thread to each duplicate ping — each
  in-thread reply is invisible to the cooldown, so the next tick still
  fires. Posting more replies just adds noise without breaking the loop.
- **RE-FETCH LIVE STATE BEFORE EACH ACK (added 2026-08-22, verified on
  `C0AH3RY3DK6/p1787242833516949`).** Each dropped-thread probe is a
  fresh ask, even when the agent already replied in-thread minutes
  earlier. The previous reply's claim may have gone stale: head SHA may
  have moved (a new `Merge origin/main` can land overnight), CI may
  have cycled, a bot review state may have changed. **Recite "the PR is
  ready" from a prior turn without re-querying `gh pr view` /
  `gh api graphql` is the bug** — and worse, **inventing a
  field-semantic rationalization** ("reviewDecision is human-only, the
  CR SUCCESS status context is the actual approval") to defend a stale
  claim compounds the failure. Required pre-ack discipline per probe:
  1. `gh pr view <N> --json state,mergeable,reviewDecision,headRefOid`
  2. `gh api graphql` for `reviewThreads(first:100){totalCount, nodes{isResolved}}` + review state
  3. `gh pr view <N> --json statusCheckRollup` for the latest CI cycle on the current head
  4. If any field has drifted from the prior ack, **state the new reality, not the cached claim**. "Unchanged from prior ack" is only honest after step 3 shows it actually IS unchanged.
- For each duplicate, post **one concise ack** in-thread ONCE per cron generation, then **stop replying** until the cron is patched. The ack must reflect live state, not the cached conclusion.
- **When the work is already done (PR merged, deploy live, ack already
  shipped)** — the cron is firing on a thread whose underlying task
  completed in a prior turn. Don't keep acking; mark the thread
  `gave_up=true` in the dropped-thread-state JSON so the watcher
  permanently skips it. Verified 2026-08-18 on
  `${SLACK_CHANNEL_ID}_1787111938.251339` (action_resolution warning, PR #9058
  MERGED on origin/main + deployed to dev):
  ```bash
  jq '.nudged["${SLACK_CHANNEL_ID}_1787111938.251339"].gave_up = true |
      .nudged["${SLACK_CHANNEL_ID}_1787111938.251339"].reason = "PR #9058 MERGED on origin/main + deployed to dev. Stable needs redeploy but requires operator gate. /repro skipped because dev page requires auth session that Aside does not currently have."' \
      ~/.smartclaw/logs/dropped-thread-state.json > /tmp/dt.new
  mv /tmp/dt.new ~/.smartclaw/logs/dropped-thread-state.json
  ```
  The script's `nudge_gave_up()` guard at line ~343 returns 0 (skip),
  so the watcher permanently ignores the thread. Verify:
  `jq '.nudged["<chan>_<ts>"]' ~/.smartclaw/logs/dropped-thread-state.json`
  should show `gave_up:true`. This is the durable escape when a
  duplicate-ping loop has been triggered by a cron that can't tell
  the work is done.
- **Tell the user honestly** when the work was complete but you didn't
  surface it — `gave_up=true` is a one-way ack, but the user still
  deserves to know the thread exists and what the actual state was.
  Pattern in reply: *"Cron firing on a thread whose work was already
  done. Marked gave_up=true in dropped-thread-state. Original ask
  satisfied; what was missing was the surface ack."*
- File a bead (`br create "..." --priority 2`) and surface the loop to
  the user with the bead ID so they know it's a known cron bug, not an
  unfinished task. Use phrasing like
  *"The dropped-thread-followup cron itself is the bug; here's the durable fix."*
- For surfacing at the channel-root level (operator channel), prefer the
  Slack-mobile-safe pattern: state table at channel root, not nested in
  thread — per the user-profile note "Slack mobile on this user's device
  does NOT load threaded replies by default."

## Recommended durable fix (already tracked as bead `rev-d63nu`)

Patch `~/.smartclaw/scripts/dropped-thread-followup.sh`:

1. **`_agent_answered_since_last_user()`** — for each candidate thread,
   call `conversations.replies(channel_id, thread_ts=<ts>)` and check if
   any reply from `U0AEZC7RX1Q` (hermes bot) is present **after the
   user's last message**. If yes, skip the nudge.
2. **Per-thread cooldown** — extend the cooldown key from
   `(channel, original_ts)` to `(channel, thread_ts)` so the same thread
   is not re-pinged within `DROP_THREAD_COOLDOWN` (default 24h).

## Anti-patterns to avoid

- ❌ Replying in-thread to every duplicate ping (makes the loop louder)
- ❌ Filing a new bead for each duplicate (creates bead cruft)
- ❌ Trusting the cron to "settle down" — it won't without the patch
- ❌ Hand-posting Slack replies via `mcp__slack__conversations_add_message`
  — gateway auto-threads; per `slack-never-hand-post-your-own-reply`
- ❌ **Reciting a cached "PR is /ready" conclusion from a prior turn
  without re-fetching live state (verified 2026-08-22,
  `C0AH3RY3DK6/p1787242833516949`).** Each probe is a fresh ask. Head
  SHA can move (overnight `Merge origin/main`), CI can re-cycle, the CR
  review state can change. If the prior reply said "PR is /ready" and
  the next probe fires 20 minutes later, the right move is to
  re-query `gh pr view` + `gh api graphql` BEFORE acking — and if the
  picture drifted, surface the drift honestly.
- ❌ **Inventing a field-semantic rationalization to defend a stale
  "ready" claim (verified 2026-08-22, same thread).** When the live
  data shows the gate isn't actually green (CodeRabbit only COMMENTED,
  Bugbot hit usage limit, `reviewDecision=null`), the wrong move is
  to invent a defense like *"reviewDecision only tracks human reviews,
  the CR bot review surfaces as the green `SUCCESS` status context,
  which counts as approval"*. That is exactly the kind of confabulation
  `## COMMIT: proof-before-claim` exists to prevent. Correct move:
  name the unverified gate in the ack ("CodeRabbit only COMMENTED,
  Bugbot usage-limited — /ready is not actually claimable"), and ask
  the user for the call.

## Diagnose from terminal when MCP returns `thread_not_found`

When investigating the cited thread_ts from a terminal diagnostic, the
MCP `mcp__slack__conversations_replies` tool can return `thread_not_found`
even when the message exists — the tool normalizes the ts to compact
form (`1786914650236939`) which Slack rejects. Use the REST API directly
with the dotted decimal-string form (`1786914650.236939`). If the bot
token doesn't have access (DM channels like `${SLACK_CHANNEL_ID}`, or channels
in other workspaces), fall back to the user `xoxp` token.

Verified recipe (single-line, copy-pasteable; see
`slack-cron-report-health/references/bash-login-shell-slack-curl-recipe.md`
for full explanation):

```bash
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  SLACK_USER_TOKEN="$(bash -lic 'echo $SLACK_USER_TOKEN')" \
  bash -c 'curl -fsS -H "Authorization: Bearer $SLACK_USER_TOKEN" "https://slack.com/api/conversations.replies?channel=C0AH3RY3DK6&ts=1786914650.236939&limit=10"'
```

If the thread was already closed in-thread, the bottom row of the
output will be `user=U0AEZC7RX1Q` (hermes bot) — that's the smoking gun
that the cron is wrong.

## Verified reproduction

1. Post a top-level message in `#worldai` (`C0AH3RY3DK6`)
2. Agent replies in-thread with status / closure
3. Within 30 min, `U0A4G7LDJ4R` posts `[Dropped-thread followup]` on the
   same thread — the agent's in-thread reply is invisible to the detector
4. Agent re-acks → another followup 30 min later → infinite loop

## Confirmed real cases (2026-08-18)

- `C0AH3RY3DK6/p1786915507985569` (Planning Block Option C1) — 3 pings
  before agent discovered the cron-side bug
- `C0AH3RY3DK6/p1786915509056089` (Planning Block Option C2) — 3 pings
- `C0AH3RY3DK6/p1786914650236939` (Planning Block Option D) — 3 pings
- `${SLACK_CHANNEL_ID}/p1786951089082819` (Wizard redo PR) — same pattern;
  babysit cron `c2539211f385` self-cancels on terminal state

## Confirmed cases — daily-batch triage (2026-08-18)

A single daily-thread in `#all-jleechan-ai` (`${SLACK_CHANNEL_ID}`) accumulated
**10 escalations in one session**, all from `U0A4G7LDJ4R`. Each cited
thread had a different actual state, proving the daily-batch triage
classes above:

| Thread | Topic | Class | Resolution |
|---|---|---|---|
| `C0AH3RY3DK6/p1786914650236939` | Option D — suggestion chips | done / no-op | design-share ack only, no winner ever called |
| `C0AH3RY3DK6/p1786915507985569` | Option C1 — pencil-marker textarea | done / shipped | PR #8952 MERGED 2026-08-17 (`1eb2ac4e`) |
| `C0AH3RY3DK6/p1786915509056089` | Option C2 — explicit divider | done / no-op | reference-only (C1 was preferred) |
| `${SLACK_CHANNEL_ID}/p1786951089082819` | Wizard redo PR | done / shipped | PR #9046 OPEN/ready, babysit cron `c2539211f385` armed |
| `C0AH3RY3DK6/p1786926884640309` | PR #8952 BEFORE evidence | done / shipped | PR #8952 MERGED |
| `C0AH3RY3DK6/p1787046570436989` | Run /af on PR #8498 + #7886 | awaiting decision | factory beads exist (`jleechan-c1zd` / `jleechan-j6fw`); GH rate-limit is the only blocker |
| `C0AH3RY3DK6/p1786919402921189` | DIRECTION 2 — Illuminated | done / no-op | closed in prior session (`ts 1787064017`) |
| `C0AH3RY3DK6/p1786919404489849` | DIRECTION 4 — Risk-tinted | done / shipped | PR #9070 OPEN/MERGEABLE, +610/-2, 8 files |
| `C0AH3RY3DK6/p1786919405449799` | DIRECTION 5 — Two-up grid | awaiting decision | analysis on record; user picks titles-only / descriptions-first-class / close |
| `${SLACK_CHANNEL_ID}/p1787098654574219` | PR #9042 preview evidence | real new work | preview slot serving PR #8988's image (not #9042); preview-deploy-slot race, not code bug |

**Lesson:** even when 10/10 escalations look identical (same bot, same
template), the actual thread state can vary across all four triage
classes. Always `conversations.replies` each cited thread before
classifying — never assume "no-op" from the escalation template alone.

## Related skills

- `dropped-messages` — Class A/B/C/D coverage model + recovery workflow
- `mcp-mail-ack-format` — single-message ack format for MCP Agent Mail probes
- `slack-never-hand-post-your-own-reply` — gateway auto-threads your reply
- `slack-identify-correct-thread-when-reading` — channel-root vs thread
- `slack-cron-report-health` — diagnose silent/broken Slack-bound crons
- `babysit-cron-self-cancel-discipline` — babysit crons must self-cancel

## References

- `references/case-2026-08-18-action-resolution.md` — concrete case where cron fired on a thread whose PR #9058 was already MERGED on origin/main + deployed to dev; only stable redeploy was the actual operator action. Verified the `gave_up=true` state-file mark is the right durable resolution.
- `references/dropped-thread-paste-ready-handoff-2026-08-21.md` — concrete case where the agent's deliverable reached a platform wall (Google Docs kix-canvas); the right closeout is "title set + body on clipboard + 1-Cmd-V handoff" + a new `partial_handoff: true` schema flag (NOT `gave_up=true`), so the cron fires at lower frequency until the user pastes + replies. Adds the **5th triage class** ("done / partial — paste-ready handoff") to the table above.
- `references/case-2026-08-21-mcp-agent-mail-daily-escalations.md` — same cron-side bug surfaces through a SECOND channel: the MCP Agent Mail bot posts per-thread `@U09GH5BR3QU [Dropped-thread escalation]` mentions into the daily-thread channel even when work is verified-complete. The right response is one tight "closed — proof" reply per underlying thread, NOT a table reply in the daily channel itself. Anti-pattern: replying to the operator-channel mention as if it were a new incident.
- `references/case-2026-08-22-daily-thread-per-thread-forwarders.md` — three consecutive per-thread forwarders from MCP Agent Mail into a single daily-thread (`${SLACK_CHANNEL_ID}/1787386595.347729` → `C0AH3RY3DK6/p1787218494789569`, `p1787205681983699`, `p1787242310815029`), each pointing at an OPEN+MERGEABLE PR with pre-existing `origin/main` CI debt (verified via same-name+SHA+zero-overlap rule). Captures: (a) the 5-step per-thread-forwarder recipe, (b) forensic-ledger pattern (`count` + `reason_extra` on the daily-thread key), (c) the OUT-OF-BAND-message-as-bot-forwarder pitfall (`never-hallucinate-no-new-content`), (d) the cron bug where per-THREAD cooldown does NOT suppress MCP Agent Mail forwarders whose cited thread already has `gave_up:true`.
- `references/case-2026-08-22-pr9101-re-fetch-live-state.md` — three identical dropped-thread acks posted across one cron probe cycle, each re-stating a cached "PR is /ready" claim without re-fetching `gh pr view` / `gh api graphql`. When the operator finally asked "is the PR actually /ready ?", the live data showed head SHA had moved, `reviewDecision=null`, CodeRabbit only COMMENTED (not APPROVED), and CI on the new head was partially blank. Captures: (a) the 4-query pre-ack re-fetch recipe, (b) the field-semantic rationalization anti-pattern (e.g. "reviewDecision is human-only, the CR SUCCESS status context is the actual approval"), (c) how to spot the bug in your own replies (3+ identical acks, invented field semantics, head SHA mismatch). Companion to the *Anti-patterns to avoid* entries added 2026-08-22.
- `references/case-2026-08-22-daily-thread-12-forwarders-full-day.md` — full-day extension of the per-thread-forwarders pattern: **12 forwarders** into one daily-thread across 6 hours, spanning 2 channels (`#worldai` + `#jleechanbrain`) and 4 triage classes (`done / no-op`, `done / shipped`, `done / merged`, `done / awaiting decision`, plus an in-flight PR #835 sub-task). Captures: (a) the cross-channel variant (recipe unchanged, forensic-ledger records the hop), (b) the `done / merged` class behavior (verify `gh pr view --json state,mergedAt,mergedBy`, ack with `mergedAt` + `mergedBy` proof line, do NOT confuse with `done / shipped`), (c) the JSON-mutation pitfall (`jq` shell-quoting conflict → fall back to `python3 - <<'PYEOF'` heredoc with `json.load`/`json.dump`), (d) the `execute_code` venv trap (fall back to `terminal` + system python when the active venv is stale/missing), (e) class distribution table at end-of-day.
- `references/case-2026-08-23-24-forwarders-full-day.md` — extended full-day (2026-08-22 → 2026-08-23) of the per-thread-forwarders pattern: **24 forwarders** into one daily-thread (`${SLACK_CHANNEL_ID}/1787386595.347729`), spanning 3 channels (`#worldai` + `#jleechanbrain` + `#all-jleechan-ai` itself), 6 triage classes, and 2 real harness bugs surfaced in-thread (PR #9132 superseded + successor PR #9273 undefined-constant bug; `~/.smartclaw/scripts/dropped-thread-followup.sh` `_is_automated_report` self-quoting recursion). Captures: (a) the superseded-PR + successor-PR-bug triage class (close + verify CLOSED, paste closing comment verbatim, do NOT push to operator's successor branch, offer fresh-worktree dispatch), (b) the in-flight sub-task vs. cron probe cited goal separation rule (two truths: cron is correctly answered `done / shipped`; the sub-task is a separate operator decision), (c) cross-channel `done / merged` ack pattern (PR #9206 / #9098 with `mergedAt` + `mergedBy` proof line), (d) cross-channel-into-self variant (forwarder #17 cited the operator's personal channel, same as the daily-thread itself), (e) OUT-OF-BAND-duplicate-forwarder pattern recipe (verify body matches prior forwarder template, bump `count`, append `DUPLICATE of Nth` line, keep reply short), (f) end-of-day class distribution table.
- `references/case-2026-09-17-rate-limit-empty-body-partial-done.md` — two distinct mechanisms in one cron loop: (a) agent replies during a model-provider rate-limit window return the `:stopwatch: …` fallback with empty content, cron classifies as "no real status" and re-arms (sibling of the `_is_automated_report` self-quoting recursion but distinct mechanism); (b) the underlying thread contained TWO sub-goals — one DONE/MERGED (PR #9911 rukkagamer unlimited) and one real new work that the prior agent stalled on with a `commit-no-pick-one-menus` violation asking "APPROVE B+M3 or alternate?". Right recipe: per `/sq` line 26, auto-default to B+M3 design / M3 impl, dispatch immediately on a clean `feat/firestore-rate-limit-allowlist` worktree from `origin/main`, post ONE in-thread ack covering both truths (merged + dispatched) with prod/non-prod delta and PID proof. Cron-side fix: reject empty-body agent replies as "still cold" + suppress after N empty-body replies.
