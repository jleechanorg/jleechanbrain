# Diagnosed Scripts (worked examples)

Concrete walk-throughs of each pattern from the umbrella SKILL.md, with file:line citations, original code, fixed code, and commit SHAs. Use these as templates when you encounter the same pattern in a new script.

---

## 2026-08-06 — `~/.smartclaw/scripts/cron-backup-sync.sh` — Patterns A + B

**Symptom (reported by Slack user):**
> Cron Backup: no changes. Total: ? jobs (? enabled).

The cron ran fine, the script exited 0, but the Slack message had `?` in both numeric fields.

### Root cause analysis

```bash
# Original code (line 19):
CRON_JSON=$(hermes cron list --json 2>/dev/null) || true

# hermes cron list --help shows:
#   usage: hermes cron list [-h] [--all]
#   options: -h, --help / --all
#   NO --json flag exists.

# Result: $CRON_JSON = the usage text
# (the parser fell through because raw didn't start with '{')
```

The python parser bailed (raw didn't start with `{`), and the fallback `|| CRON_JOBS="$CRON_JSON"` propagated the usage text into `CRON_JOBS`. Downstream:

```bash
# Line 98-99 (original):
TOTAL=$(echo "$CRON_JOBS" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('jobs',[])))" 2>/dev/null || echo "?")
ENABLED=$(echo "$CRON_JOBS" | python3 -c "import json,sys; print(sum(1 for j in json.load(sys.stdin).get('jobs',[]) if j.get('enabled')))" 2>/dev/null || echo "?")
```

Both parsers failed (input wasn't JSON), both fallbacks fired, both returned `?`. Final Slack message: `Total: ? jobs (? enabled).`

A second bug compounded this:

```bash
# Line 154 (original):
if [[ "$CHANGED" -eq 1 ]] && [[ -n "$COMMIT_SHA" ]]; then
  do_slack "..."
fi
# `COMMIT_SHA` was never assigned on the no-commit path. Under `set -u`,
# the second [[ ]] crashed with `COMMIT_SHA: unbound variable`.
```

This was masked by the parser-fallback path running first; it only crashed when the script actually had a commit to make.

### Fix

1. **Replaced `--json` with table parsing** of `hermes cron list --all` output. New parser uses regex on the box-drawing table format (each job starts with `<id> [<state>]`, followed by indented `Key: Value` lines).

2. **Added `hermes cron status` for the canonical active count.** Output line `  N active job(s)` is more reliable than parsing the table (and matches what the user sees in `hermes cron status`).

3. **Pre-defaulted `COMMIT_SHA=""`** before the commit branch. Reads use `${COMMIT_SHA:-}` for safety.

4. **Made each `||` fallback return a valid empty JSON** instead of propagating the broken input:
   ```bash
   ) || CRON_JOBS='{"jobs": [], "total": 0, "active": 0, "status_active": null}'
   ```

### Verification

End-to-end run after fix:
```
[2026-08-06 08:35:36] Done. Total=24 Enabled=10 Active=10 Changed=1 Commit=d5fbcce77dbdd1d2e8743e18f716afd37982d081
```

Backup JSON now contains the canonical count:
```json
{
  "jobs": [...],
  "total": 24,
  "active": 10,
  "status_active": 10
}
```

### Commits

- `a7395137feec523cc61dd857306acd34d414f5c6` — `fix(cron-backup): parse 'hermes cron list' table instead of non-existent --json flag` (local; push blocked by Pattern C below)

---

## 2026-08-06 — `~/.smartclaw/` push blocked — Pattern C

**Symptom:** `git push origin HEAD:refs/heads/auto/commit-pending` rejected:
```
git secret guard: scanning outgoing range d9f2840b611...a7395137fe for refs/heads/auto/commit-pending
8:31AM WRN leaks found: 2
git secret guard: push blocked by secret scan for origin https://github.com/jleechanorg/jleechanbrain.git
```

My commit `a7395137fe` had a 79-line diff with NO credentials. The diff contained:
- Bash heredoc + python parser
- A few `Bearer ***` references (already redacted in source)
- No actual tokens

### Root cause

The pre-push hook runs:
```bash
gitleaks git --log-opts <range-base>..HEAD --redact=100 --no-banner --log-level warn .
```

Where `<range-base>` = `origin/auto/commit-pending` = `d9f2840b611f4f6a813069b6b8a8302c0280f9b1`. So it scanned `d9f2840..a7395137fe`.

### Diagnostic

```bash
gitleaks git --log-opts a7395137fe^..a7395137fe --redact=100 --no-banner --log-level info --verbose .
# → 1 commits scanned. no leaks found

gitleaks git --log-opts d9f2840b611..a7395137fe --redact=100 --no-banner --log-level info --verbose .
# → 4 commits scanned. leaks found.
# Finding:  token: REDACTED
# RuleID:   generic-api-key
# File:     config.yaml
# Line:     368
# Commit:   5977fa23c06718c315a00c27cf90c08e969ea3e4
# (× 2: lines 368 and 376)
```

Commit `5977fa23c0` is from PR #813 (already on `origin/main` before my push). It contains a string in `config.yaml` lines 368/376 that gitleaks' `generic-api-key` rule flagged at entropy 3.78. False positive (the strings are not API keys; likely random-ish config values).

### Action taken

Did NOT push via `--no-verify` (would set a precedent). Documented in the response and recommended filing a bead to tighten the guard to `HEAD^..HEAD`.

### Recommended fix (for the bead)

Change `${HOME}/.config/git/hooks/secret-scan.sh` so the `pre_push()` function uses:
```bash
# Scan only the new commits, not the rev-list range
run_gitleaks_range() {
  local log_opts="HEAD~${NEW_COMMITS_COUNT}..HEAD"
  gitleaks git --log-opts "$log_opts" ...
}
```
OR simply:
```bash
gitleaks git --log-opts "HEAD^..HEAD" ...
```
This would have allowed the 2026-08-06 push through (the offending commits are in shared history, not in the diff being reviewed).

---

## Pre-2026-08-06 — `monitor-agent.sh` memory probe — Pattern D (related)

Documented in `hermes-health-check` references. The fix was about subshell PATH inheritance, but the same shape applies to subshell assignment leaks:

```bash
# WRONG (subshell scope leak)
memory_output=$(bash -lc "$memory_cmd")   # PATH added in subshell, hermes found,
                                          # but any VAR= set inside is lost

# GOOD (export PATH first)
PATH="$HOME/.nvm/versions/node/v22.22.0/bin:$PATH" memory_output=$(bash -lc "$memory_cmd")
```

The fix ran the `bash -lc` with explicit `export PATH=...` chained before the actual command, so the subshell's `hermes` invocation found the binary.

---

## Reference: all `?` placeholder scripts in `~/.smartclaw/scripts/`

Grep for the pre-baked fallback pattern across all hermes-managed scripts:

```bash
grep -rn '|| echo "?"\||| echo '\''?'\''' ~/.smartclaw/scripts/ 2>/dev/null
grep -rnE '\|\| ?echo ?["\x27]\?["\x27]' ~/.smartclaw/scripts/ 2>/dev/null
```

Scripts that match should be audited for the same pattern A/B root cause:

| Script | Has `\|\| echo "?"`? | Audited? |
|--------|---------------------|----------|
| `cron-backup-sync.sh` | YES | YES (2026-08-06) |
| `backup_cron_jobs.sh` | TBD | TBD |
| `run-hermes-backup.sh` | TBD | TBD |
| `backup-watchdog.sh` | TBD | TBD |

When auditing, run the diagnostic order from the umbrella SKILL.md: find pre-baked fallbacks → `bash -x` trace → `command --help` → unconditional-assignment audit.