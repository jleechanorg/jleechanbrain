# Hermes Cron → Launchd Migration

## Live vs Tracked Distinction

This is the canonical reference for how Hermes's scheduled/recurring jobs are managed.

### Tracked in Git (here, in `launchd/`)

All **infrastructure** and **scheduled review/analysis** jobs are tracked as launchd plist
templates in this repository. These represent *scheduling intent* — when something should run
and what it should do — and are reproduced on any machine via the install scripts.

| Plist | Label | Schedule | Script | Purpose |
|-------|-------|----------|--------|---------|
| `ai.smartclaw.prod.plist` | `ai.smartclaw.prod` | KeepAlive | `hermes` CLI | Hermes gateway daemon (port 8643) |
| `ai.smartclaw.health-check.plist` | `ai.smartclaw.health-check` | 5 min | `health-check.sh` | Gateway health probe + self-heal |
| `ai.smartclaw.monitor-agent.plist` | `ai.smartclaw.monitor-agent` | 30 min | `monitor-agent.sh` | Agent process monitoring |
| `ai.smartclaw.schedule.morning-log-review.plist` | `ai.smartclaw.schedule.morning-log-review` | 8:00 AM PT daily | `morning-log-review.sh` | Gateway log error review |
| `ai.smartclaw.schedule.weekly-error-trends.plist` | `ai.smartclaw.schedule.weekly-error-trends` | Mon 9:00 AM PT | `weekly-error-trends.sh` | 7-day error trend analysis |
| `ai.smartclaw.schedule.docs-drift-review.plist` | `ai.smartclaw.schedule.docs-drift-review` | 8:15 AM PT daily | `docs-drift-review.sh` | Docs audit + drift fill |
| `ai.smartclaw.schedule.cron-backup-sync.plist` | `ai.smartclaw.schedule.cron-backup-sync` | 8:25 AM PT daily | `cron-backup-sync.sh` | Cron backup + git commit |
| `ai.smartclaw.schedule.daily-research.plist` | `ai.smartclaw.schedule.daily-research` | 6:00 PM PT M–F | `daily-hermes-research.sh` | Hermes tips + state check |
| `ai.smartclaw.schedule.living-blog-status.plist` | `ai.smartclaw.schedule.living-blog-status` | Hourly | `living-blog-status.sh` | Living blog + novel status → #novel |
| `ai.smartclaw.schedule.bug-hunt-9am.plist` | `ai.smartclaw.schedule.bug-hunt-9am` | 9:00 AM PT M–F | `scripts/bug-hunt-daily.sh` | Bug hunt across repos |
| `ai.smartclaw.schedule.harness-analyzer-9am.plist` | `ai.smartclaw.schedule.harness-analyzer-9am` | 9:00 AM PT M–F | `scripts/harness-analyzer.sh` | Harness engineering analysis |
| `ai.smartclaw.schedule.orch-health-weekly.plist` | `ai.smartclaw.schedule.orch-health-weekly` | Mon 9:30 AM PT | `orchestration.cron_runner` | Orchestration health report |
| `ai.smartclaw.schedule.composio-upstream-reminder.plist` | `ai.smartclaw.schedule.composio-upstream-reminder` | Mon 9:00 AM PT | `scripts/composio-upstream-reminder.sh` | Reminder to consider upstream pull + PR batch |
| `ai.smartclaw.schedule.github-intake.plist` | `ai.smartclaw.schedule.github-intake` | 9:00 AM PT daily | `scripts/github-intake.sh` | GitHub notification intake |
| `ai.smartclaw.schedule.daily-repo-export.plist.template` | `ai.smartclaw.schedule.daily-repo-export` | 3:20 AM local daily | `scripts/auto-push-to-main.sh --repo ...` | Export `llm_wiki` + `roadmap` to `origin/main`; AO Go recovery on failure — see "Daily Repository Export" below |
| `ai.agento.dashboard.plist` | `ai.agento.dashboard` | KeepAlive | `npx next start` | AO web dashboard (port 3020) |
| `ai.smartclaw.lifecycle-manager.plist` | `ai.smartclaw.lifecycle-manager` | KeepAlive | inline bash | AO lifecycle workers |
| `ai.smartclaw.config-sync.plist` | `ai.smartclaw.config-sync` | 1 hr | `scripts/sync-hermes-config.sh` | Config sync to live dir |
| `ai.smartclaw.qdrant.plist` | `ai.smartclaw.qdrant` | KeepAlive | `scripts/start-qdrant-container.sh` | Qdrant vector DB (Docker) |
| `ai.smartclaw.webhook.plist` | `ai.smartclaw.webhook` | KeepAlive | webhook daemon | GitHub webhook ingress |
| `com.smartclaw.backup.plist` | `com.smartclaw.backup` | 4h20m | `scripts/run-hermes-backup.sh` | Redacted backup snapshots |

