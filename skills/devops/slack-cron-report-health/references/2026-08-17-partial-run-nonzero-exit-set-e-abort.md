# Partial run: `last exit code = 1` was a 6-day outage, not cosmetic noise

**Date:** 2026-08-17
**Service:** `ai.smartclaw.schedule.dropped-thread-followup` (`~/.smartclaw/scripts/dropped-thread-followup.sh`, 1,882 lines)
**Slack thread:** `${SLACK_CHANNEL_ID}/p1786948684686239`
**Fix:** jleechanorg/jleechanbrain#827
**Regression window:** 2026-08-11 → 2026-08-17 (6 days)

This is the canonical worked example for Section 1a of the parent skill. It documents both the bug and the *misdiagnosis*, because the misdiagnosis is the more repeatable failure.

---

## The misdiagnosis (what to avoid)

An earlier turn in the same Slack thread investigated the same service and reported:

> 🟡 **Known caveat — `last exit code = 1`:**
> - Stderr has 19 instances of `line 462: echo: write error: Broken pipe`
> - That's from `echo … | head` style piping in `dropped-thread-followup.sh` when `head` exits early — **cosmetic, doesn't break the nudge**; log shows `NUDGED` rows landing correctly
> - Not blocking, but worth a separate bead if the user wants it quiet

Every factual observation in that paragraph is true. The conclusion is wrong. The service had been aborting mid-run on **every tick for 6 days**.

### Why the wrong conclusion was so easy to reach

The evidence genuinely looked healthy, because all of it came from the part of the script that ran *before* the abort:

| Observation | Real? | Why it misleads |
|---|---|---|
| `NUDGED: ${SLACK_CHANNEL_ID} 1786948684.686239` in today's log | Yes | The nudge happens in an early loop iteration, before the abort point |
| Fresh log lines at the current timestamp | Yes | The script starts fine every tick; it just never finishes |
| `state = spawn scheduled`, plist registered | Yes | launchd health says nothing about in-script control flow |
| 19 broken-pipe stderr lines | Yes | Real, and completely inert — see disproof below |
| Thread actually received a nudge | Yes | Confirms one work item, says nothing about the rest |

**The generalizable lesson:** confirming that the *visible* work item succeeded is not evidence the run completed. The items a loop never reaches leave no trace at all — absence of error is not presence of work.

### Three cheap disproofs of the broken-pipe theory

1. **The signal was already trapped.** Line 43 of the script: `trap '' PIPE`, with a comment explaining it exists precisely to suppress these messages under `set -euo pipefail`. A trapped SIGPIPE cannot set the exit code.
2. **The counts don't line up.** 19 stderr lines total, accumulated across 12 days — but the exit code was 1 on *every* tick. A once-every-few-days event cannot explain an every-tick failure.
3. **The timeline doesn't line up.** Broken-pipe entries appear on 2026-08-05 through 2026-08-09, while the script was still completing successfully (`Done —` lines present). Noise predating the regression is not its cause.

Any one of these takes under 30 seconds and refutes the theory.

---

## The 5-second diagnostic that should have run first

```bash
$ grep -c "Done —" ~/.smartclaw/logs/dropped-thread-followup.log
208
$ grep "Done —" ~/.smartclaw/logs/dropped-thread-followup.log | tail -1
[2026-08-11T19:38:38] Done — actioned=3 skipped=23      # ← 6 days before "today"

$ tail -3 ~/.smartclaw/logs/dropped-thread-followup.log
[2026-08-17T18:08:55] Checking channel C0AJ3SD5C79...
[2026-08-17T18:08:56] Checking channel C0ALSKLU9KM...
[2026-08-17T18:08:58]   OK (no user asks): C0ALSKLU9KM 1786864602.436029   # ← log just stops
```

208 historical completions, then nothing after 2026-08-11. The script starts, logs, posts, and dies before its final line. The regression date falls out of the log for free.

## Blast radius: the starved tail of the loop

```bash
$ grep -n 'DROP_PRIORITY_CHANNELS' scripts/dropped-thread-followup.sh
1264:DROP_PRIORITY_CHANNELS="${DROP_PRIORITY_CHANNELS:-${SLACK_CHANNEL_ID} C0AH3RY3DK6 C0AJ3SD5C79 C0ALSKLU9KM ${SLACK_CHANNEL_ID}}"

$ grep "2026-08-17" ~/.smartclaw/logs/dropped-thread-followup.log \
    | grep -o 'Checking channel C[A-Z0-9]*' | sort -u
Checking channel ${SLACK_CHANNEL_ID}
Checking channel C0AH3RY3DK6
Checking channel C0AJ3SD5C79
Checking channel C0ALSKLU9KM
# ${SLACK_CHANNEL_ID} absent — 4 of 5
```

`${SLACK_CHANNEL_ID}` is last in iteration order, so it absorbed the entire cost: **zero scans in 6 days.** Dropped threads in that channel were never nudged and never escalated. Meanwhile the first four channels looked perfectly healthy, which is exactly what sustained the "it's working" read.

**Pattern:** an abort inside a loop starves the tail. Iteration order determines the victim, and the victim is invisible precisely because it produced no log lines.

## Localizing the abort: injected ERR trap

```bash
cp scripts/dropped-thread-followup.sh /tmp/dtf_trace.sh
python3 - <<'PY'
p='/tmp/dtf_trace.sh'; s=open(p).read()
s=s.replace("set -euo pipefail",
  "set -euo pipefail\ntrap 'echo \"ERRTRAP line=$LINENO cmd=[$BASH_COMMAND] rc=$?\" >&2' ERR", 1)
open(p,'w').write(s)
PY

DRY_RUN=1 DROP_LOCK_DIR=/tmp/dtf-trace.lock bash /tmp/dtf_trace.sh \
  >/tmp/out.txt 2>/tmp/err.txt; echo "exit_code=$?"
grep ERRTRAP /tmp/err.txt
```

