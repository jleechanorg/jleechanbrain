---
name: config-export-from-canonical-store
version: 1.1.0
description: |
  Snapshot daemons from their on-disk store, never CLI output.
when_to_use: |
  Whenever a script intends to "backup" or "snapshot" a Hermes subsystem's config
  for restore or drift detection — the canonical store is on disk; use it.
triggers:
  - "cron backup wrong"
  - "jobs.json mismatch"
  - "table format changed"
  - "hermes cron list --json gone"
  - "snapshot not capturing all jobs"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
context: inline
---

# config-export-from-canonical-store

The rule is one line: **snapshot a daemon by reading its on-disk state store, never by scraping CLI table output.** Everything below is the rationale, the canonical paths in Hermes, and the failure modes this rule prevents.

## Why this rule exists

Cron backup `~/.smartclaw/scripts/cron-backup-sync.sh` rewrote itself on 2026-08-10 (`cc729fe2cb`) to scrape `hermes cron list --all` after `hermes cron list --json` stopped existing. The new parser's header regex matched `[active|paused|disabled]` but omitted `[completed]`. A skipped header leaves the parser pointing at the **previous** job — so the completed job's `Name`/`Schedule`/`Deliver` fields overwrote the live job that preceded them. Result: the script committed a backup claiming 23 jobs when 36 existed, with 8 live jobs stored under another job's name and schedule, and the Slack notification reported "Total: 9 jobs (9 enabled)" — both numbers drawn from the same variable. `TOTAL` was structurally guaranteed to equal `ENABLED` because the parser only ever reached the `enabled`/`active` branch and never the real total.

The same anti-pattern is alive elsewhere: `~/.smartclaw/scripts/backup_cron_jobs.sh` still calls the removed `--json` flag and would now exit 1 on every run, and `~/.smartclaw/skills/shell-script-template-substitution/references/diagnosed-scripts.md` even documents the table-parsing fallback as a "fix" — diagnosing a symptom without naming the disease.

## The class of failure

CLI table output is a **human-facing rendering**, not an API. Three properties make it unfit as a snapshot source:

1. **It omits fields the daemon considers essential.** `hermes cron list --all` does not print `prompt`, `skills`, `workdir`, `model`, `provider`. A snapshot built from it cannot restore those jobs. Compare the canonical store: `~/.smartclaw/cron/jobs.json` includes every field the scheduler reads on tick.
2. **Its header format is not a stable contract.** State labels like `[active|paused|disabled|completed]` are the daemon's internal vocabulary exposed for human eyes. A grep that misses one bucket silently mis-attributes every field after it. (Bug-ref: 2026-08-10, 8 mis-attributed rows.)
3. **It mixes runtime state with configuration.** `Last run: <ts> ok` changes every tick; if your change-detection diff includes that line, the script reports itself as "changed" forever.

## Canonical stores in this repo

| Subsystem | Store path | Notes |
|---|---|---|
| Cron jobs | `~/.smartclaw/cron/jobs.json` | Top-level `{"jobs":[...], "updated_at":"..."}`. Source of truth per `hermes-deploy-pipeline/SKILL.md` (Stage 5.5b drift watch). |
| Cron executions | `~/.smartclaw/cron/executions.db` | SQLite, runtime-only — exclude from config backups. |
| Launchd labels | `~/Library/LaunchAgents/*.plist` | Filename IS the label; parse `Label` from each plist. |
| (other subsystems) | — | When in doubt: `find ~/.smartclaw -maxdepth 3 -name 'jobs.json' -o -name '*.db' -o -name '*.json'` near the subsystem's launchd plist, then trace which file the daemon actually opens at startup. |

## Procedure for any new export script

1. **Identify the canonical store** — the file the daemon re-reads on tick. If you cannot name it from one grep, you are about to write a screenshot, not a backup.
2. **Read it directly** in the script. `json.load(open(path))` for JSON stores, `sqlite3.connect(path)` for SQLite.
3. **Strip volatile runtime fields** before diffing for change detection. For cron: `next_run_at`, `last_run_at`, `last_status`, `last_error`, `last_delivery_error`, `fire_claim`. For other subsystems, derive the analogous list by asking "what changes when the clock moves without anything changing?" **Recurse into nested objects** — the canonical cron store nests these under `meta`, and a one-level stripper will still report clock movement as config change.
4. **Write via temp file + `mv`** so a crash mid-write cannot truncate a good snapshot. The pattern in the fixed `cron-backup-sync.sh`:

   ```bash
   printf '%s\n' "$CONTENT" > "$TARGET.tmp"
   mv "$TARGET.tmp" "$TARGET"
   ```

5. **Failure paths must exit non-zero and leave the previous snapshot intact.** Test: rename the store to a hidden path, run the script, confirm exit=1 and that the previous snapshot is byte-identical to before.
6. **Separate the export logic from the commit/push/Slack post.** Every "Cron Backup: committed" line should quote the **commit SHA** it just produced, not a precomputed total — and the totals must come from the file you actually wrote, not a parser that ran on a different artifact. The fixed script splits them so a regression in one cannot fabricate the other's report.

## Anti-patterns to reject on review