### Live Only (gitignored: `~/.smartclaw/cron/jobs.json`)

These jobs are **managed by the Hermes gateway** and live in `~/.smartclaw/cron/jobs.json`.
That file is **gitignored** — it is never committed. These are short-lived, ad-hoc, or
PR-automation jobs where gateway ownership of lifecycle is appropriate.

**These remain live and are NOT migrated to launchd:**

| Job ID | Name | Schedule | Why Live-Only |
|--------|------|----------|---------------|
| `9417b82a-ac58-4d00-b5f3-5103e2f7073a` | `thread-followup-ao263` | 5 min interval | Ad-hoc follow-up; short-lived; gateway manages lifecycle |
| *(future PR automation jobs)* | `agento:pr-monitor-*` | varies | AO lifecycle-worker owns spawn/cleanup; gateway is not the canonical owner |
| *(any `thread-followup-*` jobs)* | `thread-followup-*` | interval | Same as above — short-lived, spawned by AO |

### Canonical Install Path

```bash
# Single entrypoint — installs ALL hermes launchd services
cd ~/.smartclaw  # or any worktree
./scripts/install-hermes-launchd.sh

# Bootstrap also calls this automatically after git clone
bash ~/.smartclaw/scripts/bootstrap.sh
```

To verify all labels are loaded. Note: several labels require separate setup and may be absent on a fresh machine — `ai.smartclaw.qdrant` needs Docker, `ai.smartclaw.webhook` needs a separate webhook setup script, `ai.agento.dashboard` needs the agent-orchestrator packages, `ai.smartclaw.lifecycle-manager` and `ai.smartclaw.config-sync` are managed by the AO orchestrator, and `com.smartclaw.backup` needs the backup script. Labels not installed will show ✗ — install the relevant prerequisite before re-running the check.

To verify all labels are loaded:

```bash
for label in \
  ai.smartclaw.prod \
  ai.smartclaw.health-check \
  ai.smartclaw.monitor-agent \
  ai.smartclaw.schedule.morning-log-review \
  ai.smartclaw.schedule.weekly-error-trends \
  ai.smartclaw.schedule.docs-drift-review \
  ai.smartclaw.schedule.cron-backup-sync \
  ai.smartclaw.schedule.daily-research \
  ai.smartclaw.schedule.living-blog-status \
  ai.smartclaw.schedule.bug-hunt-9am \
  ai.smartclaw.schedule.harness-analyzer-9am \
  ai.smartclaw.schedule.orch-health-weekly \
  ai.smartclaw.schedule.composio-upstream-reminder \
  ai.smartclaw.schedule.github-intake \
  ai.smartclaw.lifecycle-manager \
  ai.smartclaw.config-sync \
  ai.agento.dashboard \
  ai.smartclaw.qdrant \
  ai.smartclaw.webhook \
  com.smartclaw.backup; do
  if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    echo "✓ $label"
  else
    echo "✗ $label NOT loaded"
  fi
done
```

## Migration Map: Gateway Cron → Launchd

| Gateway Cron Job ID | Name | → Launchd Label | → Plist | → Script |
|---|---|---|---|---|
| `c0accca2-3b58-4da6-ba84-e8c929387e30` | `healthcheck:morning-log-review` | `ai.smartclaw.schedule.morning-log-review` | `ai.smartclaw.schedule.morning-log-review.plist.template` | `morning-log-review.sh` |
| `4ec2aa58-5c97-4c46-8775-a7f030d1dec6` | `healthcheck:weekly-error-trends` | `ai.smartclaw.schedule.weekly-error-trends` | `ai.smartclaw.schedule.weekly-error-trends.plist.template` | `weekly-error-trends.sh` |
| `95f858df-0fe8-4434-90c9-c5c89f61889e` | `healthcheck:docs-drift-review` | `ai.smartclaw.schedule.docs-drift-review` | `ai.smartclaw.schedule.docs-drift-review.plist.template` | `docs-drift-review.sh` |
| `d6bb3693-9f5c-4a4e-99ed-bc56eb33e35c` | `healthcheck:cron-backup-sync` | `ai.smartclaw.schedule.cron-backup-sync` | `ai.smartclaw.schedule.cron-backup-sync.plist.template` | `cron-backup-sync.sh` |
| `abf80788-7bb0-4ce7-9e09-6c1a97faa5cd` | `tips:daily-hermes-research` | `ai.smartclaw.schedule.daily-research` | `ai.smartclaw.schedule.daily-research.plist.template` | `daily-hermes-research.sh` |
| `e2f1a3b4-c5d6-4e7f-8a9b-0c1d2e3f4a5b` | `living-blog:novel-hourly-status` | `ai.smartclaw.schedule.living-blog-status` | `ai.smartclaw.schedule.living-blog-status.plist.template` | `living-blog-status.sh` |
| `9417b82a-ac58-4d00-b5f3-5103e2f7073a` | `thread-followup-ao263` | **NOT MIGRATED** | — | Remains in `~/.smartclaw/cron/jobs.json` (live) |

