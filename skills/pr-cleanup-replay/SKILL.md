---
name: pr-cleanup-replay
version: 1.1.0
description: Replay a polluted long-stale PR to a clean branch.
changelog:
  - "1.1.0 (2026-09-16): Add **Variant F — silent-stale-base rebasable PR** (verified on PR #9874 `fix/world-logic-reducer-mask-9869`, jleechanorg/worldarchitect.ai). A new failure mode where `mergeable=MERGEABLE` + all-CI-green gives a false 'PR is ready' signal because CI runs against the PR's own branch tip (NOT against current main) and mergeable only checks for git-level conflicts (NOT mainline drift). Detection recipe: `git merge-base --is-ancestor origin/<head-branch> origin/main` MUST return YES before declaring any 'PR is ready / fix is in flight' verdict. The user wasted 3 days debugging 'the same bug' because dev SHA == main SHA != PR head SHA. Cross-ref: skill `pr-preview-deploy-verification` P11 (the 'I declared PASSED without bundle evidence' trap) — same fabrication pattern, different gate. Anti-pattern codified: 'CI is green, the PR is ready.' CI passing ≠ fix in main."
  - "1.0.0 (2026-08-15): Initial creation. PR #7842 → #8937 worked example (54-day stale PR with agento drift)."
tags: [workflow, pr, replay, cherry-pick, drift, contamination, orphan]
related_skills: [drive-pr-to-green, always-pr-never-local-edit, github-pr-workflow]
---

# pr-cleanup-replay

## Trigger

Load when ANY of these signals fire:

