# Reference: polluted-worktree recovery — jleechanorg/worldarchitect.ai#8794 → #8805

**Incident date:** 2026-08-06
**Trigger:** Dropped-thread followup fired at 30m on `C0AH3RY3DK6/p1785979549858139` ("ok lets redo the PR and focus on phase1. Users can share/edit an existing campaign"). The terminal status response uncovered that [PR #8794](https://github.com/jleechanorg/worldarchitect.ai/pull/8794) had been opened days earlier with `5657 lines / 16 files` — most of it a polluted `.beads/issues.jsonl` plus 5 unrelated tier_pressure-revert files because the claudem worker's worktree was forked from a stale origin/main.

This transcript is the **recovery recipe in practice**, not theory. Read this after the "Recovery" section of `tracked-append-only-git-defense/SKILL.md` and execute it; every command is real and was run on Hermes gateway session `default/20260806_*` to produce [PR #8805](https://github.com/jleechanorg/worldarchitect.ai/pull/8805) (`8 files, +1430/-0, exactly the share-token scope`).

---

## 0. Symptoms — confirming the worktree is polluted

```bash
# Detect: too many files / lines for a scoped feature PR
git diff --shortstat origin/main..HEAD
# 16 files changed, 5657 insertions(+), 80 deletions(-)
#   (anything > 1500 on a thin-slice feature PR is suspicious)

# Detect: append-only log files in the diff
git diff origin/main..HEAD --name-only | grep -E '\.(jsonl|log|po)$'
# .beads/issues.jsonl
#   (NEVER want to see .beads/issues.jsonl in a feature PR diff
#    unless the PR is literally about the JSONL.)

# Detect: stale base
git log --oneline origin/main..HEAD --grep='^Merge remote-tracking branch'
# merge remote-tracking branch 'origin/main' into feat/campaign-share-url-phase1
#   (means the worker did `git pull` instead of `git rebase` or made a fresh branch)

# Detect: scope drift from auto-staged unrelated files
git diff origin/main..HEAD --stat | grep -vE '^( |$|[0-9]+ files? changed)'
# Look for entries unrelated to the PR title. Share PR contains:
#   mvp_site/agent_prompts.py            (tier_pressure revert)
#   mvp_site/agents.py                   (tier_pressure revert)
#   mvp_site/constants.py                (tier_pressure revert)
#   mvp_site/prompts/shared/tier_pressure.md  (tier_pressure revert)
#   mvp_site/tests/test_agents.py        (unrelated)
#   mvp_site/tests/test_level_up_stale_flags.py  (unrelated)
#   mvp_site/tests/test_prompts.py       (unrelated)
# All unrelated to "campaign share tokens".
```

## 1. Mark CI output (so you know which jobs were broken)

```bash
gh pr view <N> --repo <owner>/<repo> --json statusCheckRollup \
  | jq -r '.statusCheckRollup[]
           | select(.conclusion=="FAILURE")
           | "\(.name) -> \(.detailsUrl)"'
# Mobile Auth Same-Origin Regression
# Playwright auth browser tests (Chromium + WebKit)
# Directory tests (core-mvp-1(self hosted))
# Directory tests (core-mvp-2(self hosted))
# Directory tests (core-mvp-3(self hosted))
# Directory tests (core-tests)
# beads-jsonl-validation
# Tests Required Gate
```

`beads-jsonl-validation` is the smoking gun:

```bash
gh run view <run-id> --repo <owner>/<repo> --job <job-id> --log-failed \
  | grep "duplicate id"
# - line 6738: duplicate id 'rev-zkhey'
# - line 6739: duplicate id 'rev-zkzu'
# ... 877 duplicate IDs total.
```

The actual root cause is `test_beads_integrity.py:test_beads_issue_ids_are_unique` failing — visible in the core-tests artifact:

```bash
gh api repos/<owner>/<repo>/actions/runs/<run-id>/artifacts --jq '.artifacts[] | select(.name=="test-results-core-tests") | .archive_download_url'
curl -fsSL -H "Authorization: Bearer $(gh auth token)" -o test-results-core-tests.zip "<url>"
unzip test-results-core-tests.zip -d test-results
grep -A2 "FAILURES" test-results/test_beads_integrity.py.*.log | head -10
# TestBeadsIntegrity.test_beads_issue_ids_are_unique ... AssertionError
# Expected unique issue IDs in .beads/issues.jsonl
```

## 2. Close the polluted PR (preserve the commit so we can extract its wanted files)

```bash
gh pr close <N> --repo <owner>/<repo> --delete-branch=false --comment "Replaced by <NEW-PR-NUMBER> — this branch was built from stale origin/main and included 4228 lines of polluted .beads/issues.jsonl plus 5 unrelated tier_pressure revert files. Clean replay at <NEW-PR-URL>"
```

The branch is NOT deleted — we need the original commit's tree to extract the wanted files in step 4.

## 3. Fresh worktree from CURRENT origin/main

```bash
git fetch origin main

# Verify the local main is stale before creating the new worktree
git log --oneline -1 HEAD
# <polluted-commit-hash> feat(share): campaign share-token thin slice (Phase 1) ...
git log --oneline -1 origin/main
# <NEW-origin-main-sha> ... (the upstream HEAD the worker should have based on)

# Create a new worktree from current origin/main only
git worktree add -b fix/<topic>-clean ~/wt-<topic>-clean origin/main
```

## 4. Extract ONLY the wanted files from the polluted commit

```bash
cd ~/wt-<topic>-clean

# Identify the SHA of the wanted diff on the polluted branch
git show <polluted-commit-sha> --stat
# docs/plans/2026-08-05-campaign-share-redesign.md | 287 ++++++++++++++++++
# mvp_site/frontend_v1/app.js                      | 109 +++++++
# mvp_site/frontend_v1/index.html                  |   41 +++
# mvp_site/frontend_v1/js/campaign-wizard.js       |   90 ++++++
# mvp_site/main.py                                 | 178 ++++++++
# mvp_site/share_token.py                          | 242 +++++++++++++
# mvp_site/tests/test_modal_placement.py           | 124 ++++++++
# mvp_site/tests/test_share_token.py               | 356 +++++++++++++++++++++
#                                                                        
# These 8 files are the wanted diff. The other 8 are pollution.

# Path-limited checkout brings ONLY those 8 files into the new worktree.
# This is the surgical-extract — equivalent to cherry-pick minus the noise.
git checkout <polluted-commit-sha> -- \
  mvp_site/share_token.py \
  mvp_site/main.py \
  mvp_site/frontend_v1/app.js \
  mvp_site/frontend_v1/index.html \
  mvp_site/frontend_v1/js/campaign-wizard.js \
  mvp_site/tests/test_share_token.py \
  mvp_site/tests/test_modal_placement.py \
  docs/plans/2026-08-05-campaign-share-redesign.md

git status --short
#   All 8 files staged; nothing else.
```

**Critical: this step intentionally skips the auto-staged `.beads/issues.jsonl`, the unrelated `tier_pressure.md` revert, etc. The path-limited checkout addresses files by name. Cherry-pick would have re-introduced all of them.**

## 5. Local quality gates on the clean worktree

```bash
# Tests for the new files
./run_tests.sh mvp_site/tests/test_share_token.py mvp_site/tests/test_modal_placement.py
# 13/13 passing

# Lint ONLY the touched files
ruff check mvp_site/share_token.py mvp_site/main.py \
  mvp_site/tests/test_share_token.py mvp_site/tests/test_modal_placement.py
# All checks passed!
#   (Found 6 errors on first run — see section 6 for the pattern; fix and re-check.)

# Format ONLY the touched files (AGENTS.md "format only touched files" rule)
ruff format --check mvp_site/share_token.py mvp_site/main.py \
  mvp_site/tests/test_share_token.py mvp_site/tests/test_modal_placement.py
# 2 files would be reformatted, 2 files already formatted
ruff format mvp_site/share_token.py mvp_site/main.py \
  mvp_site/tests/test_share_token.py mvp_site/tests/test_modal_placement.py
```

## 6. Lint fixes commonly seen in pollution recovery

Real fixes that landed in PR #8805's clean replay (each is a `ruff` rule + a one-line patch):

```python
# F841 Local variable assigned but never used — dead code
#   mvp_site/main.py:3014:  description = escape(payload.get("description") or "")
#   mvp_site/main.py:3015:  character_template = escape(payload.get(...) or "")
#   mvp_site/main.py:3016:  source_campaign_id = escape(payload.get(...) or "")
#   → DELETE the three lines; the HTML template below only uses title/setting/author/preview/play_url.

# UP028 yield over for-loop — modernize
#   for path in sorted(FRONTEND_DIR.rglob("*.html")):
#       yield path
#   → yield from sorted(FRONTEND_DIR.rglob("*.html"))

# UP037 Quoted type annotation — stub class already in scope
#   def collection(self, name: str) -> "_FakeFirestoreCollection":
#   → def collection(self, name: str) -> _FakeFirestoreCollection:

# E402 Module-level imports not sorted — placement fix
#   import sys
#   import importlib
#   → import importlib
#     import sys
```

Six lines changed, one quality-gate turn.

## 7. Commit, push, open PR

```bash
cd ~/wt-<topic>-clean
git -c user.email="claude-code@anthropic.com" -c user.name="Claude Code" \
    commit -m "<proper-prefix>: <scope>: <description>
...
<standard commit body>

Co-authored-by: ..."  # optional
git push -u origin HEAD
gh pr create --repo <owner>/<repo> \
  --base main \
  --head fix/<topic>-clean \
  --title "<proper-prefix>: <scope>: <description>" \
  --body "<standard PR body with /es evidence when applicable>"
```

## 8. Verify cleanliness

```bash
git diff --shortstat origin/main..HEAD
# 8 files changed, 1430 insertions(+), -0 deletions(-)
git diff origin/main..HEAD --name-only
#   ONLY the 8 wanted files. Nothing else.

gh pr view <NEW-N> --repo <owner>/<repo> \
  --json additions,changedFiles,deletions,isDraft,state,url
# { "additions": 1430, "changedFiles": 8, "deletions": 0,
#   "isDraft": false, "state": "OPEN",
#   "url": "https://github.com/<owner>/<repo>/pull/<NEW-N>" }
```

## 9. Cleanup (optional — keep the polluted worktree until you've shipped the clean replay)

```bash
# Don't `git worktree remove` the polluted worktree until after the clean PR
# ships — having it around preserves the original commit SHA for any
# disambiguation questions during code review. After merge:
git worktree remove --force ~/wt-<topic>
git worktree list
```

---

## Numbers — what "clean replay" looks like at a glance

| Metric                 | Polluted PR (#8794)        | Clean replay (#8805)   |
|------------------------|----------------------------|------------------------|
| files changed          | 16                         | 8                      |
| lines added            | 5657                       | 1430                   |
| lines deleted          | 80 (reverts)               | 0                      |
| `.beads/issues.jsonl`  | +4228 (corrupted)          | untouched              |
| unrelated scope        | 5 files (tier_pressure)    | 0                      |
| CI status              | 8 checks FAILING            | gate-ready             |
| local tests            | 13/13 passing              | 13/13 passing          |
| lint (touched files)   | not run                    | clean (0 errors)       |
| format (touched files) | not run                    | clean (0 reformat)     |
| cost to gateway        | $0.10 (~12 tool calls)     | —                      |
| cost to worker         | $6.16 / 154 turns / 34 min | —                      |

The clean replay had ZERO worker dispatch — the recovery was 12 inline tool calls. The high worker cost vs low recovery cost is the argument for the recipe: catching the pollution early is much cheaper than reimplementing from scratch.