**Migration behavior:**
- When `install-hermes-scheduled-jobs.sh` runs, it sets `enabled: false` for migrated jobs
  in `~/.smartclaw/cron/jobs.json` (live file, gitignored — changes stay local).
- The gateway is signaled to reload `jobs.json` via SIGHUP.
- If the job was already disabled, no change is made.
- The `jobs.json` file is never committed to git.

## Manual Steps Required

These are honest notes about what requires manual intervention:

1. **Token/secrets**: Some plists reference tokens in `~/.smartclaw/config.yaml`.
   The `install-hermes-launchd.sh` does NOT set up tokens — ensure `config.yaml`
   is configured first (bootstrap.sh handles this for new machines).

2. **Qdrant Docker**: `ai.smartclaw.qdrant` requires Docker to be running.
   If Docker is not running at install time, the service starts on next login.
   Run `docker info` before installing to verify.

3. **AO dashboard directory**: `ai.agento.dashboard` requires
   `$HOME/projects_reference/agent-orchestrator/packages/web` to exist.
   If not present, the plist will fail to start. Install the AO repo first
   or set `AO_DASHBOARD_DIR` env var before running the install.

4. **Existing hardcoded plists**: If you have old hardcoded plist files in
   `~/Library/LaunchAgents/` from before this migration, they may conflict.
   Run `launchctl bootout gui/$(id -u)/<label>` for each old plist before
   re-installing.

5. **Gateway cron live jobs**: After migration, `~/.smartclaw/cron/jobs.json`
   still contains the migrated jobs with `enabled: false`. This is correct.
   The jobs will not run via gateway anymore — they now run via launchd.
   Do NOT delete them from `jobs.json` (the disabled state is the migration marker).

## PR Checklist: Tracked in Git vs Live-Only

Use this checklist when reviewing whether a recurring job belongs in git or stays live.

### Now tracked in git (launchd):
- [ ] All plist templates in `launchd/*.plist.template`
- [ ] All job scripts: `morning-log-review.sh`, `weekly-error-trends.sh`,
      `docs-drift-review.sh`, `cron-backup-sync.sh`, `daily-hermes-research.sh`,
      `living-blog-status.sh`, `composio-upstream-reminder.sh`
- [ ] `scripts/install-hermes-launchd.sh` (central entrypoint)
- [ ] `scripts/install-hermes-scheduled-jobs.sh` (scheduled job installer)
- [ ] `scripts/install-launchagents.sh` (updated to fix CONFIG_DIR and add dashboard)
- [ ] `scripts/bootstrap.sh` (updated to call central installer)

### Still live-only (NOT in git):
- [ ] `~/.smartclaw/cron/jobs.json` — gateway cron jobs, gitignored
  - Contains: `thread-followup-ao263`, future PR automation jobs
  - Never commit this file
- [ ] `~/.smartclaw/config.yaml` — tokens and secrets, gitignored
  - Never commit this file
- [ ] `~/.smartclaw/webhook.json` — webhook secrets, gitignored
  - Never commit this file

## Daily Repository Export (llm_wiki + roadmap, AO Go recovery)

Governing design and plan: `docs/superpowers/specs/2026-07-10-ao-go-daily-repo-export-design.md`,
`docs/superpowers/plans/2026-07-10-ao-go-daily-repo-export.md`. Issue:
https://github.com/jleechanorg/jleechanbrain/issues/755.

`ai.smartclaw.schedule.daily-repo-export` replaces the two overlapping
per-repository jobs below with one daily coordinator run. It uses the
existing deterministic Git fast path in `scripts/auto-push-to-main.sh`
(`--repo PATH:NAME` coordinator mode, preserving the legacy
`<repo_path> <repo_name>` two-argument interface for other callers) and
delegates exceptional recovery — merge conflicts, hook failures, secret-scan
blockers — to `scripts/ao-go-repo-recovery.sh`, a narrow shell boundary
around the **Go** Agent Orchestrator CLI. It never calls `codex` or `claude`
directly.

