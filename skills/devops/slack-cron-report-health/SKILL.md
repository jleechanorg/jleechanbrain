---
name: slack-cron-report-health
description: Diagnose silent Slack-bound crons end-to-end.
changelog:
  - "1.2.0 (2026-08-17): New Section 1a — `last exit code != 0` means PARTIAL RUN, never cosmetic. Adds the completion-sentinel diagnostic (`grep \"Done —\" <log> | tail -1` vs current tick), blast-radius measurement (configured work list vs processed set), the injected-ERR-trap localization recipe, the `set -e` + bare-`return 1` bug class with fix + generalized regression-test shape, and three cheap disproofs for blaming stderr noise. New top pitfall against calling a nonzero exit 'cosmetic'/'not blocking' without proving the script reached its final line. Verified 2026-08-17 on ai.smartclaw.schedule.dropped-thread-followup (Slack ${SLACK_CHANNEL_ID}/p1786948684686239, fix jleechanorg/jleechanbrain#827): a prior turn called it cosmetic broken-pipe noise while the script had been aborting mid-run for 6 days and had not scanned 1 of 5 priority channels once. Transcript: references/2026-08-17-partial-run-nonzero-exit-set-e-abort.md."
  - "1.4.0 (2026-08-18): New pitfall — **Mac AO daemon is NOT expected to run; /linux is the primary AO host**. Operator direction (`We shouldn't expect mac AO daemon to be up. We use /linux primarily for AO`) means any cron that surfaces Mac-AO-down as a warning is misaligned with operator policy and the warning itself becomes the noise. The cross-machine AO reporter must SILENCE `mac_daemon_up=false` (still probe it for diagnostics in the header line, but DO NOT emit a Mac-DOWN warning line). Verified 2026-08-18 on PR #828 (jleechanorg/jleechanbrain) — the second commit on the replay branch (cdcebb0448818a96cee1d487cc89698048946a55) replaces the would-be 🚨 Mac-DOWN line with `maybe_mac_down` returning empty. The header still carries `mac_daemon=up|DOWN` so the operator can see the state in passing. Companion to the 4a /healthz probe rule: probe Mac for diagnostics, but do NOT surface as an actionable signal. Worked transcript: `references/2026-08-18-mac-ao-silenced-by-operator-direction.md`."
  - "1.3.0 (2026-08-18): New pitfall — bash script `PATH-bootstrap` vs `PATH-override` in test harness. The `export PATH=\"$HOME/bin:...\"` block at the top of scripts like `scripts/ao-progress-reporter.sh` (defending against launchd's minimal env) silently clobbers the test harness's `PATH=\"$STUB_BIN:/usr/bin:/bin\"`, causing real-ssh stderr noise (`Could not resolve hostname host: nodename nor servname...`) to appear in `bash -x` traces. The noise is INERT — the test still passes — and should NOT be read as evidence that the script is calling real `ssh`. Reference: `references/2026-08-18-clean-replay-of-merged-stuck-pr-817.md`. New pitfall — the clean-replay pattern also applies to never-merged, gate-stuck cron-fix PRs (PR #817 → #828); a fix that has been authored + tested but cannot land because of merge-gate pressure is itself the bug, and clean-replay onto current `origin/main` is the action — not more agent time on the same body. Worked example recorded in the same reference."
  - "1.5.0 (2026-08-21): Split Section 3 into 3a (CLI output shape drift, pre-existing) and 3b (CLI SUBCOMMAND confusion, NEW). The `ao-progress-reporter.sh` blank-body bug hid for 4 weeks because the script called `ao status --json` (daemon-status object) thinking it was the sessions command — `jq 'length'` returned the daemon-status object's key count (8) which looked plausible, and the session-iteration loop yielded zero items every tick. Each prior session's fix hit a different layer (cross-machine reconciliation, suppression policy, daemon-down surface) without addressing the root cause. Adds the diagnostic recipe (verify the subcommand name, not just the output), the fix shape (call `ao session ls --json` + unwrap `.data` envelope), the field-rename trap (post-#828 schema: `.id` not `.name`, dropped `.branch`/`.prUrl`/`.prNumber`), and the regression-test shape (fake `ao` CLI emits both shapes; assert the unwrap). Replaces the existing pitfall with one that names the actual bug class. Verified on PR jleechanorg/jleechanbrain#834 (commit `05e26ae048`); transcript: `references/2026-08-21-ao-cli-subcommand-confusion-blank-report.md`."
  - "1.1.0 (2026-08-14): New pitfall — Hermes-managed launchd plists MUST use `~/.smartclaw/logs/scheduled-jobs/<label>.{out,err}.log` for StandardOutPath/StandardErrorPath, NOT `~/logs/scheduled-jobs/`. A wrong-path plist silently writes elsewhere (or nowhere) and the cron looks silent because no log appears under the expected grep path. Verified 2026-08-14 on PR #819 (jleechanorg/jleechanbrain, claw-codestandards-tuesday plist) via Cursor Bugbot — keep all four plists aligned on the same base path."
---

# slack-cron-report-health

When a Slack-bound recurring cron goes silent or posts the wrong thing, work through these layers. Each layer is independent — check the cheapest first.

## When to use

- User says "X isn't posting" / "the daily report is silent" / "still not fixed" / "the cron seems broken"
- A fix was supposedly shipped to fix the cron, but the cron still misbehaves
- The cron ticks but the Slack thread has no new messages
- The cron posts noise / empty blocks / "no changes" repeatedly
- **`launchctl print` shows `last exit code != 0`** for a cron — even when it appears to be working and delivering messages (Section 1a; this state is routinely misread as cosmetic)
- A watcher-of-watchers / health-monitor keeps alerting on a cron that "looks fine" on inspection

