# Cron backup false-green — incident transcript 2026-08-10

## Symptom

Slack channel `#ai-general` (`C0AJQ5M0A0Y`) received at 08:25 PT:

> `[Hermes AI Meeting Bot]` Cron Backup: committed. Total: 9 jobs (9 enabled).

Operator asked why only 9 jobs when the system clearly ran more.

## Reproduction

```
hermes cron list --all
```
returned **36** job header lines. States: 9 active, 4 paused, 10 disabled, 13 completed.

`docs/context/CRON_JOBS_BACKUP.json` (the file the script had just committed) contained **23** jobs and reported `enabled=9`. Eight of the saved jobs were stored under another job's name and schedule.

## Root cause

`~/.smartclaw/scripts/cron-backup-sync.sh` had been rewritten in commit `cc729fe2cb` (08:25 PT, the same minute the alert fired) to scrape `hermes cron list --all`. The previous version read `hermes cron list --json`; the `--json` flag had been removed from the CLI, so the rewrite substituted table parsing.

The new parser's header regex was:

```python
id_re = re.compile(r"^\s+([0-9a-f]{12,})\s+\[(active|paused|disabled)\]")
```

The actual table emits four state labels — `active`, `paused`, `disabled`, **and `completed`** — so the `[completed]` header lines fell through. The parser's loop structure is:

```python
current = None
for line in table.splitlines():
    if id_re.match(line):                # only fires for active/paused/disabled
        if current: jobs.append(current)
        current = {"id": ..., "enabled": ...}
        continue
    if current is None: continue         # also true if a [completed] header preceded
    key_re.match(line)                   # populates Name/Schedule/Deliver into current
```

A `[completed]` header is neither a new job nor the end of the previous one — it's just a line the regex ignores. `current` continues to point at the previous job, so the completed job's `Name`/`Schedule`/`Deliver` fields are written into it. Last writer wins.

Concrete clobber from the live diff:

```
backup record               real job
─────────────────────       ───────────────────────────────────────────────────
48860712156d                48860712156d [active]
  name:  antig:hourly-…       name: life:renew-car-registration-hourly
  sched: once in 60m          sched: 0 9 * * 5

d87ec0ac5c92                d87ec0ac5c92 [active]
  name:  babysit wa-3157 …    name: life:mizraim-register-pa-daily-9am
  sched: once in 5m           sched: 0 9 * * *
```

`TOTAL` and `ENABLED` were both printed from the same parser:
```bash
TOTAL=$(... status_active or total ...)
ENABLED=$(... active ...)
```
where `status_active` was the active count, and `total` (the real total) only replaced it when `status_active` was null. The parser reported `active=9` AND `status_active=9`, so `TOTAL == ENABLED` every run — a structural guarantee, not a coincidence.

## What changed

The fixed `~/.smartclaw/scripts/cron-backup-sync.sh`:

1. Reads `~/.smartclaw/cron/jobs.json` directly (the canonical store the scheduler ticks through), not the CLI table.
2. Strips volatile runtime fields (`next_run_at`, `last_run_at`, `last_status`, `last_error`, `last_delivery_error`, `fire_claim`) before diff, so a tick does not look like a config change.
3. Writes via `tmp + mv`, so a crash mid-write cannot truncate the previous good backup.
4. Exits 1 on missing or corrupt store and leaves the previous snapshot intact (verified with a rename + a `not json{` overwrite test).
5. The Slack message quotes the **commit SHA** it just produced (`Cron Backup: committed <sha>. Total: 36 jobs (9 enabled).`), so a regression in the parser cannot fabricate a matching report.

Verified round-trip:
- 36/36 jobs present in export, names exact, schedules exact, enabled flags match.
- Re-runs report `Changed=0`.
- Both failure paths (missing store, corrupt JSON) exit non-zero; previous backup is byte-identical.

## Lessons

- CLI table output is human-facing rendering, not an API. If a field is needed for restore, the daemon's on-disk store has it; the table almost certainly does not.
- A grep that misses one bucket silently mis-attributes every field after it. Always validate the **set** of headers against a `sort | uniq -c` against the live store, not against your own header regex.
- When the Slack notification says "X (Y enabled)" and `X == Y` every time, the variables share a fallback. That is a bug shape, not a coincidence.
- A "Cron Backup: no changes" line is fine; a "Cron Backup: committed" line that disagrees with the on-disk store is a five-alarm fire. Always verify the file the script just wrote.

## Cleanup still owed

- `~/.smartclaw/scripts/backup_cron_jobs.sh` still calls the removed `--json` flag and would now exit 1 on every invocation. It is not currently scheduled in launchd or crontab, so nothing is actively broken — but it is dead code that looks live. Delete it or point it at `cron/jobs.json` (it lives at `~/.smartclaw/scripts/backup_cron_jobs.sh`).
- The bad commit `cc729fe2cb` and the regenerated backup files in `docs/context/` are staged in `~/.smartclaw` with an unrelated working-tree backlog (`auth.json.corrupt`, `DOC_GAPS.md`, etc.). Operator's call on how to sequence a follow-up commit/push.
- `~/.smartclaw/skills/shell-script-template-substitution/references/diagnosed-scripts.md` documents the original `--json` → table-parsing fallback as the fix without naming the canonical store. Either patch it to point at this skill, or leave a cross-reference from the next skillify pass.