**Superseded (booted out and removed by the installer once the new label
loads successfully):**
- `ai.smartclaw.schedule.auto-push-llm-wiki` (tracked in this repo)
- `com.jleechan.git-push-llm-wiki` (live-only; wraps the older
  `scripts/git-push-or-codex.sh`, which called `codex exec --yolo` directly
  and staged untracked files with `--no-verify`)

`ai.smartclaw.schedule.auto-push-user-scope` and `com.jleechan.git-push-user-scope`
are **not** touched — user-scope is outside this job's `llm_wiki`+`roadmap`
allowlist and keeps its own schedule.

### Install / dry-run / operate

```bash
# Render + lint every scheduled plist into an isolated $HOME without calling
# launchctl, mutating live cron JSON, or signaling the gateway. Use this to
# verify the daily-repo-export template before touching a real machine.
HOME=/tmp/dry-run-home INSTALL_DRY_RUN=1 \
  AO_GO_BIN="$HOME/.local/bin/ao-go" \
  bash scripts/install-hermes-scheduled-jobs.sh

# Real install (resolves AO_GO_BIN from env or the stable default path;
# fails loudly and skips only this one job if the binary is missing or is
# the rejected Node AO CLI — every other scheduled job still installs):
AO_GO_BIN="$HOME/.local/bin/ao-go" bash scripts/install-hermes-scheduled-jobs.sh

# Inspect the loaded job
launchctl print "gui/$UID/ai.smartclaw.schedule.daily-repo-export"

# Run it once, on demand, instead of waiting for 3:20 AM
launchctl kickstart -k "gui/$UID/ai.smartclaw.schedule.daily-repo-export"

# Logs
tail -n 100 "$HOME/.smartclaw/logs/scheduled-jobs/daily-repo-export.out.log"
tail -n 100 "$HOME/.smartclaw/logs/scheduled-jobs/daily-repo-export.err.log"

# Per-repo state (run id/phase/local+remote SHA/AO session id/harness/attempt)
cat "$HOME/.smartclaw/logs/scheduled-jobs/auto-push-llm-wiki-state.json"
cat "$HOME/.smartclaw/logs/scheduled-jobs/ao-recovery-llm-wiki-state.json"
```

**Success is defined as a freshly fetched local `HEAD` equal to
`refs/remotes/origin/main`** — not merely a zero process exit code. A run
that exits 0 without actually reconciling the remote is not a successful
run; `scripts/ao-go-repo-recovery.sh` only exits 0 once it has verified this
condition itself, independent of what the AO session reports about itself.

### AO Go recovery — session lookup

On a mutating failure (`git add`/`git commit`/`git push`/remote-verify),
the adapter spawns one durable AO session with the configured primary
harness (default `codex`), polls the real remote-head condition, and — if
the primary stalls, terminates, or times out without resolving it — calls
`ao session switch <id> --harness claude-code` on that **same** session
before sending a continuation prompt with the still-unmet exit criteria.
Harness order is AO project configuration
(`AO_PRIMARY_HARNESS`/`AO_FALLBACK_HARNESS`), not shell keyword routing.

```bash
ao session get <id> --json --project llm-wiki-auto-export
ao session get <id> --json --project roadmap-auto-export
```

### Rollback

```bash
launchctl bootout "gui/$UID/ai.smartclaw.schedule.daily-repo-export"
rm -f "$HOME/Library/LaunchAgents/ai.smartclaw.schedule.daily-repo-export.plist"
# Re-render the previous tracked per-repository templates:
bash scripts/install-hermes-scheduled-jobs.sh
```

Rollback does **not** restore the direct `codex exec --yolo` /
`--no-verify` fallback path — that path is permanently removed, and
`tests/test_auto_push_to_main.sh` fails if it is reintroduced into
`scripts/auto-push-to-main.sh`.

## Adding a New Scheduled Job

To add a new recurring job:

1. Create the script in `~/.smartclaw/scripts/` (or `scripts/` in repo).
2. Create `launchd/ai.smartclaw.schedule.<name>.plist.template` using `@HOME@`
   and `@HERMES_EXTRA_PATH@` for paths.
3. Add the plist to `install-hermes-scheduled-jobs.sh` if it needs
   to be installed as part of the standard install.
4. Add the job's gateway cron ID (if migrating from `jobs.json`) to the
   `MIGRATED_JOBS` associative array in `install-hermes-scheduled-jobs.sh`.
5. If the job should NOT be in the standard install, add it to
   `install-launchagents.sh` instead.
6. Update this document with the new job.
