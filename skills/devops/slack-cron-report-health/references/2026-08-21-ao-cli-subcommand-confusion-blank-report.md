# 2026-08-21 — `ao-progress-reporter.sh` daily report blank for 4 weeks (CLI subcommand confusion)

## Symptom

Operator complaint chain in Slack channel `C0ALSKLU9KM` (the daily AO Progress Report channel):

- 2026-08-21 07:29 UTC — "look at this fucking report its blank" (ts 1787297369.301279)
- 2026-08-13 00:28 UTC — "This progress report still not fixed" (ts 1786580895.173149)
- 2026-08-08 08:17 UTC — "Still not fixed" (ts 1786177055.805219)
- 2026-08-05 (first complaint after PR #816 was supposed to fix it)

The thread parent message text is just the title (`AO Progress Report 2026-08-XX new daily thread`) at 07:08 UTC daily. No body content in any of those threads.

## Root cause (NOT what prior sessions diagnosed)

Three prior sessions opened PRs to fix this report:

- PR #816 (2026-08-13): fixed Linux db mtime as the stuck-write signal → replaced with `/healthz` probe. Did NOT address why the body was blank.
- PR #817 (2026-08-13): cross-machine `/linux` reconciliation. Never merged (reviewer rate-limited).
- PR #828 (2026-08-18): clean replay of #817 onto current `origin/main`. Did NOT address why the body was blank.

The recurring complaint was "the report is blank" — and every fix hit a *different* layer (cross-machine reconciliation, suppression policy, daemon-down surface). None touched the actual reason the body was empty: the script was calling the **wrong `ao` subcommand**.

## What the script actually called

```bash
# ~/.smartclaw/scripts/ao-progress-reporter.sh, line 294 (pre-fix)
if ! all_sessions="$(cd "$AO_DIR" && "$AO_BIN" status --json 2>/dev/null)"; then
  log "ERROR: '$AO_BIN status --json' failed (rc=$?) — output was: ${all_sessions:0:500}"
  echo "[]"
  return
fi
```

`ao status --json` returns the **daemon-status object**:
```json
{"state":"ready","pid":48160,"port":3001,"startedAt":"...","uptime":"9s",
 "runFile":"${HOME}/.ao/running.json","dataDir":"${HOME}/.ao/data",
 "health":"ok","ready":"ready"}
```

9 keys. `jq 'length'` returns 9. The script logged:

```
[2026-08-20T22:02:22] Found 9 AO sessions
```

This is **plausible-looking output for "9 sessions"** — but it's the key count of the daemon-status object. There were zero actual sessions iterated.

The WARN line `WARN: ao stdout does not start with '[' — first 200 chars: {` DID fire every tick (script line 303) but the suppression branch at the bottom of the script fired correctly because the session iteration loop (`jq '.[]'` on an object = empty stream) yielded no records to compare against the state file.

## The "Found N sessions" trap

The script's `session_count` variable uses `jq 'length'` (line 661). On an array `[]` this returns `0`. On an object `{...}` it returns the **key count**. The pre-fix output was "Found 9 AO sessions" — a number that looked healthy enough that no prior session caught it.

Three things had to be true at once for the bug to hide this long:

1. The WARN line fired every tick (good signal — but the suppression branch was *correct* given the empty iteration).
2. `Found N sessions` was non-zero (key count, not session count).
3. The per-tick suppression branch fired correctly (no body — because no iterations).

So the cron kept looking "healthy" to a casual reader while doing nothing useful.

## Diagnostic — confirm by inspecting each `ao` subcommand independently

```bash
# Each subcommand returns a DIFFERENT thing; verify what you actually have
ao status --json | jq 'keys'                 # → ["dataDir","health","pid","port","ready","runFile","startedAt","state","uptime"]
ao session ls --json | jq '.data | length'  # → 1 (real session count)
ao session ls --json | jq '.data[0] | keys' # → ["id","projectId","kind","status","harness",...]

# If status returns 6+ keys AND the script iterates with '.[]', you have CLI subcommand confusion (Section 3b).
# If session ls returns a real array AND the script ignores it, you have CLI subcommand confusion.
```

The fix is to call the right subcommand. `ao status` is for daemon health; `ao session ls` is for session records.

## Fix shape (PR #834, commit `05e26ae048`)

```bash
# OLD (wrong subcommand — daemon status, not sessions):
if ! all_sessions="$(cd "$AO_DIR" && "$AO_BIN" status --json 2>/dev/null)"; then
  log "ERROR: '$AO_BIN status --json' failed ..."
  echo "[]"
  return
fi

# NEW (correct subcommand with envelope unwrap; legacy fallback for old CLI):
if ! raw="$(cd "$AO_DIR" && "$AO_BIN" session ls --json 2>/dev/null)"; then
  log "ERROR: '$AO_BIN session ls --json' failed (rc=$?) — falling back to legacy 'ao status --json'"
  if ! raw="$(cd "$AO_DIR" && "$AO_BIN" status --json 2>/dev/null)"; then
    log "ERROR: '$AO_BIN status --json' failed too (rc=$?) — output was: ${raw:0:500}"
    echo "[]"
    return
  fi
  log "WARN: using legacy 'ao status --json' (daemon-status object) — sessions likely missing. Upgrade ao CLI."
fi
# Unwrap {"data":[...]} envelope if present; pass through if already an array.
if [[ "$raw" == "{"* ]]; then
  all_sessions="$(echo "$raw" | jq -c '.data // .sessions // []' 2>/dev/null)" || all_sessions="[]"
else
  all_sessions="$raw"
fi
```

## Field rename trap (post-#828 AO rewrite)

The new `ao session ls --json` schema dropped several fields that older AO versions exposed:

| Old field      | New field / status |
|----------------|--------------------|
| `.name`        | `.id` (no `.name` alias) |
| `.branch`      | NOT exposed on session — must derive from PR |
| `.prUrl`       | NOT exposed on session — lives in AO's review subsystem |
| `.prNumber`    | NOT exposed on session — same as above |

If a script extracts `.name // empty` and gets empty, every session is silently skipped by the `[[ -z "$session_name" ]] && continue` guard (line 700 in the pre-fix script). The suppression fires again with a different symptom — "Found N sessions but no report_blocks emitted".

Mitigation:

```bash
# Map .id → session_name (was .name)
session_name="$(echo "$session_json" | jq -r '.id // .name // empty' 2>/dev/null)"

# Branch/PR/URL no longer on the session record — default to empty.
# The PR-detail block is gated on '[[ -n "$repo" && -n "$pr_number" ]]'
# so it is silently skipped when the new schema doesn't carry the linkage.
branch=""
pr_url=""
pr_number=""
```

## Regression test (5 assertions, all pass)

`tests/test_ao_progress_reporter_session_field.sh` fakes the `ao` CLI by writing a shim that emits:

- `ao session ls --json` → `{"data":[{"id":"worldarchitect-207",...}], "meta":{...}}`
- `ao status --json`     → `{"state":"ready", ...}` (the bug-shape)

Then sources the script's helpers (`IS_SOURCED=1`) and asserts:

1. `fetch_ao_sessions` returns a JSON array (not the daemon-status object)
2. `.data` envelope is unwrapped to a flat array (length 1)
3. `.id` is extracted (not empty, not falling through to suppression)
4. daemon-status object shape is NOT leaked into the session list
5. helper function `fetch_ao_sessions` is defined

All 5 PASS. The test fails immediately if a future schema drift breaks any of the four contract points.

## Verification (live)

After the fix landed on branch `fix/ao-progress-reporter-blank-body` and the Mac AO daemon was restarted (it had been "stale" for 43+ hours, PID 31655 from 2026-08-19 10:32 UTC), running the script manually produced:

```
[2026-08-21T00:34:24] Found 1 AO sessions
[2026-08-21T00:34:25] AO progress reporter done — healthy:0 stalled:1 no_pr:0
```

…and posted to the 2026-08-21 thread (ts 1787296113.930609) as message ts 1787297665.500999:

```
AO Progress Report 00:34 PDT 1 sessions :warning: 1 stalled
 worldarchitect-207 worldarchitect :red_circle: CI failed :fire:
```

That `worldarchitect-207 (worldarchitect) :red_circle: CI failed :fire:` line — the first body content posted to any daily AO Progress Report thread since PR #828 — is the proof the fix landed.

## End-state declaration

- **PR opened**: jleechanorg/jleechanbrain#834 (clean from origin/main, parent commit 03b464e2b0)
- **CI**: not yet evaluated by Green Gate (PR opened 2026-08-21 ~07:34 UTC)
- **Cron actually uses new code**: yes — `~/.smartclaw/scripts/ao-progress-reporter.sh` was edited in-place on the dirty main checkout, then a clean worktree replayed onto `origin/main` for the PR. The cron reads `~/.smartclaw/scripts/`, not the repo, so the fix only takes effect after PR merge + the standard durable-promotion step (`git show origin/main:<script> > ~/.smartclaw/scripts/<script>` + chmod).
- **Babysit cron**: `76ef91552e95` (PR #834, every 10 min, 20 repeats) — will self-terminate when PR is merged/closed.

## Lessons for future sessions (encoded as Section 3b pitfall in SKILL.md)

1. **`Found N sessions` is NOT evidence of session count** when the parser doesn't validate the shape. `jq 'length'` on an object returns key count.
2. **A WARN line firing every tick is a real bug, not a pre-existing condition** — but only if you can show what the script is supposed to do. "WARN fires, suppression fires, body is empty" is consistent with multiple bugs.
3. **Verify the subcommand name, not just the output** — `ao status` and `ao session ls` are different commands with different semantics. Calling the wrong one looks plausible because both return valid JSON.
4. **The bug class hides for weeks when every prior fix hits a different layer** — same operator complaint, different diagnosis each time. When a recurring complaint has a known chain of "fix attempts" that didn't address the root cause, walk through the script's actual data flow top-down and verify each subcommand independently. Don't accept "we already fixed this" as a starting assumption.
5. **Schema renames in daemons are silent** — `.name` → `.id`, dropped fields, new envelope shapes. Always include a field-by-field regression test that fakes the daemon's output rather than relying on integration testing against the real daemon.
