---
name: coding-wave-liveness-check
description: "Verify coding-wave worker liveness."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
---

# Coding-Wave Liveness Check

When reporting on a coding wave (multiple `bash -lic 'claudem -p <task>'` workers dispatched via the `claude-code-claudem` skill), **never** trust `pgrep -af claudem | wc -l` for worker count. Each worker runs inside a `claude.exe --bg-spare` slot owned by the `claude-code` daemon, so `pgrep` matches the daemon tree AND every bg-spare wrapper — the count is 5-20× the real worker count, and every worker appears alive even when most have exited.

This skill encodes the correct verification recipe. Verified 2026-08-13 on `${SLACK_CHANNEL_ID}` — bot status reported "78 claudem processes alive" when there were 5 real workers (4 alive, 1 correctly STOPped).

## When to use

Use this skill when:

- A status cron (`--at 20m --delete-after-run --repeat 1`) fires on a coding wave and asks for current status
- The user asks "status on backlog" / "how are the workers doing" / "is the wave done"
- An agent needs to decide whether to dispatch the next batch (cap-at-2-concurrent policy)
- Before claiming "all workers still running" or "N workers exited" in any user-facing reply

## The four verification methods

Pick ONE per worker, in priority order. Always verify, never infer.

### Method 1 — session-id match (most reliable, single line)

Each worker's cmdline includes `--session-id <uuid>`. Match on the first 8 hex chars:

```bash
ps -eo pid,etime,command -A | grep claude.exe | grep 'session-id <8-hex-prefix>'
```

- `etime` < 15 min since dispatch → worker alive
- cmdline still present → worker process not exited
- If no match → worker exited (which may be correct — see Method 2)

### Method 2 — JSONL mtime (cheapest, best for "is it actively making tool calls")

Each worker session appends to `~/.claude/projects/-<cwd-hash>/<uuid>.jsonl`. To find a worker's JSONL path, read the first user message of each session in that project dir (the task prompt identifies which worker it belongs to). Then check mtime:

```bash
# Per worker, get mtime + size
ls -la --time-style=full-iso ~/.claude/projects/-Users-jleechan-projects-worldarchitect-ai/<uuid>.jsonl
```

- mtime < 2 min ago → actively making tool calls
- mtime > 5 min ago + no `is_terminal()` text in last assistant → stalled or STOPped
- If last assistant text is "## STOP — Blocker. Cannot Proceed." → correctly STOPped, NOT a bug

### Method 3 — worktree cwd (cheapest for "is the worktree still around")

Workers create their worktree at `/private/tmp/wt-<topic>` or `${HOME}/.claude/worktrees/<branch>`. If the directory exists, the worker created it.

```bash
# For known wave branches
for branch in fix/dice-natural-1-always-fail-natural-20-always-succeed \
              fix/combat-agent-verify-or-fix \
              fix/arrow-ui-exact-match \
              feat/ui-redesign-advice-batch-1; do
    short="${branch##*/}"
    find /private/tmp ${HOME}/.claude/worktrees -maxdepth 3 -type d -name "${short}*" 2>/dev/null
done
```

- Worktree exists → worker may still be active (or may have exited cleanly without cleaning up)
- Worktree gone → worker either hasn't started or has exited and pruned its worktree

### Method 4 — `git worktree list --porcelain` on the target repo

Less reliable: workers don't always register worktrees in the main repo's `.git/worktrees/`. Use only as a cross-check. If you need this, also include `${HOME}/.claude/worktrees` and `/private/tmp` paths.

## Anti-pattern: what NOT to do

```bash
# WRONG — returns daemon + bg-spare wrappers, NOT workers
pgrep -af claudem | wc -l
# Reported "78" when there were 5 real workers (2026-08-13)

# WRONG — same daemon-tree false positive
ps aux | grep claudem | grep -v grep | wc -l

# WRONG — daemon name match, not worker match
pgrep -f claude-code-daemon | wc -l

# WRONG — `lsof` on the daemon's pty socket
lsof -p <daemon-pid> | grep sock | wc -l
# Counts ptys allocated by the daemon, NOT worker sessions
```

