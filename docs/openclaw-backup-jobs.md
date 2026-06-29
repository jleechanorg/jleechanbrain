# Hermes ~/.smartclaw Backup Automation

This repository includes a recurring backup workflow for `~/.smartclaw` that runs on:

- `launchd` (24/7 Apple scheduler)

Guardrail:
- Forbidden: system `crontab` edits for Hermes jobs.
- Required: launchd scheduling for repo-managed recurring jobs.

Backups are written into this repository as redacted snapshots under:

- `.smartclaw-backups/<YYYYMMDD_HHMMSS>/`

## What gets backed up

The backup script mirrors `~/.smartclaw` contents and performs in-band redaction/scrubbing:

- masks common secret-bearing environment/key/token patterns in text files
- redacts obvious embedded credential strings
- skips obvious binary/log/db/ipynb/jsonl artifacts
- keeps a `REDACTION_MANIFEST.txt` per snapshot

## Files added

- `scripts/backup-hermes-full.sh` — creates redacted snapshot and commits when changed
- `scripts/run-hermes-backup.sh` — wrapper with timestamped logging
- `scripts/hermes-backup.plist.template` — `launchd` job template
- `scripts/install-hermes-backup-jobs.sh` — installs launchd schedules and removes legacy Hermes crontab entries

## Install recurring jobs

```bash
cd ~/.smartclaw/workspace/hermes
./scripts/install-hermes-backup-jobs.sh
```

This creates:

- `com.smartclaw.backup` launchd job at `~/Library/LaunchAgents/`

## Verify

```bash
# launchd status
launchctl print gui/$(id -u)/com.smartclaw.backup
# run once now
./scripts/run-hermes-backup.sh
```

## Logs

- `~/Library/Logs/hermes-backup/hermes-backup.log`
- `~/Library/Logs/hermes-backup/stdout.log`
- `~/Library/Logs/hermes-backup/stderr.log`