## When NOT to use

- Cron is firing correctly and posting correct content → no action
- User asks how to BUILD a new cron reporter → that's `cron-jobs-and-messaging-credentials` or `finish-the-job`
- Single-message cron (not recurring) → use `dropped-messages` instead
- Babysit cron watching a specific PR → `babysit-stale-watchdog`

## Diagnostic layers (work top-down)

### 1. Is the cron actually ticking?

```bash
launchctl print gui/$(id -u)/<plist-label>
# Look for: state, runs (count), last exit code, run interval, env vars
tail -100 ~/.smartclaw/logs/<cron>.log
```

If `state = not running` and `runs = N` hasn't incremented → cron is dead. Fix: re-bootstrap plist.
If `runs` increments but Slack has nothing → the script ran but didn't post. Move to layer 2.
If `runs` increments, Slack DOES get messages, but `last exit code != 0` → **partial run**. Go to 1a — this is neither of the two states above and is the easiest one to misdiagnose.

### 1a. `last exit code != 0` means PARTIAL RUN — never dismiss it as cosmetic

**The trap:** a cron can tick on schedule, post real messages, write plausible log lines, and still be **aborting partway through its main loop on every single tick**. Everything processed before the abort point looks healthy; everything after it is silently never processed. Because the visible evidence (fresh log lines, delivered Slack posts) all comes from the surviving prefix, the natural conclusion is "it's working, the exit code is just noise." That conclusion is wrong often enough that `last exit code != 0` should be treated as an open bug until proven otherwise.

**Check the completion sentinel FIRST — cheapest, highest-signal, ~5 seconds.**

Well-built cron scripts end with a summary line (`Done — actioned=N skipped=N`, `Complete`, `Finished run`). If the script has one, the diagnostic is trivial:

```bash
# When did this script LAST run to completion?
grep "Done —" ~/.smartclaw/logs/<cron>.log | tail -1
# Compare against the most recent tick:
tail -3 ~/.smartclaw/logs/<cron>.log
```

If the last completion line is days or weeks older than the latest tick, **the script has been aborting mid-run since that date.** That single date is your regression window — everything after it is a partial run. If the script has NO completion sentinel, add one; it is the difference between a 5-second diagnosis and an hour of guessing.

**Then measure blast radius — what got starved?**

An abort inside a loop starves whatever the loop would have reached *after* the abort point. Iteration order decides who loses. Compare the configured work list against what the log proves was actually processed:

```bash
# What was configured?
grep -n 'PRIORITY_CHANNELS\|_CHANNELS=' scripts/<cron>.sh | head
# What did the last tick actually reach?
grep "$(date +%Y-%m-%d)" ~/.smartclaw/logs/<cron>.log | grep -o 'Checking channel C[A-Z0-9]*' | sort -u
```

A configured list of 5 and a processed set of 4 is not a rounding error — the missing entry has been dark since the regression date. In the 2026-08-17 case the 5th of 5 priority channels (`${SLACK_CHANNEL_ID}`) had not been scanned once in 6 days, while the first 4 looked perfectly healthy.

**Then localize the abort with an injected ERR trap.** Do not read 1,800 lines hunting for it; make bash tell you:

```bash
cp scripts/<cron>.sh /tmp/trace.sh
python3 - <<'PY'
p='/tmp/trace.sh'; s=open(p).read()
s=s.replace("set -euo pipefail",
  "set -euo pipefail\ntrap 'echo \"ERRTRAP line=$LINENO cmd=[$BASH_COMMAND] rc=$?\" >&2' ERR", 1)
open(p,'w').write(s)
PY

# Separate lock dir so the probe does not contend with the live cron
DRY_RUN=1 DROP_LOCK_DIR=/tmp/probe.lock bash /tmp/trace.sh >/tmp/out.txt 2>/tmp/err.txt
echo "exit=$?"; grep ERRTRAP /tmp/err.txt | tail -5
```

Output is the exact aborting line, one run, no guesswork:

```
ERRTRAP line=1680 cmd=[return 1] rc=1
```

Always pass the script's own lock-dir override (`DROP_LOCK_DIR`, `LOCK_DIR`, …) so the probe cannot lose a race against a live tick and self-diagnose as "lock contention."

**Validate the fix as an A/B, not a vibe.** Same command, before and after, comparing three things: exit code, count of work items processed, and presence of the completion sentinel.

```
before: exit_code=1, 4 of 5 channels, "Done —" absent
after:  exit_code=0, 5 of 5 channels, "Done — actioned=7 skipped=27"
```

#### The `set -e` + `return 1` bug class (root cause in the 2026-08-17 case)

A shell function that uses `return 1` as an ordinary "no, this condition doesn't apply" signal — not as an error — is a live grenade under `set -euo pipefail` if it is ever **called bare**:

```bash
# BROKEN: under set -e, the common `return 1` path kills the entire script
detect_agent_fabrication "$a" "$b" "$c"
_fab_rc=$?          # ← never reached on the return-1 path

# CORRECT: guard the call, pre-seed the variable
_fab_rc=0
detect_agent_fabrication "$a" "$b" "$c" || _fab_rc=$?
```

The `cmd=[$BASH_COMMAND]` field pointing at a bare `return 1` is the signature. Grep the whole script for the idiom — the same author usually wrote it more than once:

```bash
grep -n -B1 '_rc=\$?' scripts/<cron>.sh   # any $? capture after an UNGUARDED call is the same bug
```