## Report format

Per worker, report:
- **liveness:** 🟢 alive / 🟡 stalled / 🔴 dead / ⚪ correctly STOPped
- **last activity:** JSONL mtime (e.g., "0.1 min ago")
- **worktree:** path if exists, "(pruned)" if gone
- **PR:** URL if pushed, "(no PR yet)" if still building, "(N/A)" if STOPped

Use Slack-native concise sections (Healthy/Risky/Blocked/Next actions), colored icons, no wide tables. **Always cite the verification method used** for each worker (session-id / JSONL mtime / worktree cwd) so the user can verify your claim.

## Pitfalls

- **Workers may legitimately exit before the wave is "done."** A worker that has finished its task, STOPped on blockers, or merged its PR will exit and stop appending to JSONL — that's correct behavior, not a bug. Check the worker's *final assistant text* before reporting it as "died unexpectedly."
- **Workers that have pivoted off their assigned branch** (e.g., the combat-agent worker switched from `fix/combat-agent-verify-or-fix` to `fix/prefix-conditional-relocations` after finding PR #8809 already merged) will have worktrees under different names. Always read the worker's recent file ops (`git log --oneline origin/main..HEAD` in its cwd) before declaring "off-scope."
- **`ps -eo command -A` output is huge** — always pipe through `grep 'session-id <prefix>'` to keep the output under 10 lines.
- **JSONL path encoding**: `~/.claude/projects/` uses double-dash path encoding (e.g., `-Users-jleechan-projects-worldarchitect-ai/`). Globbing works fine; explicit paths need the leading dash + no separator.
- **The worker's session-uuid is NOT the same as the `claude --session-id` flag value** — the JSONL filename matches the session-uuid. Always cross-reference via the first user message in the JSONL.
- **Workers may cite bead IDs that "don't exist" in the active repo** — before reporting the worker as mis-citing or transcribing IDs, check the cross-repo bead stores. Verified 2026-08-13 in `${SLACK_CHANNEL_ID}/p1786684990.874569`: the worker cited `rev-j24mb` / `rev-2nabu` / `rev-btxyn` which the bot flagged as missing from `~/repos/jleechanorg/worldarchitect.ai/.beads/`, but all three resolve in `~/projects/dark-factory/.beads/issues.jsonl` (canonical store for dark-factory beads). The caveat was "cross-repo store mismatch", not fabrication. Recipe:
  ```bash
  # 1. Active repo (where the worker is touching)
  cd ~/repos/jleechanorg/<active-repo> && br list 2>&1 | grep -E "<bead-id-pattern>"

  # 2. Cross-repo canonical stores on this machine
  for repo in dark-factory claude-commands jleechanbrain worldarchitect.ai; do
      for base in ~/projects ~/repos/jleechanorg; do
          [ -d "$base/$repo" ] && (cd "$base/$repo" && br list 2>&1 | grep -E "<bead-id-pattern>" | head -3)
      done
  done

  # 3. If still no match, grep raw JSONL across all .beads/ trees
  grep -lE "<bead-id-pattern>" ~/projects/*/.beads/issues.jsonl \
      ~/repos/jleechanorg/*/.beads/issues.jsonl 2>/dev/null
  ```
  Coding-wave / dark-factory beads are typically `rev-<5char>` IDs (e.g. `rev-j24mb`, `rev-2nabu`, `rev-btxyn`) and live in `~/projects/dark-factory/.beads/` regardless of which repo the worker is touching. Always `br show <id>` to confirm status (OPEN / CLOSED / P-level / owner) before writing "missing" or "fabricated" in any user-facing reply.

## Cross-references

- `claude-code-claudem` — dispatch skill that creates these workers (currently user-owned; if you have write access, patch its "Gotchas" with this recipe)
- `status-check-cron-execution` — covers cron-driven status of in-flight work (currently user-owned)
- `slack-cron-report-health` — diagnostic skill for silent or wrong Slack-bound crons
- `babysit-stale-watchdog` — handles babysit crons whose target PR is MERGED/CLOSED
- `claude-code` (bundled) — canonical Claude Code CLI skill