# 2026-08-13 — ao-progress-reporter: replacing mtime with `/healthz` (PR #817)

Companion to `2026-08-13-ao-progress-reporter-still-not-fixed.md` (PR #814 → #816 clean-replay). PR #816 fixed the *omission* (reporter never queried /linux) but introduced a new bug — it used `db-file mtime` as the "stuck write" signal, which is the wrong signal. PR #817 fixed that.

## The recurring-warning loop (the user-visible symptom)

Thread C0ALSKLU9KM parent ts `1786604836.495059` (2026-08-13 daily), the warning repeated **15+ times in 24 hours** with monotonically increasing stale hours:

```
⚠️ Linux AO db is 367h stale (threshold 6h) — daily reports may be missing /linux activity.
⚠️ Linux AO db is 368h stale (threshold 6h) — daily reports may be missing /linux activity.
⚠️ Linux AO db is 369h stale ... [15+ more]
```

This is itself the bug signature. A reporter that produces the same warning text 15+ times in a day is in a false-positive loop, not informing the user.

## What `/linux` actually was at the time

Verified directly via SSH (cmd transcript from this session):

```
$ ssh jeff-ubuntu "ls -la ~/.ao/data/ao.db"
-rw-r--r-- 1 jleechan jleechan 385024 Jul 29 00:26 /home/jleechan/.ao/data/ao.db

$ ssh jeff-ubuntu "curl -fsS -m 2 http://127.0.0.1:3001/healthz"
{"executablePath":"/home/jleechan/.local/bin/ao-go","pid":3312,
 "service":"agent-orchestrator-daemon","status":"ok",
 "workingDirectory":"/home/jleechan"}

$ ssh jeff-ubuntu "sqlite3 ~/.ao/data/ao.db 'SELECT COUNT(*) FROM sessions WHERE kind=\"worker\"'"
31
```

- The db mtime is from 2026-07-29 (16 days ago) — that's what triggered the warning.
- The `ao-go` daemon is **alive** (`status:ok`, pid 3312, running 9+ days).
- All 31 worker sessions are terminated (`is_terminated=1`) — the daemon has been idle because there's no work to do.

**Diagnosis:** The 367h-stale mtime is a false positive. A healthy-but-idle daemon legitimately doesn't write the db for hours/days, because nothing is happening. The reporter was using mtime as a stuck-write signal when it should have been using a daemon-alive signal.

## What the **Mac** actually was at the time (the hidden real bug)

The reporter had been hiding the actual broken thing for a week:

```
$ ao status --json
{"state":"stale","pid":41591,"port":3001,"startedAt":"2026-08-04T04:55:31.042543Z",
 "uptime":"240h32m27s","runFile":"${HOME}/.ao/running.json",
 "dataDir":"${HOME}/.ao/data","error":"run-file points to a dead process"}

$ cat ${HOME}/.ao/running.json
{"pid":41591,"port":3001,"startedAt":"2026-08-04T04:55:31.042543Z"}

$ kill -0 41591
bash: kill: (41591) - No such process

$ lsof -nP -iTCP:3001 -sTCP:LISTEN
(empty — nothing listening on Mac port 3001)

$ curl -s -m 2 http://127.0.0.1:3001/healthz
(empty — connection refused)
```

- Mac's `ao-go` daemon has been dead for **240 hours** (since 2026-08-04).
- `~/.ao/running.json` still points to dead pid 41591.
- The SQLite db is still readable (the OS reopens the file on read independently of the daemon process).
- The reporter was reading the SQLite db and getting **correct historical numbers** but with **no daemon to spawn new work**.

So the Mac has been unable to spawn workers for 10 days, and the only warning the user ever saw was the false-positive Linux one. The right warning (Mac daemon DOWN) was hidden because the reporter was watching the wrong signal.

## The fix (PR #817, commit `a84bd5fd20`)

`fetch_cross_machine_ao_state()` now does three things instead of one:

1. **Probe the daemon** with `curl /healthz` on BOTH machines (local + SSH).
2. **Probe data freshness** with SQLite ground-truth (`MAX(activity_last_at)`, open PRs, etc.).
3. **Combine** them: stale-warning fires ONLY when daemon is alive AND there is real work that should have written the db (active workers OR open PRs) AND db mtime > threshold. That's the actual "stuck write" scenario.

The output JSON gained two new fields:

```json
{"mac":{...},"mac_daemon_up":false,
 "linux":{...},"linux_daemon_up":true,
 "linux_db_stale_h":0,"stale_threshold_h":6}
```

And the format function gained two new conditional warnings:

- `🚨 Mac AO daemon is DOWN` — when `mac_daemon_up=false`. This is the actually-broken thing the user needs to fix.
- `⚠️ Linux AO db is Xh stale ... likely a stuck write` — only when `linux_daemon_up=true` AND there's real work that should have written the db. This is the legitimate failure mode.

A healthy-but-idle daemon (`linux_daemon_up=true`, no workers, no open PRs, db old) is now silent — normal operation, not a bug.

## Pattern that PR #817 shipped (canonical "is the daemon alive" probe)

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

For daemons with no HTTP listener but a pidfile / runfile, fall back to `kill -0 "$(jq -r .pid runfile)"` — that catches the exact failure mode that hid here: "run-file points to a dead process."

## Tests that prove the new contract

`tests/test_ao_progress_reporter_cross_machine.sh` (7 scenarios, 24/24 PASS):

| # | Scenario | Asserts |
|---|---|---|
| 2 | Healthy linux (busy, db fresh) | Both daemon probes return true, no warning fires |
| 3 | True stuck write (linux daemon up + 1 worker 24h + 2 open PRs + db 24h stale) | Stale warning fires with "stuck write" hint |
| 4 | **Healthy linux, idle (0 workers 24h, db 180h stale)** — the false-positive guard | **NO stale warning fires** (this is the regression case from PR #816) |
| 5 | /linux unreachable (SSH down) | Fallback note fires |
| 6 | Mac daemon DOWN (`mac_daemon_up:false`) | 🚨 Mac AO daemon is DOWN warning fires |
| 7 | End-to-end real-shape with full healthy+stuck inputs | Format renders correctly with new fields |

Test 4 is the regression guard for the PR #816 bug. Without it, the false-positive loop would be back the next time `/linux` is idle for a few hours.

## Live proof right after the fix shipped

```
🖥️ *Cross-machine AO state* mac: open=32 green=0 workers(24h)=0 / linux: open=0 green=0 workers(24h)=0 | mac_daemon=DOWN linux_daemon=up
🚨 *Mac AO daemon is DOWN* (no /healthz response on 127.0.0.1:3001) — workers cannot be spawned. Investigate: `ao status` (likely "run-file points to a dead process"); restart with `ao start`.
```

Now shows the **actual broken thing** (Mac daemon DOWN) and **silences the false positive** (no "Linux db is Xh stale" line). Single cron tick is enough to see what the user needs to do.

## Durable-promotion step (the part that's easy to miss)

PR #817 is on `origin/main` after merge — but the cron reads from `~/.smartclaw/scripts/ao-progress-reporter.sh`, NOT from the repo. After merging, the live script MUST be updated:

```bash
# from the merged branch (after fetch + ff-merge to local main):
git show origin/main:scripts/ao-progress-reporter.sh > ~/.smartclaw/scripts/ao-progress-reporter.sh
chmod 755 ~/.smartclaw/scripts/ao-progress-reporter.sh
# then verify the live copy matches:
diff ~/.smartclaw/scripts/ao-progress-reporter.sh ~/.worktrees/<branch>/scripts/ao-progress-reporter.sh
```

PR #816 was merged but the live copy was stale for a day (the durable-promotion step was missed), which is why the user kept seeing false warnings even after the merge landed. PR #817 fixed it: I copied the merged script to `~/.smartclaw/scripts/ao-progress-reporter.sh` immediately after merge, with backup `.pre-817.bak`. See Pitfall "Merged ≠ deployed" in `SKILL.md`.

## Recommended user action after this fix

`ao start` — brings the Mac daemon back online so workers can spawn again. The reporter will then surface real session activity instead of the empty 0/0 it shows now.