A regression test should assert the *class*, not the one line: flag any `$?` capture whose preceding line lacks `||`, `if`, or `&&`. That way the bug cannot reappear elsewhere in the file.

#### Ruling out stderr noise before blaming it

Before attributing a nonzero exit to stderr messages, confirm the message can even be fatal:

- **Is the signal already trapped?** `grep -n "trap '' PIPE" scripts/<cron>.sh` — if SIGPIPE is trapped at the top of the file, broken-pipe lines are inert and provably cannot be your exit code. In the 2026-08-17 case, `trap '' PIPE` sat at line 43 while the diagnosis blamed broken pipes at line 462.
- **Do the counts line up?** 19 stderr lines accumulated over 12 days cannot explain an exit code that is nonzero on *every* tick. Frequency mismatch is disproof.
- **Does the timeline line up?** Check whether the stderr entries predate the regression window from the completion-sentinel check. Noise that was present while the script was still completing successfully is not the cause.

### 2. Why didn't the script post?

Common reasons a tick produces no Slack message:

- **Lock contention** — overlap lock (`mkdir $LOCK_DIR`) failed → another instance holds it. Check stderr.
- **Post-suppression logic** — the script intentionally suppresses when "no change since last tick". This is *correct behavior*; check if the data actually changed by reading the state file.
- **Token missing/invalid** — `SLACK_BOT_TOKEN` not in launchd env → `post_slack` returns silently. Verify env via `launchctl print`.
- **Slack API error** — script posted but `chat.postMessage` returned `{"ok":false}`. Check `.err` log.
- **Thread routing lost** — script posted but to wrong channel/thread. Compare `ts` in `conversations_replies`. See the **stale thread_ts pitfall** below for the case where the cron's prompt-supplied `thread_ts` is invalid.

### 2a. Stale `thread_ts` in cron prompt — silent auto-route to nearest active thread