```
exit_code=1
ERRTRAP line=1680 cmd=[return 1] rc=1
```

One run, exact line, no source-reading. Note `DROP_LOCK_DIR=/tmp/dtf-trace.lock` — without a separate lock dir the probe races the live cron and misreports as lock contention.

## Root cause: `set -e` + a function that returns 1 as a normal signal

```bash
# scripts/dropped-thread-followup.sh:1679-1680 (before)
detect_agent_fabrication "$channel" "$thread_ts" "$_penultimate_ts" "$_last_ts" "$_last_text" "$_fabrication_tmp"
_fab_rc=$?
```

`detect_agent_fabrication` (defined at line 258) has **eight** `return 1` paths, all meaning *"this is not a fabrication"* — the overwhelmingly common case, not an error:

```
rel  3:  [[ -z "$last_agent_text" ]] && return 1
rel 13:  [[ -z "$matched" ]] && return 1
rel 15:  [[ -z "$last_human_ts" || "$last_human_ts" == "null" ]] && return 1
rel 20:  [[ -z "$penultimate_text" || "$penultimate_text" == "null" ]] && return 1
rel 22:  [[ "$penultimate_user" == "$AGENT_USER_ID" ]] && return 1
rel 23:  [[ -n "$penultimate_is_bot" && "$penultimate_is_bot" != "null" ]] && return 1
rel 32:  [[ $gap_secs -lt 0 ]] && return 1
rel 33:  [[ $gap_secs -gt $FABRICATION_WINDOW_SECS ]] && return 1
```

Under `set -euo pipefail` (line 36) a **bare** call returning nonzero terminates the script. `_fab_rc=$?` on the next line is unreachable on every one of those paths. The author's intent — capture the code and branch on it — was silently defeated by `set -e`.

### Fix

```bash
# set -e safety: detect_agent_fabrication returns 1 for the common
# "not a fabrication" case. A bare call under `set -e` aborts the whole
# script on that non-zero return, so guard with `|| _fab_rc=$?`.
_fab_rc=0
detect_agent_fabrication "$channel" "$thread_ts" "$_penultimate_ts" "$_last_ts" "$_last_text" "$_fabrication_tmp" || _fab_rc=$?
```

`_fab_rc=0` must be pre-seeded: `set -u` is active, and on the success path `|| _fab_rc=$?` never assigns.

### Grep for siblings

```bash
$ grep -n '_rc=\$?' scripts/dropped-thread-followup.sh
1680:          _fab_rc=$?
```

Only one instance here, but check every time — the same author usually repeats the idiom.

## A/B validation

Identical command, before and after, on three axes:

```
before (origin/main):
  exit_code=1
  channels: ${SLACK_CHANNEL_ID} C0AH3RY3DK6 C0AJ3SD5C79 C0ALSKLU9KM          # 4 of 5
  "Done —": absent

after (patched):
  exit_code=0
  channels: ${SLACK_CHANNEL_ID} C0AH3RY3DK6 C0AJ3SD5C79 ${SLACK_CHANNEL_ID} C0ALSKLU9KM   # 5 of 5
  "Done — actioned=7 skipped=27"
```

Live confirmation after promoting the fix to `~/.smartclaw/scripts/` and kickstarting:

```
$ launchctl kickstart -k gui/501/ai.smartclaw.schedule.dropped-thread-followup
$ launchctl print gui/501/ai.smartclaw.schedule.dropped-thread-followup | grep "last exit"
	last exit code = 0                                        # was 1

[2026-08-17T18:16:02] Checking channel ${SLACK_CHANNEL_ID}...             # first since 08-11
[2026-08-17T18:16:11] Done — actioned=1 skipped=35                # first completion since 08-11
```

## Regression test: assert the class, not the line

`tests/test_dropped_thread_followup_set_e.py` — RED on `origin/main` (3 failures), GREEN after fix.

Checks that matter beyond this one bug:

| Check | Purpose |
|---|---|
| `set_euo_pipefail_present` | If `set -e` is ever removed the test's premise is stale — fail loudly rather than pass vacuously |
| `no_unguarded_call` | Every `detect_agent_fabrication` call site must have `\|\|`, `if`, `&&`, or `$(...)` |
| `bad_bare_call_then_dollar_question_absent` | Regex for the exact broken idiom |
| `function_returns_1_on_no_match` | Proves the guard is load-bearing, not decorative |
| **`rc_capture_guarded_line_N`** | **Generalized:** flags *any* `_rc=$?` capture whose preceding line lacks `\|\|`/`if`/`&&` — catches the bug class anywhere in the file, including code not yet written |

The last row is the one that earns its keep. A test pinned to line 1680 would pass forever while the same mistake reappeared 400 lines later.

## Checklist for the next `last exit code != 0`

1. `grep "<completion sentinel>" <log> | tail -1` — is it from the current tick? If not, you have a partial run and a regression date.
2. Configured work list vs. processed set — what's missing is what's starved.
3. Inject an ERR trap, run once with a separate lock dir, read `ERRTRAP line=…`.
4. Before blaming stderr noise: is the signal trapped? do the counts match? does the timeline predate the regression?
5. Fix, then A/B on exit code + items processed + completion sentinel.
6. Write the regression test against the bug *class*.
7. Promote to `~/.smartclaw/scripts/`, sync prod, `launchctl kickstart -k`, and verify `last exit code = 0` plus a fresh completion line.
