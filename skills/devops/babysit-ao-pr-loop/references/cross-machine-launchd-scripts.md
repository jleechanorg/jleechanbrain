# Cross-Machine Launchd Scripts — Recurring Fix Patterns

> Verified 2026-08-05 (jleechanorg/jleechanbrain PR #814). The AO daily
> progress reporter ran fine on the Mac but silently lied about /linux
> for 8 days. Same class of bug recurs across every cross-machine
> launchd script. This file collects the patterns.

## The class of bug

Any launchd-managed script that monitors state across machines will
silently drift the moment one machine's view goes stale. The script
"looks healthy" (no error, no exit code, posts a report) while
reporting a partial or wrong picture. There is no alarm because the
*reporter* is the thing that's wrong.

Same shape recurs for:
- AO daily reporter (Mac + /linux reconciliation)
- Disk growth watchdog (Mac + /linux)
- Backup verifier (Mac + /home backup server)
- Cross-repo PR status reporter (jleechanorg + Agnt-F)

## Pattern: SSH reconciliation block

Every cross-machine monitoring script MUST:

1. Run the same query on EACH machine, not assume a single source of
   truth.
2. Compute a `linux_db_stale_h` (hours since mtime) — escalate when
   > threshold (default 6h).
3. Post a per-machine breakdown block in the daily thread BEFORE the
   main report. Suppress when all machines agree (no noise).

**SQLite-direct, NOT the CLI** — the daemon's `ao status --json` /
similar CLI calls hang or return empty under GH rate-limit. Direct
`sqlite3 ~/.ao/data/ao.db "<query>"` is the canonical source.

```bash
# Mac counts
sqlite3 -separator '|' "$mac_db" "
SELECT
  (SELECT COUNT(*) FROM pr WHERE pr_state='open'),
  (SELECT COUNT(*) FROM sessions WHERE kind='worker')
" 2>/dev/null

# /linux counts via SSH (heredoc-friendly to avoid quoting hell)
ssh -o ConnectTimeout=4 -o BatchMode=yes "$host" "
  db=\"\${HOME}/.ao/data/ao.db\"
  if [ -r \"\$db\" ] && command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 -separator '|' \"\$db\" \"SELECT ...\"
  fi
"
```

## jq gotchas — silent-empty-output traps (verified 2026-08-05)

Three separate jq bugs caused a 30-minute debug spiral. Document each:

### Gotcha 1: `as $var` after `if … else empty end` collapses to empty

```jq
# WRONG: produces empty silently
. as $root
| ("hdr text") as $hdr
| (if $root.stale > 0 then "STALE" else empty end) as $stale
| [$hdr, $stale] | join("\n")
```

**Why**: `as $stale` binds the *stream* of results from the if. When
the else branch emits `empty`, the stream has zero elements, $stale
is undefined, and everything downstream is empty. jq does NOT error.

**Fix**: lift the conditional into a helper `def` that returns either
a value or `empty`, then collect into an array and `select(. != null
and . != "")`:

```jq
. as $root
| (
    "hdr text"
  ) as $hdr
| [ $hdr, maybe_stale($root) ]
| map(select(. != null and . != ""))
| join("\n")

def maybe_stale($root):
  if $root.linux_db_stale_h != null and ($root.linux_db_stale_h | tonumber) > $root.stale_threshold_h
  then "STALE warning"
  else empty
  end;
```

### Gotcha 2: `.` rebinds to `$var` after `as $var`

```jq
# WRONG: `.linux_db_stale_h` looks up in the string $hdr, fails silently
. as $root
| ("hdr") as $hdr
| (if .linux_db_stale_h > 0 then "STALE" else empty end) as $stale
```

**Why**: after `as $hdr`, the input context `.` becomes the string
$hdr, not the original object. `.linux_db_stale_h` tries to index a
string, returns empty. jq does NOT error.

**Fix**: ALWAYS anchor the input first: `. as $root | … ($root.field) …`

### Gotcha 3: `def safe_num(v)` uses `.` instead of `v`

```jq
# WRONG: `. | tostring` converts the WHOLE input, not `v`
def safe_num(v): if v == null then "?" else (. | tostring) end;
safe_num(.mac.open_prs)  # returns the entire JSON object as a string
```

**Why**: jq function bodies have `.` bound to the *input context* of
the function call, NOT to the function's argument `v`. To tostring the
argument, use `(v | tostring)`.

**Fix**: use the argument name explicitly: `(v | tostring)`.

## Test-stub gotcha: `HOME=$TMPDIR` overrides script PATH bootstrap

When testing a launchd script by sourcing it with `IS_SOURCED=1`, the
script's PATH-bootstrap block (which prepends `~/.nvm/.../bin`,
`/opt/homebrew/bin`, etc.) shoves any stub `ssh` binary off PATH and
calls the real `ssh` with the stub's hostname, which fails.

**Fix**: tests MUST export `HOME="$TMPDIR"` so the bootstrap can't
find any of those directories. PATH-prepend the stub bin manually:

```bash
HOME="$TMPDIR" \
  PATH="$STUB_BIN:/usr/bin:/bin" \
  IS_SOURCED=1 \
  bash -c "source '$SCRIPT'; fetch_cross_machine_ao_state"
```

## Token sourcing in non-interactive bash

The SLACK_BOT_TOKEN / GITHUB_TOKEN variables are NOT in the env
when bash is run non-interactively (`bash -c "..."`). They live in
`~/.bashrc` for interactive shells only. To source them in scripts:

```bash
env = subprocess.run(['bash','-c','source ~/.smartclaw/scripts/launchd-env-wrapper.sh 2>/dev/null; env'], ...)
# Then parse the output for HERMES_* / GITHUB_* / SLACK_* vars
```

Or extract just the tokens:

```bash
bash ~/.smartclaw/scripts/launchd-env-wrapper.sh env 2>/dev/null \
  | grep -E '^(HERMES_|GITHUB_|SLACK_)' > /tmp/env.sh
```

## Recipe: durable fix protocol for cross-machine cron

1. **Diagnose both machines** — never assume the local machine is the
   canonical view. Run `sqlite3 ~/.ao/data/ao.db …` AND
   `ssh jeff-ubuntu sqlite3 ~/.ao/data/ao.db …`. Diff the counts.
2. **Fix the script, not the cron** — never just edit the cron entry;
   edit the script that the cron runs, then redeploy.
3. **Add cross-machine reconciliation block** — separate Slack
   message BEFORE the main report. Suppress when both machines
   agree (no noise).
4. **Add a `linux_db_stale_h` field** — escalate when mtime > 6h.
5. **Test against real data via the wrapper** —
   `bash ~/.smartclaw/scripts/launchd-env-wrapper.sh bash` to inherit
   the right tokens, then run the script with `DRY_RUN=1`.
6. **Ship as a PR** to the repo where the script lives (NOT the
   hermes repo — that's just for hermes-internal cron).
7. **Verify** — post one tick, confirm the cross-machine block
   surfaces.

## References

- jleechanbrain PR #814 (2026-08-05) — first cross-machine reconciliation
  pass on `ao-progress-reporter.sh`. Commit `7dd006a102`. Tests:
  `tests/test_ao_progress_reporter_cross_machine.sh` (16/16 PASS).
- jleechanbrain PR #696 (2026-06-27) — same class of bug (silent-empty
  output from PATH bootstrap). Different mechanism, same end state.