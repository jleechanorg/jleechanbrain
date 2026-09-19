# Fork Cherry-Pick Recipe — canonical fix for upstream #72273 onto user-owned fork

> **v1.0.0 (2026-08-19)** — written from a verified run that shipped [jleechanorg/hermes-agent#9](https://github.com/jleechanorg/hermes-agent/pull/9). The recipe below is the playbook for future "I have a fork of `NousResearch/hermes-agent` and want to apply upstream PR #N there" tasks.

## When to use this recipe

Use when the user has **ADMIN or WRITE access** to a fork of `NousResearch/hermes-agent` (verify with `gh repo view <user-fork> --json viewerPermission`) AND wants the upstream PR's fix to be durable across `pip install --upgrade` cycles. The recipe replaces the older local-venv-patch approach (see `local-continuation-prompt-patch.md`).

**Trigger phrase patterns:**
- "use my fork" / "apply it to my jleechanorg fork"
- "open a PR on the fork"
- "fix the upstream PR on my side"
- Anytime `gh repo view jleechanorg/hermes-agent --json viewerPermission` returns `ADMIN` and the user is asking for a streamed-Hermes fix.

## Inputs (gather BEFORE any edits)

1. **The upstream PR patch URL**: `https://patch-diff.githubusercontent.com/raw/NousResearch/hermes-agent/pull/<N>.patch` (replace `<N>` with the PR number — e.g. 72273 for the streaming-cut fix).
2. **Fork repo name**: confirmed via `gh repo view jleechanorg/hermes-agent --json name,isFork,parent,defaultBranchRef,pushedAt,viewerPermission`. Must be `isFork:true`, `parent.login:NousResearch`, viewerPermission ∈ `ADMIN | WRITE`.
3. **Branch from origin of fork**: target `fork/main`, NOT the local main checkout. Use `git worktree add ... origin/main` (where `origin` = the user's fork remote named `fork` here).

## Step-by-step (verified 2026-08-19)

```bash
# Step 0 — Auth + state check (run BEFORE any edits)
gh auth status 2>&1 | grep -E "jleechan-active|Active account|user" | head -3

cd ${HOME}/projects_other/hermes-agent  # canonical hermes-agent checkout

# Verify the fork remote + branch baseline
git remote -v
# Expect lines for: origin = NousResearch (upstream), fork = jleechanorg (user's fork), and possibly newfork/archive
git fetch fork main 2>&1 | tail -3
git log --oneline fork/main -3
git rev-list --count origin/main ^fork/main  # how far behind upstream

# Step 1 — Clean worktree from fork/main (NOT from local main checkout)
git worktree add .worktrees/fix-<PRNUM>-<topic> fork/main -b fix/<PRNUM>-<topic> 2>&1 | tail -3
cd .worktrees/fix-<PRNUM>-<topic>
git status -sb   # MUST be `## fix/<PRNUM>-<topic>...fork/main` — if not, STOP

# Step 2 — Apply upstream patch with --check first
curl -fsSL "https://patch-diff.githubusercontent.com/raw/NousResearch/hermes-agent/pull/<PRNUM>.patch" \
  -o /tmp/upstream-<PRNUM>.patch
git apply --check /tmp/upstream-<PRNUM>.patch
# If this fails: try git apply --check --reject, inspect reject hunks
# If still fails: re-fetch the latest commit on the PR, inspect file paths
git apply -v /tmp/upstream-<PRNUM>.patch
git diff --stat
# Expect: small numbers like +10/-3 (prompt text) and +11 (test) — NOT +500+ lines

# Step 3 — Run the test the patch added (or any regression test named in the patch)
.venv/bin/python -m pytest tests/<test_path> -q --no-header
# MUST pass locally before committing

# Step 4 — Commit with provenance tag (see ~/.claude/CLAUDE.md "Commit provenance tag (must)")
git add <file1> <file2> ...
git -c user.name='hermes-agent' -c user.email='hermes-agent@nousresearch.com' commit -m "$(cat <<'EOF'
<model-id-prefix>: <upstream-PR-title> (#<PRNUM>)

<2-3 line bug summary citing the upstream issue>
<2-3 line fix summary citing the upstream PR>

Provenance:
- branch from fork/main (<fork-main-sha>), N commits on top
- verbatim cherry-pick of upstream PR #<PRNUM> by <upstream-author>
- the <N> upstream-upstream files: <list with line counts>
- pytest <test_path>: <N>/<N> pass in <seconds>s

Originally <upstream-commit-sha-short>; this is a clean replay with the
<model-id-prefix> provenance tag added per CLAUDE.md "Commit provenance tag (must)".
EOF
)"

# Step 5 — Push branch to fork
git push fork HEAD 2>&1 | tail -5
# Expect: `* [new branch] HEAD -> fix/<PRNUM>-<topic>` plus git-secret-guard scan preamble

# Step 6 — Open PR on fork
gh pr create --repo <user-fork> \
  --base main --head fix/<PRNUM>-<topic> \
  --title "<upstream-PR-title> (#<PRNUM>)" \
  --body "$(cat <<'EOF'
## What does this PR do?

Backport of upstream PR #<PRNUM> (<upstream-author>, <upstream-date>) onto the
<user-fork> fork, so our local Hermes Agent v<version> picks it up via
`pip install --upgrade --force-reinstall git+https://github.com/<user-fork>/hermes-agent@<branch|main>`.

## Bug

<1-paragraph summary from the upstream PR body>

Fixes #<issue-number>: <issue-title>

## Fix

<1-paragraph summary of what changed>

## Changes

- `<file1>` — <file-line-count>
- `<file2>` — <file-line-count>

## How to Test

```
<test-command>
# → <N>/<N> pass in <seconds>s
```

## Provenance

- Pushed from fork/main (`<fork-main-sha>`), N commits on top.
- Source patch is verbatim from upstream PR #<PRNUM> — no changes to the wording or logic.
- `<model-id-prefix>` provenance tag added per the user's CLAUDE.md commit-provenance-tag convention.
- Original upstream commit SHA preserved in the commit body.

## Attribution

Originally authored by <upstream-author> in
[NousResearch/hermes-agent#<PRNUM>](https://github.com/NousResearch/hermes-agent/pull/<PRNUM>).
This PR is a verbatim cherry-pick onto <user-fork>, applied at commit
`<commit-sha-short>` on `fix/<PRNUM>-<topic>`. Provenance: `<model-id-prefix>:`
per fork's commit-provenance-tag convention.

## Related

- Upstream issue #<issue-number> — <issue-title>
- Upstream PR #<PRNUM> — original implementation
EOF
)"

# Step 7 — Confirm PR is OPEN
gh pr view <new-pr-number> --repo <user-fork> \
  --json url,state,headRefName,baseRefName,additions,deletions,changedFiles,author

# Step 8 — Post link to Slack thread (use the same conversation from the user's diagnostic ask)
gh pr view <new-pr-number> --repo <user-fork> --json url --jq .url
# Compose message citing the PR URL, branch, commit, diffstat, test result
```

## Pitfalls (real ones, observed in this session)

- **`git apply --check` before commit** — without the check, a hunk that doesn't apply can land and look committed but actually fail in surprising ways.
- **Provenance tag mandatory** — `~/.claude/CLAUDE.md` requires `<cli>/<model-id>:` in the commit subject. Easy to forget when copy-pasting the upstream PR title.
- **`git worktree add` MUST target `fork/main`**, not the local main checkout. The local main is often on a dirty feature branch with unrelated changes (we saw `+3973` commits ahead on the upstream side — that's normal for fork/main, but the LOCAL main checkout could have hundreds of unrelated dirty files).
- **Do NOT push to `origin`** — that's the upstream NousResearch repo. Verify with `git remote -v` before push: push to `fork`.
- **`git secret guard` scans the push range** — preamble like `git secret guard: scanning outgoing range a071f0c114..0fe9529ee1` is normal, not an error. Check the actual push output line beneath it.
- **`gh pr create` on the fork requires viewerPermission ADMIN or WRITE** — `gh auth status` shows `${GITHUB_USER}` (active user) but write access is per-repo; check `viewerPermission` in step 0.
- **Test invocation**: use `.venv/bin/python -m pytest ...`, NOT `python3 -m pytest ...` — the .venv is the active one and `python3` from Homebrew is 3.13, which doesn't have the test deps.
- **Commit message must cite the upstream issue/PR numbers inline** — future agents grepping the commit history for "fix streaming cut" will land on this commit. Cite them.

## Output contract for the user

When this recipe completes, the user-facing message must contain:

1. **PR URL** (markdown link).
2. **Branch name + commit SHA short**.
3. **diffstat** (which files + line counts).
4. **Test result** (`<N>/<N> pass in <seconds>s`).
5. **Install command** to activate the fix:
   ```
   pip install --upgrade --force-reinstall git+https://github.com/<user-fork>/hermes-agent@<branch>
   ```
6. **Citation back to upstream** (issue number + PR number with links).

The Slack message in the original 2026-08-19 incident (PR #9 thread reply) is a model output:

```
🟢 Action 2 done — PR open on your fork.

PR: jleechanorg/hermes-agent#9 — fix(agent): re-assert tool availability on partial-stream continuation (#72273)

| | |
|---|---|
| Branch | fix/72273-partial-stub-tool-availability |
| Commit | 0fe9529ee1 (1 commit on top of fork/main a071f0c114) |
| Diff | agent/conversation_loop.py +10/-3, tests/.../test_partial_stream_finish_reason.py +11 |
| Tests | pytest tests/run_agent/test_partial_stream_finish_reason.py → 16/16 pass in 7.10s |
| Author | The patch is a verbatim cherry-pick of upstream PR #72273 (Ugo Enyioha, 2026-07-30); provenance tag claude/minimax-M3: added per fork's commit-provenance-tag convention |
```

## When the user's fork is stale relative to upstream

**Observed 2026-08-19:** `fork/main` was 3,973 commits behind `origin/main`. That's fine — the cherry-pick recipe only needs `fork/main` to contain the file structure the patch touches. The cherry-pick adds a fix on top of the user's fork without bringing in 3,973 unrelated upstream commits (per `pr-clean-branch-from-main-no-history-bloat`).

**When to fast-forward the fork first:** if the upstream patch references a file path that the fork has deleted (because fork/main was last pushed months ago), the patch will fail to apply. In that case:

```bash
# Selective sync: bring in upstream main's _get_continuation_prompt location into fork/main
git fetch origin main
git checkout fork/main
git merge origin/main --no-ff -m "chore(fork): sync upstream main for #<N> patch context"
git push fork fork/main
# Then re-run the cherry-pick recipe from Step 1.
```

But **do not** do this if you can't reason about the merge cleanly — fall back to applying #72273 manually inside the conversation_loop.py file from scratch using the patch hunks.

## Companion skills

- `github-pr-workflow` — branch + commit + push + PR mechanics.
- `pr-clean-branch-from-main-no-history-bloat` — SOUL.md rule that bans piggybacking unrelated commits onto a single PR.
- `pr-evidence-inbound-review` — for the inverse direction (when upstream PRs land and you need to audit them).
- `hermes-streaming-cut-diagnosis/SKILL.md` (this skill's root) — diagnostic order + when-to-load triggers.

## Changelog

- v1.0.0 (2026-08-19): Initial authoring, shipped with jleechanorg/hermes-agent#9. Bug-ref: Slack C0AUXSVFSA2/p1787116801599009.
