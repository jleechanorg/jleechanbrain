---
name: worker-timeout-salvage-recipe
description: "When an AO worker times out mid-task, the worktree + uncommitted files survive — recovery is a 10-step pattern, not a restart from scratch."
when_to_use: |
  Load when an AO worker (deleg_da* / worldarchitect-NNN / similar session id) hits
  the 600s hard timeout, or the operator says "the worker died / timed out, what
  state did it leave?", or your babysit cron reports `exit reason: timeout after N
  API calls` with no PR opened.
---

# Worker-timeout salvage recipe

**Verified 2026-08-06, thread `${SLACK_CHANNEL_ID}/p1784253708`, codex-autoapprove PR
fix.** The AO worker (`deleg_da2df7a9`) timed out at 600s with 43 API calls
burned. It had:

- Fixed 17/18 of the failing tests in `/private/tmp/wa-cmux-codex-autoapprove/.claude/skills/cmux-codex-autoapprove/tests/test_cmux_codex_approve_launchd.py`
- Reduced test failures from 18 → 1 (`test_process_surface_cooldowns_when_approval_send_fails`)
- Created a debug `_probe.py` artifact
- Set up the worktree branch `fix/cmux-codex-autoapprove-test-contract` at `1a48db7319` (1 commit behind `origin/main=fad9db6e0`)

It had NOT:

- Committed anything (no `git log origin/main..HEAD` ahead of main)
- Pushed a branch
- Opened a PR
- Filed the bead

The default reaction to "worker timed out" is to re-spawn fresh and redo all
work. That's wrong. The worktree survives — even uncommitted, even in a tmp
scratch dir. Recovery is **always** cheaper than re-spawn when the partial
work is in the worktree.

## The 10-step recovery recipe

```bash
# 1. Locate the worker's worktree. AO stores them at:
#      ~/.ao/data/worktrees/<project>/<session-id>/
#    OR ad-hoc tmux tmp dirs like:
#      /private/tmp/wa-<topic>/
find /private/tmp ~/.ao/data/worktrees -maxdepth 4 -type d -name "*.claude" 2>/dev/null | head -5
WT=/private/tmp/wa-<topic>    # ← paste the real path

# 2. Inventory what survived — branch state, uncommitted mods, untracked files
cd "$WT" && \
  git status --short && \
  echo "--- ahead of origin/main ---" && \
  git log --oneline origin/main..HEAD | head -20 && \
  echo "--- behind origin/main ---" && \
  git log --oneline HEAD..origin/main | head -5 && \
  echo "--- untracked files (debug? tests? scripts?) ---" && \
  git ls-files --others --exclude-standard | head -10

# 3. Run the failing tests IN-PLACE to see the actual remaining failures
#    Don't trust the worker's last self-report — it may be stale.
python3 -m pytest .claude/skills/<skill>/tests/<test_file>.py --no-header 2>&1 | tail -10
python3 .claude/skills/<skill>/scripts/<smoke_test>.py 2>&1 | tail -10

# 4. If the worktree is BEHIND origin/main, rebase onto it BEFORE doing more work.
#    Per pr-clean-branch-from-main-no-history-bloat: branch must be from origin/main.
cd "$WT" && \
  git fetch origin 2>&1 | tail -3 && \
  git stash -u 2>&1 | tail -2 && \
  git rebase origin/main 2>&1 | tail -5 && \
  git stash pop 2>&1 | tail -5 && \
  git rev-parse HEAD   # verify the rebase landed

# 5. Fix the remaining test failures inline. Common patterns you'll see:
#    a) Spurious assertions referencing strings production never emitted
#       (e.g. "APPROVE_SKIPPED" log line that production doesn't log)
#       → drop the assertion, add a comment explaining why production does it differently
#    b) Stale name references after a rename refactor
#       (e.g. is_approval_candidate → is_approval_candidate_semantic,
#             APPROVE_OPTION_RE → NUMBERED_ALLOW_RE/_CANCEL_RE/_THREE_OPTION_CODEX_RE)
#       → grep the production module for the new name, update the test
#    c) References to symbols that were removed entirely
#       (e.g. CMUX_SOCKET_DISCOVER_RE that production replaced with a glob function)
#       → drop the test section, document why in a comment
#
#    VERIFY GREEN after each fix:
python3 -m pytest <path>::test_specific_failure --no-header 2>&1 | tail -5

# 6. Drop any debug artifacts the worker left behind
#    (e.g. _probe.py, scratch logs, experimental scripts)
#    Use git to find them — anything matching test names with "_probe" / "_debug" / "_scratch"
git ls-files --others --exclude-standard | grep -E "(_probe|_debug|_scratch|test_.*_tmp)\.py$"

# 7. Commit with proper CLI/model provenance per env-preferences.mdc
#    (every commit subject must be prefixed with `<cli>/<model-id>:`)
git add .claude/scripts/<shared_module>.py .claude/skills/<skill>/
git commit -m "<cli>/<model-id>: <type>(<scope>): <one-line summary>