| Signal | Action |
|---|---|
| A PR is open > 30 days with comments / `commits.totalCount` > 5× the diff scope | Suspect drift. Run `git log --first-parent origin/main..HEAD` to verify. |
| CodeRabbit / review is **APPROVED** but the PR is `mergeable: CONFLICTING` and won't rebase | Don't force-push more drift. Replay. |
| Agent-O escalation: "Backfill respawn cap reached for PR #N — 6 prior workers archived" | The cap is the *result* of contaminated history. Replay, don't spawn another worker. |
| `git diff origin/main..HEAD --stat` shows files unrelated to the PR's stated scope (e.g. `.claude/hooks/*`, `.claude/metadata-updater.sh`, `.beads/issues.jsonl`, `fix(ci):`, `chore(beads):`) | Drift. Replay. |
| User's actual PR scope is < 5 files but the PR diff shows > 30 files / +1000 lines | Definitely drift. Replay. |
| The PR's head branch tip is **also the tip of an unrelated feature branch** (shared head, multiple agents converged) | STRONG replay signal. See "Anti-pattern: shared head" below. |
| PR commits are clean and reviewable but the branch point itself is stale (created from an `origin/main` SHA that's now far behind) — `git log origin/main..origin/<head>` shows "Merge remote-tracking branch 'origin/main'" commits OR `git merge-base --is-ancestor origin/main <head-branch-base>` is false AND the diff vs current `origin/main` is small | See "**Variant B — same-PR replay**" below. Same author + clean commits → cherry-pick onto fresh `origin/main` and force-push onto the SAME head branch. PR keeps its number, review history, and CodeRabbit thread. |
| PR targets classes / selectors / DOM hooks that do NOT exist in the served HTML — `git diff origin/main..HEAD` is non-empty, but grep'ing the new selectors (e.g. `.composer-stack`, `.composer-send`) against `mvp_site/frontend_v1/index.html` and the served bundle returns ZERO hits | **Dead-diff variant** — the PR branched from stale `origin/main` BEFORE a refactor (e.g. PR #8952 composer refactor) merged. Diff looks plausible in isolation but matches no element. Close + reopen on fresh `origin/main`. See "**Variant C — dead-diff replay**" below. |
| **PR is `state=OPEN`, `mergeable=MERGEABLE`, all CI checks green, BUT `git merge-base --is-ancestor origin/<head> origin/main` returns NO** (main has moved past the PR's branch point without producing a literal merge conflict) | **Silent-stale-base variant** — CI ran against the PR's own branch (NOT against current main), so it passed vacuously; `mergeable=MERGEABLE` because git sees no conflict, only drift. The fix sits on a branch only; dev Cloud Run SHA == current main SHA == no fix. **Always run `git merge-base --is-ancestor` BEFORE claiming "PR is ready."** See "**Variant F — silent-stale-base rebasable PR**" below. |
| **User reports a deployed-URL symptom and a prior PR with all-CI-green claims to fix that exact symptom, but the fix is NOT visible in dev** | **Run before anything else:** `gcloud run revisions list --service=<dev-service> --region=<r> --project=<p> --limit=1 --format='value(metadata.labels.commit-sha)'` AND `gh pr view <N> --json headRefOid,mergeable`. If dev SHA != PR head SHA AND `merge-base --is-ancestor` returns NO → Variant F (silent-stale-base). The user re-reported PR #9869's bug 3 days later as #9905 because dev never had the fix. |
| **PR is `state=CLOSED` (not `MERGED`), `mergedAt=null`, and the head branch still exists locally** — usually a prior agent's PR that an operator closed without merging because of CI redness / merge conflicts. `gh pr reopen` cannot reset Evidence Gate / Green Gate gists that reference the dead head SHA. | **Closed-not-merged variant** — the head-branch code is still on disk in the prior worktree; the issue is the GitHub PR object's lifecycle state, not the code. **Don't reopen.** Open a FRESH branch off current `origin/main` and re-apply the same code with a clean diff. See "**Variant E — closed-not-merged replay**" below. |

## Rule

**A long-stale PR with contaminated history is not a "rebase and fix" job — it is a clean replay.** Don't add follow-up commits to the polluted branch. Cherry-pick only the in-scope commits to a fresh branch from `origin/main`, close the old PR with a comment pointing to the new one, and open the new PR.

The original PR head is shared with other agents / unrelated feature work. Per the SOUL.md `## COMMIT: pr-clean-branch-from-main-no-history-bloat` and `## COMMIT: never-push-onto-someone-elses-pr-head`, **never push onto a head branch that is not yours** — and a long-stale polluted PR is always someone else's (or many-agent-shared) head.

### Two variants — pick by author + commit shape

Before replaying, check two facts: (1) is the PR author the same as the currently-authenticated `gh auth status` user? (2) is the commit set itself clean (no merge commits, no out-of-scope fixes)?

| Variant | Author vs `gh auth` | Commit shape | End-state |
|---|---|---|---|
| **A — new-PR replay** (default, this skill's main flow below) | Different OR same-but-shared-head | Polluted (merge commits, agento drift, .beads churn) | Cherry-pick into NEW branch → open NEW PR → close OLD PR |
| **B — same-PR replay** (new) | Same AND `maintainer_can_modify=true` | Clean (every commit advances PR scope) — only branch base is stale | Cherry-pick onto fresh `origin/main` → force-push onto SAME head branch → PR keeps its number |

**Variant B is the lesson from PR #8932 (2026-08-15).** Both PR #8932 and its sibling #8936 were trying to fix `progress_percent` fallback on issue #8747. PR #8932 was authored by `${GITHUB_USER}` (same account as `gh auth status`), 4 files / +362/-3, 2 commits where every commit advanced the PR's stated scope. The branch point was stale (54 days behind `origin/main`), but the DIFF was already clean — no pollution, no merge commits, no agento drift. Pushing a sibling PR would have created a duplicate of an identical fix. The correct answer was **cherry-pick the 2 in-scope commits onto fresh `origin/main` and force-push onto `fix/rewards-delivery-custom-curve` (the PR's own head branch)**. The PR keeps its number, CodeRabbit review thread, and `headRefName`. CI re-runs against the new SHA.

**Variant B safety gates (all three MUST pass before force-pushing onto the PR's head branch):**

1. **Same author.** `gh pr view <N> --json user.login` returns a name that matches `gh api user --jq .login`. If different, fall through to Variant A — `never-push-onto-someone-elses-pr-head` violation.
2. **Same account authenticated.** `gh auth status` shows the PR author's account is the active one (`Active account: true`). A different active account means current operator does not own this PR.
3. **Diff is clean.** `git log origin/main..origin/<head> --no-merges` shows ONLY commits whose messages advance the PR's stated scope. Zero `Merge remote-tracking branch`, zero `fix(beads)`, zero `chore:`, zero `fix(ci):`. If ANY of these appear, the commit set IS polluted → use Variant A.

If any gate fails, STOP and pivot to Variant A. The Variant B path is a force-push onto a shared branch — `never-push-onto-someone-elses-pr-head` exists for a reason; same author alone is necessary but not sufficient.

### Variant B — same-PR replay sequence

After all three safety gates pass, execute this 6-step recipe instead of Step 1+ in the main flow below:

1. **Create fresh worktree from `origin/main`** (not from the PR's branch):
   ```bash
   cd /path/to/<repo>
   git fetch origin main
   git worktree add -b fix/<N>-<slug>-variant-b origin/main
   cd <new-worktree-dir>
   git rev-parse HEAD   # MUST equal origin/main SHA
   git status --short   # MUST be clean
   ```

2. **Cherry-pick the in-scope commits in order with `-x`** (same as Step 3 in main flow):
   ```bash
   for sha in <commit-A> <commit-B>; do
     git cherry-pick -x "$sha"
   done
   ```
   The `-x` flag preserves original SHAs in commit bodies for auditable provenance.

3. **Validate locally** (same as Step 4 in main flow): run the targeted test files. The local pytest is the only proof you have that the replay preserves behavior — `git diff origin/main..HEAD` matching the old PR's diff is necessary but not sufficient.

4. **Force-push onto the SAME head branch** (the only step that differs from Variant A):
   ```bash
   git push origin HEAD:refs/heads/<pr-original-head-branch> --force-with-lease
   ```
   `--force-with-lease` not `--force` — protects against concurrent pushes to the same ref. Verify the new SHA is what GitHub now reports on the PR:
   ```bash
   gh pr view <N> --json headRefName,headSha
   ```
   PR head SHA MUST match `git rev-parse HEAD` in the worktree. If they diverge, the push landed somewhere else and the PR is in an inconsistent state — STOP and investigate.

5. **Comment on the PR** with a one-line note explaining the replay (do NOT close the PR — that's Variant A):
   ```bash
   gh pr comment <N> --body "Clean replay of this PR's commits onto fresh origin/main@<sha>. Original head 5cbff868 → new head <new-sha>. Diff vs main unchanged. Cherry-picks used \`-x\` for provenance."
   ```

6. **Verify CI re-runs against new SHA**:
   ```bash
   gh pr checks <N>
   ```
   Job trigger is automatic on push; if no new runs appear within 60s, the workflow may filter by file paths — confirm with `gh workflow list` and look for `pull_request` triggers without `paths` filters.

**Why Variant B preserves review context:** PR #8932's CodeRabbit thread, any user comments, the `headRefName` in any external dashboards (Hermes agento cron, babysit jobs pointing at the PR), and any in-flight `/er` evidence reviews all reference the PR NUMBER, not the branch SHA. Force-pushing onto the same branch keeps all of those valid. Variant A abandons them — anyone watching the old PR has to update their bookmarks.

**When Variant B is wrong even with clean commits:** If the PR has been forked into downstream tooling (e.g. another team has shipped a patch derived from the old head), Variant A's "close + replace" gives them a heads-up. Variant B silently changes the head. Default to Variant A when in doubt — preserving the PR number is a benefit, not a guarantee.

### Variant D — lost-PR replay (original commit was never merged, and mainline already refactored the same file)

A separate replay variant seen on issue #9057 / PR #9058 (jleechanorg/worldarchitect.ai, 2026-08-18). The failure mode is **invisible to standard PR-cleanup signals** because there is no open PR to inspect:

- The original fix lived ONLY on a branch that never reached `main` (`fix/narrative-response-schema-required-9021`, head `098ca8316d`). No PR was ever opened against `main`. Verified with `git merge-base --is-ancestor 098ca8316d origin/main` → exit 1.
- Meanwhile, an unrelated PR (here #9045) landed on `origin/main` and refactored lines 396-510 of the SAME file the original fix touched. The unrelated PR removed a ~100-line block that contained a fallback example the original fix was relying on. So the original fix is no longer a "self-contained" replay — its work overlaps with a refactor that already shipped.

This is **not** Variant A (no polluted branch to discard) and **not** Variant B (no open PR head to preserve). It is its own variant because:

- `gh pr view <N>` returns 404 for the original commit's branch — there's nothing to close.
- The "conflict" is not a git merge conflict at all — git will auto-merge cleanly because the unrelated refactor touched lines far away from the schema section at the top. The semantic conflict (intent drift between the two changes) is what matters.

**Detection recipe (run BEFORE cherry-picking any fix onto `origin/main` that was authored before a recent mainline refactor):**

```bash
# 1. Confirm the original commit is NOT an ancestor of origin/main
git merge-base --is-ancestor <orig-sha> origin/main && echo "MERGED" || echo "LOST"
# LOST = candidate for Variant D

# 2. Find files touched by the original commit and check their recent history on main
git show <orig-sha> --stat --name-only
for f in $(git show <orig-sha> --name-only --format=""); do
  echo "=== $f ==="
  git log --oneline origin/main -5 -- "$f"
done
# If the file has had a refactor commit on main since <orig-sha>, this is Variant D

# 3. Check whether the PR refactor and the lost fix overlap on intent
gh pr view <refactor-PR> --json files,title,body --jq '.title, (.files | map(.path))'
```

**Variant D sequence (cherry-pick + extend the surviving refactor):**

1. **Branch fresh from current `origin/main`** (same as Variant A Step 2).
2. **Cherry-pick the original commit with `-x`**: usually lands cleanly because the schema section was inserted at the TOP of the file (lines 1-75), and the mainline refactor targeted lines 396-510 — far enough apart that git's three-way merge resolves without manual intervention. Confirm with `git show HEAD --stat` that all 3 of the original commit's files are present (the test file, the lint script, and the prompt file).
3. **Verify tests + lint green** on the cherry-pick alone. This catches the case where the cherry-pick's intent depended on prose that the mainline refactor deleted.
4. **Extend the surviving refactor's stub** with the missing intent. In #9057 / #9058, the mainline refactor's `**⚠️ DICE RESOLUTION & UI DISPLAY:**` stub (3 lines) explicitly told the LLM "you do not need to populate `action_resolution.mechanics.rolls`" — which is what the regression symptom was. The fix added ONE new sentence to that stub re-emphasizing that `action_resolution` itself MUST still be emitted. The line count: 1 addition. The semantic restore: `action_resolution` re-anchored at the point where the LLM reads the "code_execution handles it" message.
5. **Squash cherry-pick + extension into ONE commit** before pushing — see the "Squash recipe" section below for why two separate commits here is wrong.
6. **Push + open PR** as in Variant A Step 7.

**Squash recipe (cherry-pick + follow-up edit → single coherent commit):**

The naive sequence is `git cherry-pick <sha>` then `git commit -am "extend stub"` — which leaves two separate commits where the second one (the extension) has 1 insertion and the first (the cherry-pick) has 70. From the PR's perspective, the second commit looks like drive-by noise. Squash into one commit that describes the *outcome*:

```bash
# After cherry-pick AND follow-up edit are both uncommitted:
git add -A && git commit -m "<single accurate message>"

# OR, if you already committed them separately and the branch is local-only:
git reset --mixed HEAD~N   # N = number of fix commits to collapse
git add -A && git commit -m "<single accurate message>"
```

**Pitfall — soft-reset only replays the LAST commit's staging:** `git reset --soft HEAD~1` followed by `git commit` produces a new commit whose diff equals ONLY the previous commit's diff (the latest staging), not the cumulative diff vs `origin/main`. If you ran two `git reset --soft HEAD~1` operations in a row thinking you were accumulating staging, you actually replayed the latest commit each time. Use `--mixed` (or just leave files uncommitted), `git add -A`, then commit once.

**Pitfall — don't open TWO PRs for the cherry-pick and the extension.** Some agents will push the cherry-pick branch as PR #1, see CI go red, then push the extension as a follow-up commit on a new branch as PR #2. This produces two review threads, two CI runs, and the same regression audit twice. Squash first, then push once.

**Anti-pattern — "the cherry-pick is the fix; the extension is optional."** If the regression was caused by the mainline refactor's stub misleading the LLM, then the extension is NOT optional. Without it, the LLM still gets the "you do not need to populate `action_resolution.mechanics.rolls`" message with no counter-anchor, and emits the same broken response. The extension is the actual fix to the regression; the cherry-pick is just the precondition. Name the commit accordingly.

### Variant C — dead-diff replay (PR branched before its target classes existed)

A new failure mode seen on PR #8996 (closed draft, jleechanorg/worldarchitect.ai, 2026-08-17): the PR's `git diff origin/main..HEAD` was non-empty, reviewable in isolation, and CodeRabbit-skipped only because the PR was a draft — but every selector it added (`.composer-stack`, `.composer-send`, `.composer-row`, `.composer-choices`) was added by an earlier refactor (PR #8952) that landed on `origin/main` AFTER the fix branch was cut. So the diff was **dead CSS targeting DOM hooks that didn't exist yet**. The deploy preview would have served the rules, but no element matched, so the visual bug the rules tried to fix stayed unchanged. The worker reported "fixed" without verifying against the served page.

This is **not** a Variant A replay (commits are clean — no merge commits, no drift) and **not** a Variant B replay (the PR has nothing to preserve — the diff is functionally inert). It is its own variant because the failure mode is invisible to all the standard PR-cleanup checks:

- `git log --first-parent origin/main..origin/<head>` shows clean commits advancing the PR's stated scope — passes Step 0.
- `git diff origin/main..HEAD --stat` shows the intended files only — passes Step 0.
- `gh pr view --json reviewDecision` is empty (no review yet, because draft) — passes Step 2.
- CodeRabbit skipped review because of `isDraft: true` — review passes vacuously.

The only check that catches it: **do the new selectors match any element in the CURRENT served HTML** (or current `origin/main`'s `index.html` / served bundle). If not, the entire diff is dead.

**Detection recipe (run BEFORE opening or approving any UI/CSS PR):**

```bash
# 1. Get the PR's added selectors (rough heuristic: lines that look like CSS selectors)
gh pr diff <N> --repo <owner>/<repo> \
  | grep -E '^\+\s*\.[a-z][a-z0-9_-]+[\s,{]' \
  | sed -E 's/^\+\s*\.([a-z][a-z0-9_-]+).*/\1/' \
  | sort -u > /tmp/pr-new-selectors.txt

# 2. Grep current origin/main's served HTML/JS for each selector
git show origin/main:<entry-html-or-js-path> > /tmp/served.html
while read sel; do
  if ! grep -qE "\\.${sel}[^a-z0-9_-]" /tmp/served.html; then
    echo "DEAD SELECTOR: .${sel} — not in origin/main's served HTML"
  fi
done < /tmp/pr-new-selectors.txt
```

A non-zero exit on the per-selector grep means the selector has no matching element. Three or more dead selectors in one PR = almost certainly branched before a refactor. The fix is **Variant C — close the dead PR, branch fresh from current `origin/main`, and re-add the same rules onto the markup that now exists.**

**Variant C sequence (close + new-branch + re-apply):**

1. **Confirm the diagnosis is real**, not just an incomplete index scan:
   ```bash
   # Pull the CURRENT served HTML from the deploy preview (not local main —
   # local main may be stale if the operator hasn't `git fetch`ed recently)
   curl -s https://<deploy-preview>.run.app/ | grep -c "composer-stack"
   # If 0, the deploy env is ALSO stale — wait for the prior refactor's
   # deploy to roll out, then re-check.
   ```

2. **Close the dead PR with a one-line explanation** that names the missing class:
   ```bash
   gh pr close <N> --repo <owner>/<repo> --delete-branch \
     --comment "Closing: this PR branched from stale origin/main before \
   PR #<refactor> (<refactor title>) merged. The diff targets \
   .<class-1>, .<class-2>, .<class-3> — none of which exist in the \
   current origin/main markup. Reopening on a fresh branch."
   ```

3. **Branch fresh from current `origin/main`** (the standard replay Step 2):
   ```bash
   git fetch origin main
   git worktree add -b fix/<slug>-on-refactored-origin origin/main
   cd <new-worktree-dir>
   ```

4. **Re-apply the same fix**, this time onto markup that contains the target classes. The diff will be smaller — usually just the new `@media` block — because the markup refactor (composer-*) and the CSS scaffolding are already on `origin/main`.

5. **Verify before pushing**: re-run the selector-grep against the LOCAL `index.html` to confirm `.composer-stack` etc. now exist:
   ```bash
   grep -c 'composer-stack\|composer-send\|composer-row\|composer-choices' \
     mvp_site/frontend_v1/index.html
   # Expect: > 0
   ```

6. **Open the new PR** with a body that explicitly cites the closure reason of the dead PR — reviewers need to know this was attempted before:
   ```markdown
   ## Why this is a new PR

   Draft <https://github.com/.../pull/<N>|PR #<N>> added the same CSS rules but
   branched from stale `origin/main` before <https://github.com/.../pull/<refactor>|PR #<refactor>>
   (the <refactor title>) merged. So every selector in that PR
   (`.composer-stack`, `.composer-send`, `.composer-row`, `.composer-choices`)
   had zero matching elements in the deployed HTML. PR #<N> has been closed.

   This PR is rebased on current `origin/main` (<sha>) where the markup
   includes the composer refactor, so the rules now match real elements.

   Originally <dead-pr-head-sha>: <dead pr title>.
   ```

**Anti-patterns specific to Variant C:**

- **"Just un-draft the old PR and merge it"** — the diff has zero visible effect because the selectors are dead. Reviewers can't catch this from the diff alone.
- **"Trust the deploy preview URL after the PR is open"** — the deploy preview rebuilds from the PR's branch, but the **HTML** served is still the one bundled with the deploy image, not the PR's. If the PR's branch and the deploy image's bundled HTML disagree (because the deploy image was built from a different SHA), the deploy preview URL may serve PR's CSS rules but the *markup* from an older image — or vice versa. Always check `view-source` on the deploy preview URL and grep for the new selectors there, not in your local worktree.
- **"Add the markup classes to the PR too"** — if the dead PR also added markup for the same feature, expanding the PR to include both markup and CSS is fine. But that's a different PR (you're re-landing the missing refactor). For the case in PR #8996, the refactor (#8952) was ALREADY merged — the dead PR should have been based on it.

**Lesson source:** Slack `C0BDEAJH8PK/p1786958669.427289` (mobile composer bug, 2026-08-17). Worker opened draft PR #8996 with 245 lines of dead CSS, reported "Fixed" in Slack without deploying or visually verifying, was caught when I diff'd the local-vs-deployed `planning-blocks.css` and found 168-line local vs 375-line deployed — and `composer-*` was missing entirely from local `index.html`. Reopened as PR #8997 on fresh `origin/main` (HEAD `6327098042`), 51-line mobile-only `@media` block, single file, all selectors now match real markup.

### Variant E — closed-not-merged replay (PR closed without merge; replay onto fresh origin/main)

A new failure mode seen on PRs #9166 / #9167 (jleechanorg/worldarchitect.ai, closed 2026-08-22): the prior PRs were closed by an operator (or self-closed by stale `pr_ready_checklist.sh` runs) BEFORE merging, usually because of `isDraft` toggling + failing Evidence Gate / Green Gate / merge conflicts. The head branch still exists locally in `_wt/feat-<slug>/` worktrees; the code is correct; the issue is purely the GitHub PR object's lifecycle state.

**Why `gh pr reopen` is wrong here:**

- Evidence Gate `FAILURE` references a gist SHA bound to the closed PR's head commit. Reopening does NOT re-evaluate Evidence Gate against the same dead SHA — it stays FAIL.
- Green Gate may also be stale (decision rendered against the closed PR's diff).
- Even if all 8 readiness gates pass after reopen, the diff stat is inflated against the closed PR's merge-base — reviewers see a noisy diff with hundreds of unrelated files from agento drift that accumulated since the PR was originally cut.
- The operator's prior "close" is a signal. Reopening without explicit operator permission is the `## COMMIT: never-push-onto-someone-elses-pr-head` analog for closed PRs.

**Why this is a Variant and not "just open a new PR":**

- The prior worktree (`_wt/feat-<slug>/`) still has the working code with the right logic. You don't have to rediscover what the right changes were — they're on disk.
- The merged main has moved past the prior PR's base SHA. Cherry-picking the prior commits onto current `origin/main` may conflict (especially if the file has been refactored since). Easier to re-apply the focused diff directly.
- The same `[skill-name]:` provenance tag belongs in the new commit message so the SOUL.md audit log can trace "this was a closed-not-merged replay of N".

**Detection recipe (run BEFORE deciding reopen vs fresh-branch):**

```bash
# 1. Confirm state
gh pr view <N> --json state,mergedAt,closedAt,headRefName,headRefOid
# state="CLOSED", mergedAt=null, closedAt=<recent> → Variant E

# 2. Confirm the head branch still exists locally with code on disk
git branch --list 'feat/<slug>' 'fix/<slug>' '<branch-name>'
git worktree list | grep -F '<branch-name>'

# 3. Confirm the prior diff was clean (not 1000+ files of drift)
git -C <path-to-worktree> diff --shortstat origin/main..HEAD

# 4. Confirm no force-push will salvage the original PR — check what Evidence Gate references
gh pr view <N> --json statusCheckRollup --jq '.[] | select(.name | test("Evidence Gate|Green Gate")) | {name, conclusion, detailsUrl}'
```

If (1) is CLOSED+mergedAt=null, (2) shows the worktree + branch intact, (3) shows a focused diff (≤10 files / ≤500 lines), and (4) shows Evidence Gate FAILURE referencing a gist SHA — **use Variant E, not reopen**.

**Variant E sequence (re-apply focused diff onto fresh origin/main):**

1. **Create a fresh worktree from current `origin/main`** (NOT from the closed PR's branch):
   ```bash
   cd /path/to/<repo>
   git fetch origin main
   git worktree add -b <scope>/<slug>-v2 origin/main   # append "-v2" to disambiguate from the closed branch
   cd <new-worktree-dir>
   git rev-parse HEAD   # MUST equal origin/main SHA
   git status --short   # MUST be clean
   ```

2. **Read the prior worktree's diff against ITS origin/main, not yours.** The closed PR's branch was cut from a stale `origin/main` SHA. The diff you want is the diff against THAT old base, filtered for focused in-scope files only:
   ```bash
   # In the prior worktree (closed PR's branch)
   cd <path-to-prior-worktree>
   PRIOR_BASE=$(git merge-base HEAD origin/main)   # last common ancestor
   git diff --stat $PRIOR_BASE..HEAD

   # Filter to focused files only — drop any .beads/, .claude/, scripts/, drift files
   ```

3. **Re-apply the focused changes** to the new worktree. **Do NOT cherry-pick the prior commits** — they were authored against a stale base. Copy the hunks by hand from the prior diff, OR use `git show <sha> -- <file> | git apply` for individual files. Prefer the by-hand approach: cherry-picking pollutes the new branch with merge commits against mainline drift.

4. **Run the same targeted tests locally** that the closed PR's PR body claimed pass. They MUST pass on the fresh branch, otherwise the diff had a stale-base dependency that needs human review.

5. **Commit with provenance tag** pointing at the closed PR:
   ```bash
   git add -A
   git -c user.name="<cli>/<model>" commit -m "<cli>/<model-id>: <scope>(<area>): <accurate short description>

   Replaces closed PR #<N>. The closed PR's Evidence Gate referenced a gist SHA
   bound to the now-dead head; reopening does not re-evaluate. Re-applied the
   focused diff against current origin/main @ <sha>.

   Originally <closed-pr-head-sha>: <original first line>."
   ```

6. **Push the fresh branch and open the PR**:
   ```bash
   git push origin HEAD:refs/heads/<scope>/<slug>-v2
   gh pr create --base main --head <scope>/<slug>-v2 \
     --title "<original PR title> (v2)" \
     --body "<see template below>"
   ```

   **PR body template**:
   ```markdown
   ## Why this is a new PR (closed-not-merged replay)

   Closed <https://github.com/.../pull/<N>|PR #<N>> had Evidence Gate / Green Gate
   FAILURE tied to a gist SHA from its head commit. Reopening cannot reset the
   stale gate references. Re-applied the focused diff against current
   `origin/main` (<sha>) on branch `<scope>/<slug>-v2`.

   Originally <closed-pr-head-sha>: <closed PR title>.

   ## Diff vs current origin/main

   <N> files, +<a>-<d> lines (same scope as the closed PR's last code shape):
   - <file-1>: <one-line change summary>
   - <file-2>: <one-line change summary>

   ## Verification

   - <test-file-1>: N/N pass
   - <test-file-2>: N/N pass
   ```

7. **Comment on the closed PR** (do NOT reopen):
   ```bash
   gh pr comment <N> --body "Closed in favor of fresh-branch replay PR #<NEW-N>. \
   The original PR's Evidence Gate referenced a gist SHA from its dead head; \
   reopening cannot re-evaluate. PR #<NEW-N> contains the same scope re-applied \
   against current origin/main @ <sha>."
   ```

8. **Verify the fresh PR**:
   ```bash
   bash ~/.smartclaw/scripts/pr_ready_checklist.sh <NEW-N> <OWNER/REPO>
   # ALL gates must PASS before any "ready" claim (per `pr-ready-checklist` skill)
   ```

**Anti-patterns specific to Variant E:**

- **"Just `gh pr reopen` and wait for CI"** — Evidence Gate FAILURE persists because the gist SHA is dead; reopening does not regenerate the gist.
- **"Force-push onto the closed PR's head branch and `gh pr reopen`"** — combines two SOUL violations (`never-push-onto-someone-elses-pr-head` + reopening a closed PR without operator signal).
- **"Cherry-pick the prior commits"** — they were authored against a stale base; cherry-pick may conflict or, worse, succeed but inject merge commits against mainline drift that pollute the diff.
- **"Open a brand-new PR with a different approach"** — if the prior code was correct (just on a dead branch), reuse it; the operator doesn't need a third attempt at the same feature.
- **"Skip the 8-gate readiness check because the original PR 'passed' it"** — the original PR's readiness state is irrelevant; the new PR has its own SHA, its own Evidence Gate gist, its own CodeRabbit review, its own merge-base against current origin/main. Re-run the script.

**Lesson source:** PRs #9166 (AGY Low thinking opt-in) and #9167 (Gemini direct-API Low thinking) closed 2026-08-22 02:52:33Z and 02:37:44Z respectively. Both had `isDraft: true` + Evidence Gate FAILURE referencing gist SHAs from their respective heads. Reopening was tempting (the work was correct) but the gate references were structurally dead. Replay: opened fresh branches `feat/agy-low-thinking-v2` (HEAD `1bbce598ba`) and `feat/gemini-thinking-low-v2` (HEAD `f30f269695`) off `origin/main @ 528ddd5147`. Diff: 2 files / +57/-7 and 2 files / +452/-5 respectively. Unit tests 94/94 (agy) and 180/181 (gemini_provider_* suite) green. New PRs #9242 and #9243 opened with the same gate compliance — operator can now merge them as soon as CI drains.

### Variant F — silent-stale-base rebasable PR (PR is OPEN + CI green, fix is NOT on main)

A new failure mode seen on PR #9874 (`fix/world-logic-reducer-mask-9869`, jleechanorg/worldarchitect.ai, 2026-09-13 → 2026-09-16). The PR was authored against merge-base `816abce06f4`; main has moved 16+ commits forward to `41720ad55a7`. The smoking-gun is **silent**:

- `gh pr view <N> --json mergeable` returned `"MERGEABLE"` — no literal conflict, only drift.
- All 8 CI checks (`Green Gate`, `Design Doc Grep Gates`, `Deploy PR Preview`, `WorldArchitect Tests (Directory-Based)`, `Presubmit Checks`, `MVP Shards`, `limit-pr-runs`) were `SUCCESS`. **CI runs against the PR's own branch tip, NOT against current main.** A stale-base PR can pass every check without ever touching current main's code.
- Dev Cloud Run SHA matched current main (`41720ad55a7`), so dev never had the fix.
- User assumed "PR is OPEN with green CI → fix is in flight" — but the fix was only on the branch.

The user reported the bug class on 2026-09-13 (issue #9869), the PR was filed 4 hours later (`f25cc041338`), all CI green by 20:28Z. The user then re-reported the **same bug class** on 2026-09-16 (issue #9905, on a 2nd campaign) — 3 days later — because dev still didn't have the fix. The PR had been silently-stale the whole time.

**Why this is a NEW variant (not covered by A/B/C/D/E):**

- A — polluted with merge commits/drift: **NO**. PR #9874's single commit was clean (`fix(world_logic): ...`, scope was exactly the smoking-gun code).
- B — same-PR rebasable, clean commits, same author: **YES structurally** but the lesson is different — the failure was that nobody *checked* ancestry before treating the green PR as "ready."
- C — dead-diff (selectors don't exist): **NO**. The diff targets real code that does exist.
- D — lost-PR (never merged, file refactored): **NO**. The PR is open and mergeable.
- E — closed-not-merged: **NO**. PR is OPEN.

The distinguishing feature is: **the agent/operator trusted `mergeable=MERGEABLE` + all-CI-green as "ready to merge"** without ever verifying that the branch is an ancestor of main. The CI gate does NOT include "is this branch reachable from main?"

**Detection recipe — run BEFORE declaring any "PR is ready / fix is in flight" verdict:**

```bash
# The single check that catches silent-stale-base:
ANCESTOR=$(git merge-base --is-ancestor origin/<head-branch> origin/main && echo YES || echo NO)
echo "PR #<N> head branch ancestor of origin/main? $ANCESTOR"

# If NO, the fix is on a branch only — main has moved on.
# Cross-check against the deployed environment:
DEV_SHA=$(gcloud run revisions list \
  --service=mvp-site-app-dev \
  --region=us-central1 \
  --project=worldarchitecture-ai \
  --limit=1 --format='value(metadata.labels.commit-sha)' 2>/dev/null)
echo "Dev SHA: $DEV_SHA"
echo "Main HEAD: $(git rev-parse --short origin/main)"
# If dev SHA == main SHA AND main SHA != PR head SHA, dev never had the fix.
```

**Three signals that COMBINED indicate silent-stale-base:**

1. `mergeable=MERGEABLE` (so the operator thinks it's ready)
2. All CI green (so the operator trusts the merge)
3. `git merge-base --is-ancestor origin/<head> origin/main` returns NO (the catch)

Any ONE of (1) or (2) is *necessary but not sufficient* for "fix is in flight." (3) is the only one that confirms mainline containment.

**Variant F sequence — same as Variant B but with the explicit stale-base caveat:**

1. **Confirm the PR's commits are clean** (no merge commits, all in-scope). If polluted → pivot to Variant A. The silent-stale-base fix for #9874 was a single clean commit (`f25cc041338`) targeting 6 lines in `world_logic.py` + a 149-line contract test — the cleanest possible case.
2. **Create worktree from `origin/main` (NOT from the PR's branch)** — pull the PR's branch last so `git log origin/main..origin/<head>` shows the diff:
   ```bash
   git fetch origin main <head-branch>
   git worktree add -b fix/rebase-<N> origin/main
   cd fix/rebase-<N>
   git log --oneline origin/main..origin/<head-branch>
   # Confirm: every commit advances PR scope, zero merge commits.
   ```
3. **Run `git rebase origin/main` ON THE PR's branch inside the worktree** (the cleanest path is to checkout the PR's branch then rebase, NOT to cherry-pick — preserves commit shape + SHA provenance):
   ```bash
   git fetch origin <head-branch>
   git checkout -B <head-branch> origin/<head-branch>
   git rebase origin/main
   ```
4. **Verify the diff against current `origin/main` is unchanged** (`git diff origin/main..HEAD --stat` should match the pre-rebase line count). A different line count = main drifted through the same files the PR touched = conflicts to resolve manually.
5. **Run the PR's contract tests** from the rebased branch. They MUST pass on current main (not just the PR's stale base).
6. **Force-push onto the SAME head branch** with `--force-with-lease`:
   ```bash
   git push --force-with-lease origin HEAD:refs/heads/<head-branch>
   ```
7. **Verify the new SHA matches what GH reports on the PR**:
   ```bash
   gh pr view <N> --json headRefOid
   ```
8. **Verify CI re-runs** (`gh pr checks <N>` shows new run IDs from the post-rebase SHA — old run IDs are stale).
9. **Comment on the PR** with a one-line stale-base-rebase note (so reviewers understand why the SHA moved but the diff didn't):
   ```bash
   gh pr comment <N> --body "Stale-base rebase onto current origin/main @ <new-sha>. Original head <old-sha> branched from <old-base-sha>; main has moved 16+ commits since. Diff vs main unchanged at <N> files / +<a>-<d>. CI re-running."
   ```

**Anti-patterns specific to Variant F:**

- **"CI is green, the PR is ready."** CI passing ≠ fix in main. CI runs against the PR's branch tip; if main moved on, the CI result is from the wrong baseline.
- **"`mergeable=MERGEABLE` means safe to merge."** Mergeable = no git-level conflict. It does NOT equal "the diff is what we think it is against current main." A stale-base PR can be MERGEABLE with a 30-day-old mainline drift between its base and current main.
- **"Just merge it and see what breaks."** This is the exact anti-pattern that wastes cycles — silent-stale-base PRs can merge cleanly into a now-drifted main and silently roll back fixes that landed between PR-base and merge-time.
- **"Open a duplicate PR."** Don't. Use Variant F's same-branch force-push — the PR keeps its number, review thread, CodeRabbit history, and any babysit/cron that targets it.
- **"Close the stale-base PR without rebasing."** Closing leaves the original bug unfixed. Rebase first, then verify CI, THEN ask for merge approval.

**Lesson source:** PR #9874 (`fix/world-logic-reducer-mask-9869`), jleechanorg/worldarchitect.ai, 2026-09-13 → 2026-09-16. Authored at merge-base `816abce06f4` against an old base SHA; main moved to `41720ad55a7` via 16+ commits including PR #9384 (combat NPC statuses) and the state-primary-matrix-20260914 merge. PR #9874's CI was green at 20:28Z on Sep 13; user re-reported the bug class on Sep 16 as issue #9905 (campaign `FOpeODbNVKzcYB22JBkg`). Root cause: dev Cloud Run SHA = `41720ad55a7` (current main) ≠ `f25cc041338` (PR head). User frustration quote: "Thought we already had a PR if not make one also look the session header state still wrong why can't god mode see it." Detection: `git merge-base --is-ancestor origin/fix/world-logic-reducer-mask-9869 origin/main` returned NO. Fix: rebased onto current main HEAD `41720ad55a7` → new head `66c72ab367f`, force-pushed, CI re-queued. All 3 contract tests green on the rebased branch.

**Discipline update — added to AGENTS.md / SOUL.md workflow:** for any "PR is ready" verdict on a `jleechanorg/*` repo, the agent MUST verify `git merge-base --is-ancestor origin/<head> origin/main` returns YES before claiming the fix is in flight. Without this gate, the user wastes 3+ days debugging the "same" bug that the PR was supposed to fix. The check is sub-second and catches a class of silent failures that the standard `mergeable + ci-green` heuristics both miss.

## The full sequence (execute in order, no pauses)

### Step 0 — Diagnose the drift

Before any work, confirm the diagnosis with three commands:

```bash
# 1. Confirm the PR is in concept-good shape (reviewer approved, no real blockers)
gh pr view <N> --repo <owner>/<repo> --json reviewDecision,mergeStateStatus,statusCheckRollup,additions,changedFiles,commits

# 2. Show the first-parent-only commit list — this is the operator's "story" of the PR
git fetch origin <head-branch>
git log --first-parent origin/main..origin/<head-branch> --oneline

# 3. Diff vs origin/main to see the actual file scope
git diff origin/main..origin/<head-branch> --stat
```

If the first-parent log shows commits like `Merge remote-tracking branch 'origin/main' into ...`, `[fixpr codex-automation-commit]`, `fix(beads)`, `fix(ci):`, or `chore:` mixed in with the real feature commits, the branch is **polluted** and you must replay.

### Step 1 — Identify the IN-SCOPE commits

Inspect each commit:

```bash
git log origin/main..origin/<head-branch> --oneline --no-merges
```

For each commit, ask: "Does this commit advance the PR's stated scope?" Use the PR's title/body as the source of truth.

**Common OUT-OF-SCOPE commit patterns to drop:**

- `Merge remote-tracking branch 'origin/main' into ...` — merge commits that pumped in mainline drift
- `[fixpr codex-automation-commit] ...` — agento-driven mechanical fixes from prior spawns
- `fix(beads): remove duplicate bead ...` / `.beads/issues.jsonl` — beads bookkeeping
- `fix(ci): ...` / `ci(workflow): ...` — CI plumbing unrelated to the PR
- `chore: ...` / `style: ...` — formatting churn
- Anything touching `.claude/hooks/*`, `.claude/commands/*`, `.claude/metadata-updater.sh`, `.claude/activity-updater.sh`, `.claude/settings.json` — agento tooling drift
- `fix(rewards): ...` / `fix(level-up): ...` etc. when the PR is about a different feature

**CRITICAL coupling pitfall (the lesson from PR #7842 → #8937, 2026-08-15):** A "fix" commit may *call* a helper that was added by a separate "refactor" commit. If the refactor is out-of-scope, you cannot keep the fix — the helper won't exist on `origin/main`. Check coupling BEFORE cherry-picking:

```bash
# For each candidate fix commit, check what symbols it CALLS
git show <fix-sha> -- <file> | grep -E '^\+\s*[a-zA-Z_]+\(' | grep -v 'def ' | grep -v 'class '

# For each out-of-scope refactor commit, list the symbols it DEFINES
git log --all --oneline -S '<helper_name>' -- <file>
```

If symbol `foo` is defined in commit A (out-of-scope refactor) and called in commit B (in-scope fix), you have three options:
1. **Include both A and B** — extends PR scope, but the code is consistent
2. **Drop both A and B AND any tests that asserted on A's behavior** — strict-scoped, requires test surgery
3. **(NEVER) Include only B** — `NameError: name 'foo' is not defined` at import time, every test that exercises the helper-call path will fail
   
   Real failure mode (PR #7842): cherry-picked `4f82af582d` which called `_apply_terminal_cleanup_to_patch`. The helper was defined in `dd3b5f801e` (out-of-scope refactor). `test_projector_for_complete_session_emits_no_offer` failed with `NameError: _apply_terminal_cleanup_to_patch is not defined`. Caught only because the test was run locally.

### Step 2 — Create a fresh worktree from origin/main

NEVER rebase. NEVER amend the polluted branch. Always new worktree:

```bash
cd /path/to/<repo>
git fetch origin main
git worktree add -b fix/<N>-<slug>-clean-replay origin/main
cd <new-worktree-dir>
git rev-parse HEAD   # MUST equal origin/main SHA
git status --short   # MUST be clean
```

The worktree at `${HOME}/repos/<repo>/origin/main` is the canonical path pattern from this skill (mirrors the `git worktree add … origin/main` recipe).

### Step 3 — Cherry-pick the in-scope commits IN ORDER with `-x`

```bash
for sha in <commit-A> <commit-B> <commit-C> <commit-D>; do
  git cherry-pick -x "$sha" || break
done
```

The `-x` flag preserves the original commit SHA in the message body so provenance is auditable.

**If a cherry-pick conflicts:**
1. Read the conflict. The 54-days-of-mainline-drift case is the most common conflict source.
2. Resolve preserving the cherry-pick's INTENT (the structural change), not the original line-by-line text.
3. `git checkout --ours <file>` for files that don't need the cherry-pick's version (e.g. `.beads/issues.jsonl` if the cherry-pick only removes a duplicate that's already gone on main).
4. `git add <resolved-files>` then `git -c core.editor=true cherry-pick --continue`.

**If a helper-call conflict surfaces (the same helper was added by a now-dropped commit):**
- Option 1 (include the refactor commit): `git cherry-pick -x <refactor-sha>` on its own, resolve any conflicts, then `git cherry-pick --continue <fix-sha>`.
- Option 2 (drop the fix and its dependent tests): `git cherry-pick --abort`, then `git show <fix-sha> -- <file>` to manually extract ONLY the in-scope pieces (e.g. test additions that don't depend on the helper).

### Step 4 — Validate locally

Run the targeted tests that exercise the cherry-picked code:

```bash
./run_tests.sh <test-file-1> <test-file-2>
```

If a test fails with `NameError: name 'X' is not defined`, you have a coupling pitfall (Step 1). Catch it HERE before pushing, not after.

### Step 5 — Amend the cherry-pick messages to be accurate

A cherry-pick of `4f82af582d "[fixpr codex-automation-commit] fix PR #7842"` may only contain 2 of the 5 files from the original commit. The commit message lies. Fix it:

```bash
git -c core.editor=true commit --amend -m "test(<scope>): <accurate short description> (clean replay from <orig-sha>)

Cherry-picked <in-scope-pieces> from <orig-sha>. Dropped the <out-of-scope-pieces>
because <reason: separate refactor / out of scope / drift content>.

Originally <orig-sha>: <original first line>"
```

This keeps the `-x` provenance trail in the body while making the actual content of the commit audit-honest.

### Step 6 — Push the fresh branch

```bash
git push -u origin fix/<N>-<slug>-clean-replay
```

### Step 7 — Open the new PR

```bash
# REST is more reliable than GraphQL here when rate limits are tight
gh api -X POST repos/<owner>/<repo>/pulls \
  -H "Accept: application/vnd.github+json" \
  -f title="[agento] <original PR title> — clean replay" \
  -f head="fix/<N>-<slug>-clean-replay" \
  -f base="main" \
  -f body="<see template below>"
```

**PR body template (clear, reproducible, admits the cause):**

```markdown
## Clean replay of PR #<N>

PR #<N> had <N> commits polluted with <duration> of unrelated agento drift (`<examples>`). This is a CLEAN replay from `origin/main` with only the <N> in-scope commits:

- <sha> <original subject>
- <sha> <original subject>
- ...

Per the SOUL.md `pr-clean-branch-from-main-no-history-bloat` and `never-push-onto-someone-elses-pr-head` commits — the original PR #<N> head is shared with multiple agents and cannot be cleanly updated.

**Diff vs origin/main:** <N> files, +<a>-<d> lines
- <file-1>
- <file-2>

**Tested locally:** <test-name-1>, <test-name-2>, <test-name-3> all pass.

**Out of scope (NOT included from the original PR):**
- <out-of-scope-commit-sha> <reason>
- <out-of-scope-commit-sha> <reason>

Closes #<N>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

### Step 8 — Comment on the old PR + close it

```bash
gh api -X POST repos/<owner>/<repo>/issues/<N>/comments \
  -f body="Closing in favor of clean replay PR #<NEW-N> — original PR #<N> head was polluted with <duration> of unrelated agento drift (<N> non-<scope> commits: <examples>). PR #<NEW-N> contains only the <N> in-scope commits (+<a>-<d> across <N> files), tested locally, <reviewer> approval ported over."

gh api -X PATCH repos/<owner>/<repo>/pulls/<N> \
  -f state="closed"
```

**Do NOT** use `Closes #N` in the new PR body if the old PR is still open — `gh api -X PATCH ... state="closed"` will move the auto-closing reference to the closed PR. Close the old PR AFTER the new PR is open, then the chain resolves cleanly.

### Step 9 — Verify and report

```bash
gh api repos/<owner>/<repo>/pulls/<NEW-N> --jq '{number,state,title,head:.head.ref,base:.base.ref,mergeable,additions,changed_files,url}'
gh api repos/<owner>/<repo>/pulls/<N> --jq '{number,state,closed_at,merged_at}'
```

**Heads-up on the PR diff:** GitHub shows `additions` / `changed_files` based on the 3-dot diff (merge-base to HEAD). When origin/main has moved past your branch point, the diff will inflate to include unrelated drift between the branch point and current main. This is harmless — the actual PR diff is what you pushed. It will compress to the real numbers once merged.

## Anti-patterns (DO NOT do these)

- **"Just rebase the polluted branch"** — a polluted branch has 24+ commits of mixed provenance. Rebase rewrites them but they're still there. The audit story is broken. Plus, the head is shared with other agents, so a force-push onto `feat/...` lands between two people's intermediate states.
- **"Land a follow-up commit on the polluted branch that cherry-picks the in-scope commits"** — same audit-story problem. The PR diff still contains the drift.
- **"Force-push onto `feat/<original-branch>` to fix the history"** — this is the SOUL.md `never-push-onto-someone-elses-pr-head` violation. The branch is shared. Even if you "own" it, the worktree state is contested.
- **"Spawn another AO worker to drive to green"** — this is what failed 6 times to produce the escalation. The worker keeps re-rebasing the polluted branch and failing. Replay is the fix, not another worker.
- **"Disable the agento backfill cron for this PR"** — the cron is doing the right thing (alerting on a stuck PR). The PR is stuck because the underlying history is unrecoverable. Replay, then close the old PR so the cron stops targeting it.
- **"Include the helper refactor commit because the test fails without it"** — only if the refactor is genuinely in scope. If the refactor is a separate feature (like `dd3b5f801e refactor(level-up): extract _apply_terminal_cleanup_to_patch helper` in PR #7842 → #8937), the correct answer is option 2: drop the fix and its dependent tests, NOT extend the PR scope.

## Worked example — PR #7842 → PR #8937 (2026-08-15)

**Symptom:** Agent-O escalated "Backfill respawn cap reached for PR #7842: 6 prior workers archived." PR #7842 was 54 days old, CONFLICTING, 28 commits, +1001/-40 across 12 files. CodeRabbit APPROVED. All chatgpt-codex-connector items were stale "backfill meta" discussion, not blockers.

**Diagnosis:** `git log --first-parent origin/main..origin/feat/rag-class-fuzzy-match` showed the 28 commits were [feature, lint-fix, codereabbit-fix, fix, merge, merge, ..., fix, merge, ...]. Only 4 commits were in-scope class-lookup work. The rest was drift from 54 days of agento churn.

**In-scope commits identified:**
- `e4914e7439` feat(class-lookup): semantic fallback for reskinned class corpus (Phase C)
- `a7e8c9fa57` fix(lint): resolve Ruff PLR0911, PT018, F401 in class_lookup and its test
- `0a719b6f86` fix(class-lookup): address CodeRabbit review comments
- `4f82af582d` [fixpr codex-automation-commit] fix PR #7842

**Coupling pitfall caught:** `4f82af582d` CALLED `_apply_terminal_cleanup_to_patch`, which was DEFINED in `dd3b5f801e` (out-of-scope refactor). Two options:
- Include `dd3b5f801e` too → clean but extends scope to 5 commits
- Drop the level_up_session.py parts of `4f82af582d` AND its dependent test → strict scope, 4 commits, 3 files

Chose option 2 (strict scope). The dependent test was `test_project_legacy_clears_flags_for_sealed_v2_session` — removed from the cherry-pick. The level_up_session.py and test_level_up_session.py changes were reverted to HEAD before continuing the cherry-pick.

**Result:**
- New PR #8937: 4 commits, 3 files, +378/-3 (vs original 12 files / +1001/-40)
- Old PR #7842: closed with comment pointing to #8937
- Local tests: `test_class_lookup`, `test_class_lookup_semantic`, `test_level_up_session` all pass
- PR #8937 starts with `[agento]` so the backfill cron will pick it up cleanly

## Pre-flight gate — run BEFORE starting the replay

The fastest way to lose 30+ minutes is to start a claudem dispatch on a split the operator has already landed, or on a PR the operator has already closed. The 4-check preflight is the upstream gate for every replay path in this skill:

```bash
pr_preflight() {
  local pr="$1" target_branch="$2"
  echo "=== Preflight for PR #$pr on branch $target_branch ==="

  # Check 1: is the PR still alive?
  local state
  state=$(gh pr view "$pr" --json state,mergedAt --jq '"\(.state) merged=\(.mergedAt)"' 2>/dev/null)
  echo "1. PR state: $state"
  [[ "$state" == OPEN* ]] || { echo "   STOP — PR is not OPEN. Closed-not-merged or already merged."; return 1; }

  # Check 2: are YOU the active gh account, and does the PR author match?
  local active author
  active=$(gh auth status --json activeAccount --jq '.activeAccount.login' 2>/dev/null)
  author=$(gh pr view "$pr" --json author --jq '.author.login' 2>/dev/null)
  echo "2. Active gh account: $active | PR author: $author"
  [[ "$active" == "$author" ]] || { echo "   STOP — different author. Per never-push-onto-someone-elses-pr-head."; return 1; }

  # Check 3: is the operator's split/successor work already done?
  # (catches the most common time-waster: doing a split the operator already finished)
  local successors
  successors=$(gh pr list --state all --limit 30 --json number,title 2>/dev/null \
    | python3 -c "
import json, sys
n = int('$pr')
for p in json.load(sys.stdin):
    t = p['title'].lower()
    if f'split from #{n}' in t or f'supersedes #{n}' in t or f'replaces #{n}' in t:
        print(f\"#{p['number']} — {p['title']}\")")
  if [[ -n "$successors" ]]; then
    echo "3. Found successors:"
    echo "$successors" | sed 's/^/   /'
    echo "   ACTION: read each successor; if CI-green, link from your reply and stop."
  fi

  # Check 4: is your target branch name FREE on origin?
  local collision
  collision=$(git ls-remote origin "refs/heads/$target_branch" 2>/dev/null | awk '{print $1}')
  if [[ -n "$collision" ]]; then
    echo "4. STOP — branch $target_branch already exists at $collision. Pick -v2 suffix."
    return 1
  fi

  echo "All preflight checks PASSED."
  return 0
}
```

Real failure mode this catches (2026-08-22, PR #9132 → #9272 + #9273): the agent started a `claudem -p "split #9132" --max-turns 80` dispatch that would have created `-v2` branches duplicating the operator's already-merged split. The preflight caught it AFTER the worker was spawned but BEFORE any push landed, so the dispatch was killed and the orphan worktree was cleaned up with no remote side effects. The earlier session had also force-pushed an `a3c302e8d2` rebase onto an orphan `fix/pr9132-merge-conflicts` branch — this preflight would have flagged the closed PR at Check 1 and the wrong target branch at Check 4 before any push.

Use `pr_preflight <N> <your-target-branch>` at the start of any work on a non-trivial PR. The four checks are sequential dependencies — fail fast on the first one, don't bother with the rest. The same function is the upstream gate for `closed-pr-redrive` and any rebase/replay work in `drive-pr-to-green`.

## Pitfalls

**Pitfall 1 — `git diff origin/main..HEAD` shows 200 files because origin/main moved.** The 3-dot diff shows ALL the changes between the merge-base and HEAD. When your branch is 54 days old and origin/main has moved past your branch point, the diff inflates to include drift. Use `git diff --stat $(git merge-base origin/main HEAD)..HEAD` instead, or compare against the branch point SHA (the `HEAD~N` of your replay branch), not against current `origin/main`.

**Decision rule — when is plain `git rebase origin/main` correct, vs. full cleanup-replay?** The skill's main flow says "NEVER rebase. Always new worktree." But that rule targets **actually-polluted** branches (mix of in-scope commits + drift commits from other agents / agento churn). A clean branch whose only problem is `origin/main` moving past its base is a different situation.

Before reaching for full cleanup-replay, run the deleted-files pre-flight:

```bash
git diff --shortstat origin/main..HEAD       # the inflated diff
git diff --name-only <worktree-head>..HEAD   # your commits' actual files
git diff --name-only <worktree-head>..HEAD | while read f; do
  [ ! -f "$f" ] && echo "DELETED in main: $f"
done
```

If the deleted-files pre-flight prints NOTHING, your branch is **clean** (only `origin/main` drift inflated the diff) and the right fix is `git rebase origin/main` on the existing branch, NOT cleanup-replay. Push with `--force-with-lease` (NOT `--force` — protects against concurrent pushes to the same ref). Then re-run your tests on the rebased branch. Lesson source: PR #9089 (jleechanorg/worldarchitect.ai, 2026-08-19) — 2 commits, 7 files / +122/-95, no shared head, no merge commits, no agento drift. Plain rebase restored scope; full cleanup-replay would have created an unnecessary new branch + new PR number + orphan review thread.

If the pre-flight prints even ONE deleted file, the branch has crossed into actual pollution territory — pivot to full cleanup-replay (Variant A, B, C, or D per the table at the top).

**Pitfall 2 — `.beads/issues.jsonl` is append-only and gigantic.** Any commit that touched `.beads/issues.jsonl` will create a 4000+ line diff unless the cherry-pick's change is already on origin/main. Use `git checkout HEAD -- .beads/issues.jsonl` to drop the cherry-pick's beads change — beads is canonical-flushed on main, not on feature branches.

**Pitfall 3 — Cherry-pick conflict markers are noise.** Conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`) in committed files corrupt git history. Use `git grep -nE '^<<<<<<<|^=======$|^>>>>>>>' <file>` after each conflict resolution to verify no markers leaked. (The grep matches `=======` as a *line of only equals signs* — the section-divider marker, not table-row separators.)

**Pitfall 4 — The `[agento]` prefix.** New PRs created this way MUST start with `[agento]` so the backfill cron (`ai.agento.backfill`) detects them as AO-managed and auto-spawns session workers. Without the prefix, the cron ignores the PR and the next backfill escalation will repeat the same cycle.

**Pitfall 5 — `gh pr create` GraphQL bucket gets rate-limited.** When the GraphQL bucket is exhausted, REST `gh api -X POST repos/.../pulls` still works. Record the rate-limit hit, switch to REST, and report the new PR's URL via `gh api ... --jq`. The fallback chain is documented in `gh-rate-limit-resilience` skill.

**Pitfall 6 — Closing the old PR too early.** If you close PR #N before opening the new PR, the `Closes #N` reference in the new PR's body attaches to the now-closed issue and the issue gets reopened. Sequence: open new PR FIRST → comment on old PR → close old PR.

**Pitfall 7 — Forgetting `git -c core.editor=true` on `cherry-pick --continue` and `commit --amend`.** Without it, the editor hangs waiting for input on the "Press return to start merge message" prompt. The `-c core.editor=true` config makes the commit succeed without interaction.

**Pitfall 8 — Fresh replay worktree has no `venv/` (lesson from PR #8932, 2026-08-15).** The worktree created at Step 2 / Variant B Step 1 is bare — it shares git internals with the main checkout but NOT the `venv/` directory. Running `./vpython -m pytest ...` from the worktree fails with `Error: Virtual environment activate script not found at <worktree>/venv/bin/activate`. **Fix:** invoke pytest via the main checkout's venv at absolute path, with `PYTHONPATH=.` set to the worktree:

```bash
cd ${HOME}/projects/wt-pr-<N>-clean-replay
PYTHONPATH=. ${HOME}/projects/<repo>/venv/bin/python -m pytest \
    <test-file-1> <test-file-2> -x --tb=short
```

The alternative (`./vpython -m pytest ...` from the worktree) requires first creating the worktree's venv (`python3 -m venv <worktree>/venv && ./venv/bin/pip install -r requirements.txt`) — slow and not worth it for a 374-test regression run on the replay's targeted files. The same pattern applies to any `git worktree add` workflow (drive-pr-to-green, agento workers, etc.) — capture as a class-level pitfall, not just this skill.

**Pitfall 9 — `git ls-remote origin 'refs/pull/<N>/head'` != `refs/heads/<branch-name>` before the replay.** GH's `refs/pull/<N>/head` is the immutable ref that always points at the PR's current head. After Variant B's force-push, both refs MUST point at the new SHA. Verify with:

```bash
git ls-remote origin 'refs/pull/<N>/head' 'refs/heads/<branch-name>'
```

If they diverge, the force-push landed on a stale ref or the branch was renamed — the PR is showing one SHA, the branch is at another. STOP and investigate before posting a comment that announces a "clean replay" that didn't actually take.

**Pitfall 10 — Same `gh auth` user but `maintainer_can_modify=false` on the PR.** Cross-fork PRs and PRs from non-organization-owned forks set `maintainer_can_modify=false` even when the PR author and the active `gh auth` account match. Variant B's gates include this for a reason: force-pushing onto a `maintainer_can_modify=false` branch silently fails with `rejected: non-fast-forward` from a non-maintainer account. Check with `gh pr view <N> --json maintainer_can_modify` BEFORE the cherry-pick.

**When this gate fails, Variant A is the ONLY viable path — not a fallback.** The user may have authored the PR (author == `gh auth` user) and the PR's commits may even be theirs, but `maintainer_can_modify=false` means GitHub considers the head branch locked to the original opener's fork. The recipe:

1. Cherry-pick onto fresh `origin/main` worktree (Steps 1-4 unchanged).
2. Push to a NEW branch name (e.g. `feat/<slug>-clean-replay` or `feat/<slug>-trim`), NEVER the original `feat/...` head — any push onto the head ref is rejected.
3. Open a NEW PR with the body explaining the replay. Do NOT add `Closes #<N>` yet.
4. Comment on the old PR with the new PR URL + one-line reason ("`maintainer_can_modify=false` on #<N>; clean replay on fresh origin/main").
5. AFTER the new PR is open, edit the new PR body to add `Closes #<N>` (or close the old PR — the `Closes` reference resolves correctly because the new PR is already open).
6. Do NOT auto-close the old PR without an explicit user signal — closing a different-author's open PR silently is itself a SOUL violation. Post the side-by-side numbers and let the user decide.

**Lesson source (PR #8979, jleechanorg/worldarchitect.ai, 2026-08-17):** PR author was `${GITHUB_USER}` (== `gh auth` active account), 5 files / +179 lines, 3 commits all in scope, all in-scope. A force-push onto `feat/sanctuary-companion-dialog-opportunities` would have been rejected as non-fast-forward. The branch was pushed as `feat/sanctuary-companion-dialog-opportunities-trim` instead, rebased onto current `origin/main`, trimmed to **+81 lines** (down 55% from +179), and a fresh PR was opened. Original PR #8979 stays open until the user decides whether to supersede.

**Pitfall 11 — Variant B changes the SHA, NOT the PR number — `/er` / `/advice` evidence checks point at the PR.** If a review skill (`wa-green-gate-pr-shape`, `/er`, `/advice`) was previously run against this PR, those evidence bundles reference commit SHAs. After Variant B, those SHAs are stale. Re-run evidence reviews against the new head SHA before requesting human merge approval.

**Pitfall 12 — Cherry-pick conflict on stale base; the `git fetch <sha>` workaround.** When the original PR was branched off an N-commit-stale SHA (e.g. PR base = `c4ba6ab063`, current `origin/main` = `5be89ac325`, 8 commits ahead), the cleanest replay uses the PR's own base as the cherry-pick launchpad. The naive recipe `git worktree add -b <branch> origin/main` then `git cherry-pick <pr-sha>` produces a working-tree result but every cherry-pick from there forward re-applies 8 commits of unrelated mainline drift. The cleaner two-step:

```bash
git fetch origin <pr-base-sha>:refs/tags/<pr>-base 2>/dev/null \
  || git fetch origin <pr-base-sha>    # 'couldn't find remote ref <sha>' is fine — tag is local-only
git worktree add -b <new-branch> origin/main
cd <new-worktree-dir>
git reset --hard <pr-base-sha>          # back-date to PR base
git cherry-pick <sha1>                  # apply commit 1 of N (chronological order)
git cherry-pick <sha2>                  # apply commit 2 of N
git cherry-pick <sha3>                  # apply commit 3 of N
git rebase origin/main                  # forward to current main
# Now HEAD is on current origin/main with all 3 PR commits applied as if replayed
```

**Why fetch the base explicitly:** GitHub stores PR merge-base SHAs on the PR object, not in any standard ref. `git fetch origin c4ba6ab063` returns `fatal: couldn't find remote ref c4ba6ab063` for non-tag SHAs — that's expected, fall through to `git reset --hard <sha>`. The base SHA is known from `gh pr view <N> --json baseRefOid` (or visible in `git log`).

**Pick Path A (chronological cherry-pick) vs Path B (single reset to PR head) based on user intent:**

| User said | Path | Why |
|---|---|---|
| "Replay onto fresh origin/main" / "clean replay" / "rebase fix" | Path A — chronological cherry-pick with `-x` | Preserves the same N-shape commit history; audit story intact |
| "Trim this" / "smaller version" / "add only ~30 lines" | Path B — `git reset --hard <pr-head-sha>` then commit as 1 | Original N commits no longer accurately describe the trim; collapse them |

For the WA prompt-only case (most common trigger), Path B is often better when the user wants a trimmed version — you don't want the new PR's `git log` to lie about a 3-commit evolution when it's actually a 1-commit rewrite. Path A is better when replaying 1:1 (no trim).

**Pitfall 14 — `git reset --soft HEAD~1` only replays the LAST commit's staging, not the cumulative diff.** When collapsing a cherry-pick + a follow-up edit into a single commit, the obvious sequence is `git reset --soft HEAD~1 && git commit -m ...` followed by the same thing again. Each `--soft` reset puts the previous commit's diff into the staging area, but the next `--soft HEAD~1` resets that staging back to the previous commit's parent and re-stages only THAT previous commit. The end result is a single new commit whose diff equals only the LATEST prior commit (the 1-line extension), not the cumulative 71-line diff against `origin/main`. **Fix:** use `git reset --mixed HEAD~N` (with N = number of commits to collapse) which moves changes to the working tree, then `git add -A && git commit` once. Or just leave the changes uncommitted after the follow-up edit and skip the reset entirely. Verify the squashed commit's diff vs `origin/main` matches the expected full replay (`git diff --stat origin/main..HEAD`) before pushing. Lesson source: PR #9058 (jleechanorg/worldarchitect.ai, 2026-08-18).

**Pitfall 16 — For 1-line UI fixes, brief the worker to commit ONCE, not in two stages.** When dispatching to a claudem worker for a small CSS / HTML / JS change with attached evidence, the brief MUST say "make ONE commit containing all files: code + evidence + capture script". Workers routinely split into two commits (code first, then evidence PNGs as a follow-up) because the brief lists them as discrete steps. The result is a PR with two commits where the second is "evidence only" — the audit story is broken (per `pr-clean-branch-from-main-no-history-bloat`). The dispatcher verifies `git log --oneline origin/main..HEAD` shows exactly one commit before pushing, and squashes inline if not (via `git reset --soft HEAD^ && git commit --amend -m "<subject>" -m "<body>"` then `git push --force-with-lease`). Lesson source: PR #9365 (jleechanorg/worldarchitect.ai, 2026-08-25) — dispatched with `--max-turns 40`, worker hit limit after the 2-commit split, dispatcher squashed to a single commit ca152acf94 inline before opening the PR. The right brief would have prevented the split entirely; the right dispatcher behavior limits the blast radius when the brief fails.

**Pitfall 17 — Shell-escape trap on heredoc'd `git commit -m "$(git log …)"`.** When a dispatcher's recovery sequence is `git commit -m "$(git log --format=%s -1 HEAD)~1 -- 'evidence/...'"`, the bash parser mangles single-quote boundaries and the resulting commit subject contains literal shell noise (e.g. `…[Claude Code][MiniMax M3]~1 -- 'evidence/feat-...'`). Safer patterns: (a) write the message to a file first via `write_file`, then `git commit -F <file>`; (b) pass subject + body as separate `-m "subject" -m "body"` flags (each `-m` is parsed independently); (c) use `git -c core.editor=true commit --amend -m "subject" -m "body"` after-the-fact. Lesson source: PR #9365 (jleechanorg/worldarchitect.ai, 2026-08-25) — first push had a junk subject; recovered with `git reset --soft HEAD^ && git commit -m "feat(dashboard): right-align CTA cluster on mobile viewport [Claude Code][MiniMax M3]" -m "<3-paragraph body>"` + `git push --force-with-lease`.

**Pitfall 15 — Variant D: cherry-pick of a never-merged fix lands cleanly but the regression is NOT fixed.** A lost-PR replay against `origin/main` can succeed at the git level (auto-merge, all 3 files present, tests green) while leaving the original regression symptom untouched. The reason: the mainline refactor that landed between the lost-PR's authoring and the replay removed a fallback prose block the LLM relied on as a counter-anchor. The cherry-pick's new section at the top of the file is necessary but not sufficient; the regression needs ONE additional sentence in the surviving refactor's stub to re-anchor the requirement. **Verify the regression symptom is actually addressed** by tracing the LLM's read-path through the served prompt: `REQUIRED RESPONSE SCHEMA` (top of file) → fall through → `🛡️ PLAYER ACTION GUARDRAILS` → … → `**⚠️ DICE RESOLUTION & UI DISPLAY:**` (the refactor's stub). If the refactor's stub actively tells the LLM the opposite of what the schema section says, the LLM's read-path is contradictory and will resolve the contradiction in favor of the more recent prose. Add the reconciling sentence in the refactor's stub before opening the PR.

**Pitfall 13 — Dead-diff: PR CSS rules reference selectors that don't exist in the served HTML.** A PR can have a clean diff (no merge commits, no drift, every commit advances PR scope) AND have zero functional effect, because every CSS selector / DOM hook it adds targets classes that an upstream refactor introduces. Standard PR-cleanup checks (first-parent log, diff vs main, mergeable state, CodeRabbit) all pass vacuously. The diff is "inert."

Detection (run BEFORE opening or approving any UI/CSS PR that adds new selectors or DOM hooks):

```bash
# 1. Extract new class selectors from the PR diff (rough heuristic)
gh pr diff <N> --repo <owner>/<repo> \
  | grep -E '^\+\s*\.[a-z][a-z0-9_-]+[\s,{]' \
  | sed -E 's/^\+\s*\.([a-z][a-z0-9_-]+).*/\1/' \
  | sort -u > /tmp/pr-new-selectors.txt

# 2. Grep CURRENT origin/main's served HTML/JS (not local worktree — local
#    may be on a stale branch like agy/pr8856-thread-closure that lags
#    origin/main by 10+ commits)
git fetch origin main
git show origin/main:<entry-html-path> > /tmp/served.html

# 3. Per-selector check — non-zero exit = dead selector
while read sel; do
  grep -qE "\\.${sel}[^a-z0-9_-]" /tmp/served.html \
    || echo "DEAD: .${sel}"
done < /tmp/pr-new-selectors.txt
```

Three or more dead selectors in one PR is almost certainly Variant C (the PR branched before a refactor). Treat as Variant C — close + reopen on fresh `origin/main`. Single dead selector is more often a typo or a renamed-class mistake — confirm by reading the markup and the diff together before closing.

Real-world example: PR #8996 (jleechanorg/worldarchitect.ai, draft, 2026-08-17) added 245 lines of CSS for `.composer-stack`, `.composer-send`, `.composer-row`, `.composer-choices`. None of those existed in `index.html` at branch time — they came in with PR #8952 (composer refactor, merged 5:56 UTC the same day). The deploy preview served the dead CSS, the bug stayed unchanged, and the worker reported "Fixed" without visually verifying. Closed and reopened as PR #8997 (51 lines, single `@media` block) on fresh `origin/main`. Variant C section above has the full sequence.

This is the same anti-pattern as Pitfall 12 (stale base), but the failure mode is **functional invisibility rather than merge conflict** — the diff still merges, still builds, still passes CI. Only the visual proof step (`wa-visual-proof-playwright`) catches it, and only if the agent actually runs it before reporting "fixed."

## Slack narration threading

When posting status updates about this work in Slack, follow the same `thread_ts` rule as `drive-pr-to-green`: thread every status reply to the dispatch root ts. The original PR's alerting thread (e.g. agento's "Backfill respawn cap reached" notification) is the dispatch root — reply there, not to channel root.