- ❌ `--json` was removed and you replaced it with `awk` + regex over the table — you have just built a new bug. Read the store.
- ❌ Your diff includes `Last run:` or `Next run:` lines — your change detector is reporting clock movement, not config change.
- ❌ Your Slack notification says "Total: X (Y enabled)" and `X == Y` every time — the variables share a fallback. Confirm against the store, not the parsed list.
- ❌ You `bash -c "..."` the export script and pipe stdout to `tee` — buffered, no progress, can't be inspected if the script hangs. Run the script and read the file it wrote.
- ❌ You grep "cron" + "completed" in the regex but the daemon emits "cancelled" or "firing" too — your state set is a moving target. Match `\w+` and validate.
- ❌ The export script does not `git diff --cached --quiet` before `git commit` — silent "no changes" commits pollute history. The fixed script guards with `! git diff --cached --quiet`.

### Additional pitfalls discovered 2026-08-10

- ❌ **Your VOLATILE stripper only iterates top-level keys.** The canonical `cron/jobs.json` nests runtime fields under `meta` (e.g. `meta.next_run`, `meta.last_run`). A one-level `{k: v for k, v in j.items() if k not in VOLATILE}` leaves those nested fields ticking, so `diff -q export.json export.json.bak` returns nonzero every tick even when no config changed. Either descend into `meta` or strip the whole `meta` block before diff. Symptom in the wild: `git status` shows `M docs/context/CRON_JOBS_BACKUP.json.bak` for weeks, even though every Slack post reports `Cron Backup: no changes`. The canonical fields-to-strip list for cron is now: top-level `next_run_at, last_run_at, last_status, last_error, last_delivery_error, fire_claim` AND nested `meta: {next_run, last_run}`.
- ❌ **Two files with the same name, different behavior.** `~/.smartclaw/cron-backup-sync.sh` and `~/.smartclaw/scripts/cron-backup-sync.sh` are NOT the same script. The active launchd plist points at `scripts/cron-backup-sync.sh`; the top-level copy is an older Jun 25 entrypoint that calls `scripts/backup_cron_jobs.sh` and uses the removed `--json` flag. If your "fix" lands in one but the launchd tick runs the other, the fix never runs. Always resolve `grep -A2 ProgramArguments ~/Library/LaunchAgents/ai.smartclaw.schedule.<name>.plist` before editing.
- ❌ **`TOTAL == ENABLED` in the Slack post is a structural signature, not coincidence.** When the parser only counts rows in one bucket (e.g. `[active]`) and then prints both `TOTAL` and `ENABLED` from that same counter, the post will always satisfy `X == Y`. If you see this pattern in any cron-backup alert — past, present, or future — treat it as a five-alarm fire: the export is undercounting, the `ENABLED` count is plausible, and `TOTAL` is wrong in a way that looks reasonable. Round-trip against `cron/jobs.json` immediately.

## Verification recipe

For any new export script, after writing the data file, run the round-trip verifier:

```bash
python3 scripts/verify_cron_backup_round_trip.py          # canonical fields
python3 scripts/verify_cron_backup_round_trip.py --strict # also VOLATILE fields
```

Exits 0 with `PASS <N> jobs round-trip (enabled=<M>)`; exits 1 with diagnostic detail on job-set drift, field drift, or `enabled` count drift. Use this *any* time the cron backup Slack post looks wrong, before you start reading script source.

For ad-hoc verification, the inline shell recipe:

```bash
# Round-trip fidelity: load the export, compare field-by-field against the live store.
python3 - <<'PY'
import json
exp = {j['id']: j for j in json.load(open('docs/context/CRON_JOBS_BACKUP.json'))['jobs']}
live = {j['id']: j for j in json.load(open('cron/jobs.json'))['jobs']}
assert set(exp) == set(live), f"missing {set(live)-set(exp)} extra {set(exp)-set(live)}"
for i in live:
    mismatches = [k for k in live[i] if k not in VOLATILE
                  and exp[i].get(k) != live[i].get(k)]
    assert not mismatches, f"{i} field drift: {mismatches}"
print("PASS", len(exp), "jobs round-trip")
PY

# Failure path: corrupt store must NOT corrupt the export.
cp cron/jobs.json cron/jobs.json.bak
echo 'not json' > cron/jobs.json
bash scripts/<export>.sh; echo "exit=$?"
diff -q docs/context/<backup>.json docs/context/<backup>.json.bak  # expect identical
mv cron/jobs.json.bak cron/jobs.json
```

## Cross-references

- The cron-store bug and fix transcript: `references/cron-backup-2026-08-10.md`
- The round-trip verifier: `scripts/verify_cron_backup_round_trip.py` — re-runnable, exits 0/1, mirrors the script's VOLATILE set.
- The fixed export script lives at `~/.smartclaw/scripts/cron-backup-sync.sh` (study it before adapting to another subsystem).
- The deploy pipeline confirms `cron/jobs.json` is the source of truth and explains the staging/prod twin pattern in `~/.smartclaw/skills/hermes-deploy-pipeline/SKILL.md` Stage 5.5b.
- The shell-script-debug skill documents the original `--json` → table-parsing diagnosis without naming the canonical store: `~/.smartclaw/skills/shell-script-template-substitution/references/diagnosed-scripts.md`. If you update that skill, point it here instead.