**Symptom:** The cron fires, the script posts to Slack via `chat.postMessage` with `thread_ts=<X>` (where `<X>` came from the cron's own prompt string), `ok:true` returns, but the resulting message has `thread_ts=<Y>` where `<Y>` is a different, unrelated thread in the same channel. The cron did NOT error — it silently mis-routed.

**Root cause:** The cron's prompt string was authored with a `thread_ts` that no longer exists as a real Slack message (deleted, archived, hand-typed wrong, hallucinated from a prior session, or copied from a prompt template that drifted). Slack's `chat.postMessage` API does NOT validate that `thread_ts` references a real message — it accepts any string and falls back to the most recent sibling thread. Verified 2026-08-13 on `C0BDEAJH8PK` — cron `fb870a6e9023` (`Daily Level Up FAIL followup`) was given `thread_ts=1786605287.481999`, but `conversations.history(limit=20)` showed no such message; the post landed at `ts=1786606694.089399` with `thread_ts=1786605089.752099` (the nearest adjacent thread, completely unrelated).

**Diagnostic — mandatory pre-flight when a cron posts to a specific thread:**
```bash
# Verify the cron-supplied thread_ts is a real Slack message
bash -lic 'curl -fsS -X GET "https://slack.com/api/conversations.history?channel=<chan>&limit=20" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); [print(m[\"ts\"]) for m in d.get(\"messages\",[])]"'
# If the cron-supplied ts is NOT in the output, it is stale/wrong/deleted.
```

**Mitigations:**
1. **Cron-authoring rule** — when a cron is created, the `thread_ts` it will post to MUST be captured from `conversations.history` in the SAME turn that the cron is created (not from memory, not from a prior session's stale context, not from a template). If the cron will outlive the message it targets (e.g., a 20-min followup after a parent cron), the parent cron must verify the child ts is still valid at child-cron-creation time, not at child-cron-execution time.
2. **First action of the followup cron** — `conversations.history(channel_id=<chan>, limit=5)` to verify the target ts still exists. If absent: post with a "thread_ts was stale; this landed in the most recent active thread" preamble, OR self-cancel with a diagnostic message.
3. **Operational hygiene** — when authoring followup crons, prefer short-lived one-tick crons (`hermes cron create --at 20m --delete-after-run --repeat 1`) over recurring crons (`--every`), because one-tick crons are less likely to outlive the parent message. See SOUL.md `## COMMIT: one-time-status-cron-after-every-task` for the canonical shape.
4. **Companion watchdog** — extend `babysit-stale-watchdog` pattern: any cron whose prompt contains a literal `thread_ts=<digits>.<digits>` substring should re-validate that ts on every tick. If the ts disappears, the cron should self-cancel with a diagnostic rather than silently mis-route.

**Bug-ref:** Slack `C0BDEAJH8PK` cron `fb870a6e9023`, 2026-08-13 — cron supplied `thread_ts=1786605287.481999` which did not exist as a real Slack message; the post auto-routed to `1786605089.752099`. Operator had to read the body's "Note: cron-supplied thread_ts was stale" line to find the actual landing place.

### 3. CLI subcommand confusion vs. CLI output shape drift

**Two distinct bug classes** masquerade as "the cron logged WARN but no body":

**3a. CLI output shape drift** (pre-2026-08-21): The daemon's *same* command changes its output format silently. The script expects array `[]`, the daemon returns object `{"state":"stale",...}`. Diagnostic: WARN line `ao stdout does not start with '[' — first 200 chars: {...}`. Mitigations: adapt the parser, or call the DB directly (sqlite3 ground-truth).

**3b. CLI subcommand confusion** (NEW 2026-08-21, PR jleechanorg/jleechanbrain#834): The script calls the **wrong `ao` subcommand** entirely — one that exists and returns valid JSON, but is not the "list sessions" command. The script then iterates the wrong JSON shape and silently yields zero items, and the suppression logic fires every tick. Symptoms look identical to 3a: empty thread header at 07:08 UTC, no body, suppression log lines. The WARN line in 3a may NOT fire (the wrong subcommand returned valid JSON, just not the right JSON).

Real-world case: `scripts/ao-progress-reporter.sh` called `ao status --json` (which returns the **daemon-status object**: `{state, pid, port, startedAt, uptime, runFile, dataDir, health, ready}`) instead of `ao session ls --json` (which returns `{"data":[...]}`). The bug hid for **weeks** because:
- `jq 'length'` on the daemon-status object returned its key count (8), not 0 — the log line "Found 8 AO sessions" looked plausible
- The session-iteration loop (`jq '.[]'`) on an object yielded nothing, so no per-session suppression check fired against real records
- The suppression branch at the end of the script ("no session changes this tick") fired correctly — because there were literally no sessions iterated
- Same complaint recurred 2026-08-05, 08-08, 08-13, 08-20; each prior session's fix hit a different layer (cross-machine reconciliation, suppression policy, daemon-down surface) without addressing the root cause

**Diagnostic for 3b — verify the SUBcommand, not just the output:**
```bash
# Run each ao subcommand the script uses, with the same flags, and confirm the shape
ao status --json | jq 'keys'                 # → ["dataDir","health","pid","port","ready","runFile","startedAt","state","uptime"]
ao session ls --json | jq '.data | length'  # → N (real session count)
ao session ls --json | jq '.data[0] | keys' # → ["id","projectId","kind","status","harness",...]

# If keys() on status returns 6+ items AND the script iterates with '.[]', you have 3b.
# If session ls returns a real array of sessions AND the script ignores them, you have 3b.
```

**Fix shape:**
```bash
# OLD (wrong subcommand — daemon status, not sessions):
sessions="$(ao status --json)"

# NEW (correct subcommand with envelope unwrap):
raw="$(ao session ls --json)"
if [[ "$raw" == "{"* ]]; then
  sessions="$(echo "$raw" | jq -c '.data // .sessions // []')"
else
  sessions="$raw"
fi
```

**Field rename trap (post-#828 AO rewrite):** Even after switching to the right subcommand, the new schema uses `.id` (not `.name`) and dropped `.branch`/`.prUrl`/`.prNumber` (PR linkage moved to AO's review subsystem). Scripts that extract `.name // empty` will silently skip every session (empty session_name triggers `continue`), and the suppression fires again with a different symptom — "Found N sessions but no report_blocks emitted". Mitigate by mapping `.id // .name` and treating branch/pr_url/pr_number as empty-default.

**Regression test shape (asserts the bug class, not the one line):**
```bash
# tests/test_ao_progress_reporter_session_field.sh — fake ao CLI emits:
#   session ls → {"data":[{"id":"...",...}]}
#   status     → {"state":"ready",...}  # the bug-shape

# Assertions:
# 1. fetch_ao_sessions returns a JSON array (not the daemon-status object)
# 2. .data envelope is unwrapped to a flat array
# 3. .id is extracted (not empty, not falling through to suppression)
# 4. daemon-status object shape is NOT leaked into the session list
```

Bug-ref: PR jleechanorg/jleechanbrain#834 (commit `05e26ae048`, branch `fix/ao-progress-reporter-blank-body`), Slack `C0ALSKLU9KM/1787211649.055189` (4-week operator complaint chain: 2026-08-05, 08-08, 08-13, 08-20). Transcript: `references/2026-08-21-ao-cli-subcommand-confusion-blank-report.md`.

### 4. Cross-machine state drift

If the report covers multiple hosts (Mac + /linux + ...):

- **Daemon running does not mean db fresh** — `ao-go daemon` and similar daemons write only on session lifecycle events, not on tick. Verify freshness with `ssh <host> "sqlite3 ~/.ao/data/ao.db 'SELECT MAX(activity_last_at) FROM sessions'"` — if last activity is days ago, the daemon is idle, not broken.
- **db mtime is not the same as db content freshness** — `ls -la ~/.ao/data/ao.db` shows file mtime, but daemon may have touched the file without new rows. Always query the content.
- **SSH unreachable** — if the script depends on cross-machine SSH and the SSH host is down, the script silently skips the remote half. Test with `ssh -o BatchMode=yes -o ConnectTimeout=4 <host> true`.
- **Three different "alive" questions, three different signals** — the bug-class that PR #817 fixed (cross-machine AO reporter firing "Linux AO db is 384h stale" every 30 min for a week): the **daemon-process question** ("is the daemon actually running and able to serve?") is distinct from the **data-recency question** ("when was the db last touched?") and the **data-correctness question** ("do the rows reflect real state?"). Mixing them produces false positives in BOTH directions — see the `/healthz` probe rule below. The reporter's mtime-based check was answering a data-recency question with a stuck-write signal; a healthy-but-idle daemon legitimately doesn't write for hours/days, so mtime goes stale but the system is fine. Meanwhile the **real** failure mode (a daemon whose process is dead but whose SQLite db is still readable because the OS reopens it on read) gets completely hidden.

#### 4a. The `/healthz` probe rule (replaces mtime as the daemon-alive signal)

For any cron reporter covering a long-running HTTP-served daemon (ao-go, hermes-gateway, sidecar daemons, anything with an HTTP listener), the canonical "is this process alive and able to serve" probe is **`curl -fsS -m 2 http://127.0.0.1:<port>/healthz`** — and verify the response body matches the expected `{"status":"ok"}` shape with `grep`. File mtime is NOT this signal; it's a stale-write detector, not an alive-process detector.

Pattern that PR #817 shipped (works for Mac locally + /linux over SSH, no new dependencies):

```bash
# Mac daemon (local)
mac_daemon_up="false"
if curl -fsS -m 2 "${MAC_HEALTH_URL:-http://127.0.0.1:3001/healthz}" 2>/dev/null \
   | grep -q '"status":"ok"'; then
  mac_daemon_up="true"
fi

# /linux daemon (over SSH) — keep the probe short so a network blip doesn't stall the cron
linux_daemon_up="false"
if ssh -o ConnectTimeout=4 -o BatchMode=yes "$linux_host" \
  "curl -fsS -m 2 '${LINUX_HEALTH_URL:-http://127.0.0.1:3001/healthz}' 2>/dev/null | grep -q '\"status\":\"ok\"' && echo up || echo down" \
  2>/dev/null | grep -q '^up$'; then
  linux_daemon_up="true"
fi
```

When the daemon has **no HTTP listener** but you can read a pidfile / runfile, fall back to:

```bash
# read runfile (e.g. ao's ~/.ao/running.json), then verify the pid is alive
pid=$(jq -r '.pid' ~/.ao/running.json 2>/dev/null)
if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
  daemon_up="true"
else
  daemon_up="false"   # ← this is the actual failure mode: "run-file points to a dead process"
fi
```

**Symptoms that file-mtime was the wrong signal in the first place:** user reports "the cron keeps warning about X being stale, but everything actually looks fine" / "the warning has been firing for days/weeks" / "I checked the box and it's healthy." These are all signature of "signal meant for question A (data recency) being applied to question B (daemon alive)." Diagnose by running the `/healthz` probe manually — if it returns ok, the warning was a false positive and needs replacing, not silencing.

**Symptom that the real daemon is dead but the cron isn't surfacing it:** `ao status --json` returns `{"state":"stale", "error":"run-file points to a dead process"}` (or equivalent) but the cron keeps reporting session counts from the SQLite db as if nothing is wrong. The db is readable independent of the daemon, so any reporter that reads SQLite + mtime and not /healthz will hide the dead-daemon failure mode.

Real-world transcript: `references/2026-08-13-aopr-true-stuck-vs-false-stale.md` — PR #816 used mtime as the stuck-write signal and fired "Linux AO db is 384h stale" every 30 min for a week while the actual broken thing was a Mac daemon whose pid 41591 had been dead since 2026-08-04 (240h). PR #817 replaced mtime with the /healthz probe pattern above; tests: 24/24 PASS.

#### 4b. Operator-policy exceptions: probe-but-don't-surface for non-primary hosts

The 4a `/healthz` rule is "probe and surface". Sometimes the right answer is **"probe but DO NOT surface"** — when the host in question is explicitly off by operator policy and a warning about it is itself the noise. The pattern:

```bash
# Still probe so the header shows the state for situational awareness
mac_daemon_up="false"
if curl -fsS -m 2 "${MAC_HEALTH_URL:-http://127.0.0.1:3001/healthz}" 2>/dev/null \
   | grep -q '"status":"ok"'; then
  mac_daemon_up="true"
fi
# Header line: mac_daemon=up|DOWN  ← still shown
# Warning body: 🚨 "Mac AO daemon is DOWN"  ← DO NOT emit
```

When you discover this kind of policy exception mid-task (operator says "we don't actually run X on that box"), do NOT leave the would-be warning in the code with a `# TODO` comment — silence it. The line itself is the false-positive source; leaving it in the code with intent-to-fix-it-later is itself the bug. The fix is one-line (`maybe_mac_down` returns empty, or the `if mac_daemon_up == false` branch is dropped), and it ships in the same PR as the rest of the cross-machine refactor.

If you find yourself wanting to add a probe-but-don't-surface signal, also ask: **does the operator's "X is off" apply to the test harness?** If a test asserts `BLOCK != ""` when `mac_daemon_up == false`, that test is asserting the BUG, not the contract. Update the test to assert `BLOCK == ""` — the contract is "no warning for off-policy host", and the test should encode that contract. Verified 2026-08-18 on PR #828: Test 6 ("MAC DAEMON DOWN -> SILENT") asserts the empty block; Test 7 ("MAC DAEMON DOWN + linux TRUE stuck -> only linux stale line") asserts the Mac line is absent. Both encode the operator direction into the contract test, not just into the code.

Operator-direction capture rule: when the user states a policy preference about which hosts/conditions should be surfaced vs silenced, the skill update must capture it as a **pitfall**, not just a memory. Memory captures "the user is currently running /linux as primary" — but next session's agent might encounter the same Mac-DOWN warning pattern and emit it anyway. The pitfall in this skill is the durable guard.

### 5. External review/merge blockers (for PR-driven cron fixes)

If the fix was supposedly shipped via a PR but the cron still uses old behavior, the PR may not be merged:

- **Check PR state directly**: `gh pr view <N> --json state,mergedAt,reviewDecision`. If `mergedAt=null`, the fix is NOT on main.
- **Check reviews array directly**: `gh api repos/<owner>/<repo>/pulls/<N>/reviews`. Empty array means no reviewer has submitted. CodeRabbit/Bugbot may have hit usage limits (look for "Review limit reached" or "usage limits" in PR comments).
- **Check the green-gate comment on the PR** — every failed gate run posts a deterministic table to the PR. Read that comment to see WHICH gate failed (for example "Gate 3 FAIL state=none").
- **GitHub Actions log download endpoints return 410** — log retention expires fast. Don't waste time trying to download old logs; fall back to reading the workflow YAML + the PR comment from the gate run.
- **CodeRabbit/Bugbot rate limits are NOT self-fixable from inside the agent.** When the gate failure is "CR APPROVED missing", the agent's options are:
  1. Re-ping `@coderabbitai` (comment-only, hope quota reset)
  2. Re-trigger gate via `gh workflow run green-gate.yml -f pr_number=N -f head_sha=<sha>`
  3. **Unblock via clean-replay** — when `origin/main` is unprotected AND the fix is a single additive commit that can be cherry-picked clean, the agent can replay onto current `origin/main` and squash-merge in one turn. See `references/clean-replay-pattern-stuck-pr-2026-08-13.md` for the recipe + worked example (PR #814 → #816, jleechanorg/jleechanbrain).
  4. Escalate to human for self-approval: `gh pr review <N> --repo <owner>/<repo> --approve`
- **Verify the cron actually uses the new code** — even after merge, the cron reads from `~/.smartclaw/scripts/<script>`, NOT from the repo. The durable-promotion step is `git show origin/main:<script> > ~/.smartclaw/scripts/<script>` + `chmod 755`. Skipping this means the cron keeps running old code even after `mergedAt` is set. The clean-replay reference (option 3 above) covers this as Step 7.

### 6. Sanity-check with live execution

After identifying the blocker, do not declare done until you have run the script manually with the same env the cron uses. Two patterns:

```bash
# Via launchd-env-wrapper.sh (loads SLACK_BOT_TOKEN from .bashrc)
bash ${HOME}/.smartclaw/scripts/launchd-env-wrapper.sh \
  ${HOME}/.smartclaw/scripts/<cron>.sh
# or
launchctl kickstart -k gui/$(id -u)/<plist-label>
```

**Why the wrapper matters**: direct `bash <cron>.sh` invocation fails with `ERROR: SLACK_BOT_TOKEN not set` because launchd-env isn't inherited. The wrapper scripts source `.bash_profile` + `.profile` + explicit `_extract_bashrc_var` for the token.

## Pitfalls

- **Never call `last exit code != 0` "cosmetic" / "not blocking" without proving the script reached its final line.** This is the highest-cost mistake in this skill. A cron that ticks, posts real Slack messages, and writes fresh log lines can still be aborting mid-loop on every tick — the healthy-looking evidence all comes from the surviving prefix before the abort. The proof obligation is one grep: `grep "Done —" <log> | tail -1` must show a timestamp from the CURRENT tick, not one from days ago. Verified 2026-08-17 (`${SLACK_CHANNEL_ID}/p1786948684686239`): a prior turn inspected the same service, found 19 broken-pipe stderr lines, and reported *"Known caveat: cosmetic, doesn't break the nudge — log shows NUDGED rows landing correctly."* The NUDGED rows were real; the script had nonetheless been dying mid-run for **6 days**, and one of five priority channels had not been scanned once in that window. The broken pipes were provably inert (`trap '' PIPE` was already set at line 43). See Section 1a and `references/2026-08-17-partial-run-nonzero-exit-set-e-abort.md`.
- **"The visible work item succeeded" is not evidence the run completed.** Confirming that *this* thread got nudged says nothing about the items the loop never reached. Always check the configured work list against what the log proves was processed (Section 1a, blast-radius step).
- **Don't hand-read a long script hunting for the abort — inject an ERR trap.** One traced run prints `ERRTRAP line=<N> cmd=[<command>] rc=<code>`. Reading 1,800 lines to guess at the culprit is how a 6-day outage stays open.
- **Do not declare done based on "PR opened"** — verify the fix actually reached main (`mergedAt != null`), the cron actually executes the new code, and a live tick produces the expected output.
- **Don't trust `ao status --json` to be the "sessions" command** — `ao status --json` returns the **daemon-status object** (state/pid/uptime/runFile/dataDir/health/ready), NOT a session list. To list sessions, use `ao session ls --json` which returns `{"data":[...]}` envelope. Even if `jq 'length'` returns a plausible number (e.g. 8 = key count of the daemon-status object) and no WARN fires, you may still be iterating the wrong shape and silently emitting zero sessions. Always verify the subcommand name matches the data intent (`ao status` for daemon health, `ao session ls` for session records). Bug class: Section 3b — CLI subcommand confusion. Verified 2026-08-21 on PR #834 (jleechanorg/jleechanbrain) after the bug hid for 4 weeks (operator complaints on 2026-08-05, 08-08, 08-13, 08-20).
- **Do not assume `/linux` is dead from db mtime alone** — query `MAX(activity_last_at)` instead.
- **GH Actions log download endpoints expire fast (HTTP 410)** — fall back to reading the workflow YAML + the PR gate-comment table.
- **Cron-suppressed posts are NOT bugs** — many crons deliberately suppress no-op posts to avoid thread spam. A silent cron with `Found N sessions, no changes this tick` in the log is working as designed; the question is whether the *content* is what the user expects.
- **A warning that fires every tick for a week IS the bug** — if a reporter has been posting the same "X is stale / X is down / X is unreachable" warning repeatedly into a daily thread, the warning itself is the failure mode (false-positive loop), not the underlying condition. Verify by manually running the check the warning is based on; if the underlying state is healthy, the check is the bug, not the state. PR #816 shipped this exact trap: the warning fired 15+ times in 24h while the Linux daemon was healthy, hiding the real bug (Mac daemon dead, pid 41591). Don't tune thresholds to silence the loop — replace the underlying signal with the right one (see Section 4a).
- **The prior session's "pre-existing failures" excuse is dangerous** — confirm by re-running on `origin/main` (the same `git stash` test the agent claims it did). If the failure exists on `main` AND the PR doesn't fix it, the PR scope is wrong.
- **"Merged" ≠ "deployed"** — the cron reads from `~/.smartclaw/scripts/`, not from the repo. After a clean-replay merge, you MUST copy the new file content via `git show origin/main:<path>` and `chmod 755`. See clean-replay reference Step 7.
- **Log-path convention for hermes-managed launchd plists** — Hermes-managed plists under `~/.smartclaw/launchd/ai.smartclaw.schedule.*.plist` MUST use `StandardOutPath`/`StandardErrorPath` pointing at `~/.smartclaw/logs/scheduled-jobs/<label>.{out,err}.log` (NOT `~/logs/...`). A plist pointing at `~/logs/scheduled-jobs/` silently writes to the wrong tree (which may not exist), and the cron "looks" silent because no log file appears under the path you'd grep first. Cursor Bugbot caught this on PR #819 (jleechanbrain): one new plist used `~/logs/scheduled-jobs/` while the other three used `~/.smartclaw/logs/scheduled-jobs/`. Fix: keep all four `StandardOutPath`/`StandardErrorPath` keys aligned on `~/.smartclaw/logs/scheduled-jobs/<label>.{out,err}.log`. Diagnostic: `grep -E '(StandardOutPath|StandardErrorPath)' ~/.smartclaw/launchd/*.plist | sort -u` — all should resolve to a single base path.
- **Bash script PATH bootstrap vs PATH-override in test harness (real-ssh "Could not resolve hostname host" noise is INERT)** — Scripts that begin with `export PATH="$HOME/bin:/opt/homebrew/bin:..."` (to defend against launchd's minimal env, per `ao-progress-reporter.sh` lines 28-33) silently clobber the test-passed `PATH="$STUB_BIN:/usr/bin:/bin"` whenever the script is sourced or run from a test harness. The real `ssh` binary then runs against the stub hostnames (`stub-linux`, `host`, etc.) and emits `ssh: Could not resolve hostname host: nodename nor servname provided, or not known` on stderr. **This stderr noise is INERT** — the test still passes (the script returned the correct JSON via the stubbed `ssh`), and the noise is just bash redirecting `ssh: ...` to stderr before the script's piped subshell exits. **Do not read this as a test failure or as evidence the script is calling real `ssh`.** Diagnostic: run the same test in a fresh shell with `bash -x` and search the stderr for `REAL_SSH_CALLED` markers (use a sentinel echo inside a non-stub control). If the only stderr output is `Could not resolve hostname <stub-name>` and the test summary still ends with `PASS=N FAIL=0`, the harness is working and the noise is a known artifact. Mitigation: do **not** try to suppress the PATH-export — it's there for a launchd reason. Instead, accept the stderr noise as part of the expected output of any `bash -x`-trace test on a script that contains a PATH bootstrap. Reference case: PR #828 (the second clean replay of the same fix), test log saved at `references/2026-08-18-clean-replay-of-merged-stuck-pr-817.md`.
- **The clean-replay pattern applies to never-merged, gate-stuck cron-fix PRs the same way it applies to polluted-PR rebase unlocks** — A "fix has been authored, full local test coverage, but reviewer rate-limits / merge gates have prevented landing for weeks" PR is NOT an unfinished task; it is a PR whose *merge state* is the bug, and whose *fix body* is already correct. The right action is to `cherry-pick -x <original-fix-sha>` onto a fresh `origin/main` worktree, verify local tests still pass, push as a new branch, open a new PR via REST (more reliable than GraphQL when reviewer rate-limit pressure is the originating cause), and leave the original PR open. Do NOT close the original PR or force-push onto its head — the author of the original PR is usually a prior agent, not the current operator, and that violates `never-push-onto-someone-elses-pr-head`. Worked example: PR #817 (older, never-merged, gate-stuck on the same `jleechanorg/jleechanbrain` rate-limit pattern that bricked PR #814) → PR #828 (clean replay onto current `origin/main`, parent `eb1bc2a4bc`). See `references/clean-replay-pattern-stuck-pr-2026-08-13.md` (the 2026-08-13 reference, PR #814 → #816) AND the 2026-08-18 update `references/2026-08-18-clean-replay-of-merged-stuck-pr-817.md` — same pattern, different generation.
- **Cron-supplied `thread_ts` can be stale even when freshly authored** — Slack's `chat.postMessage` does NOT validate `thread_ts` against real messages; it silently falls back to the nearest active thread. Always `conversations.history(limit=5) | grep <thread_ts>` as the first action of any followup cron that targets a specific thread. If the ts is not found, post with a "thread_ts was stale" preamble in the body so the user can correlate cron intent to actual landing. See section 2a above for the full recipe + the 2026-08-13 bug-ref.
- **Posting a thread reply does NOT suppress the dropped-thread cron** — the `dropped-thread-followup.sh` script does NOT look at Slack-author identity, message content, or recent replies when deciding whether to re-nudge. Its only suppression mechanism is the internal `~/.smartclaw/logs/dropped-thread-state.json` file. Verified 2026-08-17 on `C0AH3RY3DK6/1786914648.772089` (3 replies under 2 different Slack author identities across the same session, cron re-fired every time). The script's `mark_gave_up` is the only durable way to silence a thread you're sure is closed; see the `dropped-messages` skill's "Closing a thread you've already handled" recipe for the exact `jq` invocation. Posting in-thread + hoping the cron notices is the bug.
- **One-tick crons are safer for thread-targeted followups** — recurring crons (`hermes cron create --every 20m`) can outlive the parent message they target; one-tick crons (`--at 20m --delete-after-run --repeat 1`) are auto-cleaned after firing. Default to one-tick for any followup that posts to a specific thread (per SOUL.md `## COMMIT: one-time-status-cron-after-every-task`).
- **Mac AO daemon is NOT expected to run; /linux is primary** (operator policy, 2026-08-18). If you find yourself adding a `🚨 Mac AO daemon is DOWN` line to a cross-machine reporter, STOP — that line is the bug. The Mac box is not a primary AO host; the operator explicitly said `We shouldn't expect mac AO daemon to be up. We use /linux primarily for AO`. The reporter should still probe `mac_daemon_up` (curl `/healthz` or runfile-pid `kill -0`) so the header line carries `mac_daemon=up|DOWN` for situational awareness, but DO NOT emit a warning body when `mac_daemon_up == false`. The header is enough. This applies to ANY cron that touches a multi-host setup where one host is the designated primary and the others are explicitly off: probe for diagnostics, never surface as an actionable signal. The Mac-down case study is PR #828 / commit `cdcebb0448818a96cee1d487cc89698048946a55` on jleechanorg/jleechanbrain — before, the would-be warning was a noise source hiding the real Linux signal; after, it's silent and the Linux gate is the only thing the operator sees. Transcript: `references/2026-08-18-mac-ao-silenced-by-operator-direction.md`.

## Cross-references

- `~/.smartclaw/skills/finish-the-job/SKILL.md` — end-state declaration; verify with raw tool output
- `~/.smartclaw/skills/babysit-stale-watchdog/SKILL.md` — when crons reference PRs that have merged
- `~/.smartclaw/skills/cron-jobs-and-messaging-credentials/SKILL.md` — credential rotation
- `~/.smartclaw/skills/dropped-messages/SKILL.md` — single-message drop recovery
- `references/2026-08-13-ao-progress-reporter-still-not-fixed.md` — diagnostic transcript for the cross-machine PR #814 stuck case
- `references/clean-replay-pattern-stuck-pr-2026-08-13.md` — clean-replay recipe + worked example (PR #814 → #816) for the "unprotected main + reviewer-rate-limited + cherry-pickable single fix" configuration
- `references/2026-08-13-aopr-true-stuck-vs-false-stale.md` — diagnostic + fix recipe for the recurring-warning loop (PR #817): the daemon-alive signal is `/healthz` (or `kill -0 <pid>`), NOT db mtime. Includes the canonical probe pattern and the regression test that guards the false-positive case.
- `references/2026-08-18-clean-replay-of-merged-stuck-pr-817.md` — **second-generation clean replay (PR #817 → PR #828)**: the original fix-author ran a complete commit with full local test coverage, but PR #817 was never merged (same reviewer-rate-limit gate pattern that bricked PR #814 → #816). Worked example of how to diagnose this state ("the fix is already on disk, but not on `origin/main`") and apply the clean-replay recipe to a never-merged cron-fix PR whose merge state is the bug. Includes the new `bash PATH bootstrap vs PATH-override` pitfall that produces the inert `Could not resolve hostname host` stderr noise in test traces.
- `references/2026-08-17-partial-run-nonzero-exit-set-e-abort.md` — **worked example for Section 1a**: `last exit code = 1` misdiagnosed as "cosmetic broken pipe" while the cron had been aborting mid-run for 6 days, starving 1 of 5 priority channels. Covers the completion-sentinel diagnostic, blast-radius measurement, the ERR-trap localization recipe, the `set -e` + bare-`return 1` bug class, and a regression test that asserts the class rather than the line.
- `references/bash-login-shell-slack-curl-recipe.md` — **bash `env -i ... bash -lic ...` pattern for sourcing `SLACK_USER_TOKEN` from `terminal`** when you need to curl Slack REST API without launchd context (e.g., ad-hoc diagnostics on cited thread_ts values where the MCP tool returns `thread_not_found`). Verified 2026-08-18 during a 7-thread dropped-thread cron-loop diagnosis. Companion to Section 6 — Section 6 is the launchd-side recipe, this is the terminal-side recipe.
- `references/2026-08-18-mac-ao-silenced-by-operator-direction.md` — **operator-policy exception to Section 4a**. Operator direction (`We shouldn't expect mac AO daemon to be up. We use /linux primarily for AO`) on 2026-08-18 turned the previously-shipped "Mac-DOWN warning" into silent state in commit `cdcebb0448818a96cee1d487cc89698048946a55` on PR #828. Covers the probe-but-don't-surface pattern (header still shows `mac_daemon=up|DOWN`, no warning body), the contract-test update (Test 6/7 now assert empty/no-Mac-line when `mac_daemon_up=false`), and the "policy exception captured as pitfall not memory" rule.
- `references/2026-08-21-ao-cli-subcommand-confusion-blank-report.md` — **worked example for Section 3b**. `scripts/ao-progress-reporter.sh` called `ao status --json` (daemon-status object) instead of `ao session ls --json` for 4+ weeks; the daily AO Progress Report posted only an empty thread header. `jq 'length'` on the daemon-status object returned 8 (key count), and the session-iteration loop yielded zero items, so suppression fired every tick. Covers the "key count vs session count" trap, the field-rename trap (post-#828 schema dropped `.branch`/`.prUrl`/`.prNumber`), the fix shape (`ao session ls --json` + `.data` unwrap + `.id // .name`), the regression test that fakes both `ao` subcommands, and the 4-week operator complaint chain that never got the root cause addressed.