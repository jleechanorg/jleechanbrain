---
name: babysit-stale-watchdog
description: Detect enabled babysit crons whose referenced PR is MERGED or CLOSED and disable them. Companion to the in-script `is_pr_terminal()` check in babysit.py. Without this watchdog, babysit crons can run hundreds of polls for weeks after the PR they were guarding has merged or closed.
trigger: Run every 30 min via launchd. Also manually: `python3 ~/.smartclaw/scripts/babysit_stale_watchdog.py`
---

# babysit-stale-watchdog

## Why

Bug-ref: 2026-07-03 — `babysit-wa-2403-PR7711` fired **251 polls over 11 days** after PR #7711 merged. The original `babysit.py` only recognized "PR created" (a worker output event) as terminal, not "PR MERGED on GitHub" (an external event). The cron kept spamming Slack with "TERMINAL: merged" pings until Jeffrey noticed.

## What

Two-layer fix:

1. **In-script** (`babysit.py` `is_pr_terminal()`): poll() now extracts any PR ref from the task_summary, calls `gh pr view --json state`, and if the PR is MERGED or CLOSED, posts one terminal message and exits the babysit loop. **23/23 tests pass.**

2. **Watchdog** (`babysit_stale_watchdog.py`): belt-and-suspenders. Runs every 30 min via launchd. Even if `babysit.py` is broken or running against an old prompt, the watchdog catches the stale job and disables it within 30 min. **11/11 tests pass.**

## Install

```bash
# 1. Deploy plist (substituting @HOME@ with active home directory)
sed "s|@HOME@|${HOME}|g" ~/.smartclaw/launchd/ai.smartclaw.schedule.babysit-stale-watchdog.plist.template > ~/Library/LaunchAgents/ai.smartclaw.schedule.babysit-stale-watchdog.plist


# 2. Verify syntax
plutil -lint ~/Library/LaunchAgents/ai.smartclaw.schedule.babysit-stale-watchdog.plist

# 3. Load + start
launchctl load -w ~/Library/LaunchAgents/ai.smartclaw.schedule.babysit-stale-watchdog.plist
launchctl kickstart -k gui/$(id -u)/ai.smartclaw.schedule.babysit-stale-watchdog

# 4. Verify it's running
launchctl list | grep babysit-stale-watchdog
tail -5 ~/.smartclaw/cron/output/babysit-stale-watchdog.log
```

## Verify

```bash
# Run once manually
python3 ~/.smartclaw/scripts/babysit_stale_watchdog.py

# Run unit + e2e tests
python3 ~/.smartclaw/scripts/tests/test_babysit_stale_watchdog.py    # 11 tests
python3 ~/.smartclaw/skills/ao-babysit/scripts/test_babysit_pr_exit.py  # 23 tests
```

## Files

- `~/.smartclaw/scripts/babysit_stale_watchdog.py` — the watchdog
- `~/.smartclaw/scripts/tests/test_babysit_stale_watchdog.py` — 9 tests
- `~/.smartclaw/skills/ao-babysit/scripts/babysit.py` — restored + patched with `is_pr_terminal()`
- `~/.smartclaw/skills/ao-babysit/scripts/test_babysit_pr_exit.py` — 19 tests
- `~/.smartclaw/launchd/ai.smartclaw.schedule.babysit-stale-watchdog.plist.template` — committed plist template

## Pitfalls

- **`babysit.py` was deleted** in commit `4a7befcfa4` (squash-merge of feat/hermes-agent-default into main) — only the .pyc survived. Every cron prompt that referenced `python3 ~/.smartclaw/skills/ao-babysit/scripts/babysit.py poll ...` was failing silently. **Restored from `git show 4a7befcfa4^:skills/ao-babysit/scripts/babysit.py`** plus the new merged-PR check.
- **Default repo for bare `PR #NNNN` refs**: defaults to `jleechanorg/worldarchitect.ai` since that's the most common babysit target (5 of 5 in the 2026-07-03 sweep). If babysits for other repos get created, the URL form `https://github.com/o/r/pull/N` is exact — prefer that.
- **gh failures fall through to "not terminal"** — if `gh` is down or rate-limited, the watchdog leaves the job enabled rather than disabling it. The in-script `is_pr_terminal()` has the same fallback.
- **Watchdog is silent by design**: only writes a log line when a job gets disabled. No daily digest.