<body — file:line evidence, test results table, bead ID, source thread>"
# Include the pre-rebase SHA in the body for history-correction auditability:
#   "Originally <SHORT-SHA>: <what the worker did before timing out>"

# 8. Push with --force-with-lease -u for new branches, --force-with-lease for existing
#    NEVER push without verifying first:
git status --short                # MUST be clean
git log --oneline origin/main..HEAD  # MUST show only the new commits
git push --force-with-lease -u origin <branch>

# 9. Open the PR
gh pr create --base main --head <branch> \
  --title "<cli>/<model-id>: <title>" \
  --body "<full body with file:line evidence, test results table, bead ID, source thread URL>"

# 10. Update the bead (if one was filed) with the PR URL
br update <bead-id> --notes "Fix landed in PR <url> — <N>/<N> tests pass. <follow-up scope>"

# 11. Final reply — NOT a half-stop status. Include:
#     - PR URL
#     - Test counts (must be green for everything that ran in CI before)
#     - Bead ID
#     - Source-of-truth file paths (Drive folder, scratch dir, etc.)
#     - One-line "what shipped"
```

## Decision tree: salvage vs. fresh re-spawn

**Salvage (use this recipe) when ALL of these hold:**

- Worktree directory still exists and is `git`-readable
- The branch is at most a few commits behind `origin/main` (rebase-able in one step)
- Test failures reduced meaningfully from start state (worker made progress, didn't thrash)
- Uncommitted work includes test fixes that took multiple iterations (re-deriving is expensive)

**Re-spawn fresh when ANY of these hold:**

- Worktree dir is gone or corrupted
- Branch is many commits behind `origin/main` with conflicts
- Worker was thrashing (same failure → same patch → same failure pattern in the transcript)
- No tangible progress in the transcript (worker spent budget on exploration, no test green checkpoint)

**Hybrid — salvage the salvageable, re-spawn the rest:**

- The verified-good files (tests already passing, the production module) move directly into the re-spawn worker's brief as `cp` instructions
- The unfinished tests go into the re-spawn brief as the explicit next-step recipe
- See the long-brief delivery recipe in this skill's main SKILL.md for how to pass a 5-10 KB brief to the new worker

## Why this recipe isn't covered elsewhere

`drive-pr-to-green` covers the "worker died, finish the work" path but assumes
a PR exists with a known head SHA. `always-pr-never-local-edit` covers the
"don't stop at local commit" rule. Neither covers the case where the worker
**died before committing**, leaving the worktree as the only evidence of
progress.

The recipe fills the gap between "worker timed out" and "PR open". It also
serves as the **recovery path for the half-stop pattern** documented in
`references/half-stop-user-re-ping-signal.md` — when the user re-pings
their own status message, the right response is often to *salvage the
existing worktree* rather than spawn fresh.

## Companion references in this skill

- `references/half-stop-user-re-ping-signal.md` — when the user re-pings their
  own message, salvage is often cheaper than re-spawn
- The "Long-brief delivery recipe (verified 2026-08-05, PR #8787)" section in
  the main SKILL.md — passing the salvage state to a re-spawn if you decide
  to hybrid (salvage the tests, re-spawn for the PR + push)
- `references/skeptic-system-deleted.md` — what the 2-gate /green definition
  actually is post-2026-07-09

## Companion skills

- `~/.smartclaw/skills/finish-the-job/SKILL.md` — end-state contract (green PR
  merged / PR open with green CI / local state change verified)
- `~/.smartclaw/skills/always-pr-never-local-edit/SKILL.md` — the "never stop at
  local commit" rule this recipe completes
- `~/.smartclaw/skills/drive-pr-to-green/SKILL.md` — green-up-and-merge workflow
  that picks up AFTER this salvage recipe (when the PR already exists)

## Anti-patterns

- **"Worker timed out → re-spawn" as the default.** Always check the worktree
  first. If files exist, salvage is almost always cheaper.
- **Trusting the worker's last test count.** The worker may have run tests
  60s before timeout, after which a patch broke them again. Always re-run
  in your own terminal before declaring green.
- **Pushing without checking for debug artifacts.** Workers commonly leave
  `_probe.py` / `_debug.py` / `scratch_*.py` in the worktree. Drop them
  before `git add`.
- **Skipping the rebase onto origin/main.** The worktree was created at
  *some* main SHA — usually a few hours behind current origin/main. Without
  rebase, the PR carries an unrelated drift baseline that triggers
  CHANGES_REQUESTED in code review.
- **Committing with no provenance tag.** env-preferences.mdc requires every
  commit subject to start with `<cli>/<model-id>:`. Workers sometimes omit
  this; fix it in the salvage commit.
- **Re-asking the user "should I salvage or re-spawn?"** Per
  `finish-the-job`'s Phase 0 contract, the only allowed pre-spawn question
  is up-front classification. Once the worktree is verified-recoverable, you
  salvage and tell the user — you do not pause for confirmation.