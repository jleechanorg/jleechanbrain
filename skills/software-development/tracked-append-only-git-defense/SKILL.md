---
name: tracked-append-only-git-defense
version: 1.1.0
description: "Stop JSONL/append-only file corruption across merges."
tags: [git, jsonl, append-only, merge-driver, repo-infra, durability, beads, worktrees]
related_skills: [agent-harness-engineering, always-pr-never-local-edit, drive-pr-to-green]
changelog:
  - "1.1.0 (2026-08-06): Add 'Recovery: when a worker already pushed a polluted branch' subsection + `references/polluted-worktree-recovery-2026-08-06.md`. Origin incident: a claudem worker dropped into a stale-base worktree shipped 5657 lines / 16 files when the real diff was 8 files / 1430 lines; the JSONL regression test then failed CI. The recovery recipe uses path-limited `git checkout <sha> -- <files>` to extract the wanted diff onto a fresh branch from current origin/main. Skill previously covered prevention only — now covers pollution discovery + surgical recovery."
  - "1.0.0 (2026-08-05): Initial authoring. Origin incident: jleechanorg/worldarchitect.ai `.beads/issues.jsonl` — 6+ dedup commits in 2 weeks, 26+ worktrees each generating local `rev-*` IDs, recurrent duplicate IDs across merges. Fix is the 3-layer defense landed as PR #8798."
---

# Tracked Append-Only Git Defense

> **The rule of thumb:** If you commit an append-only log to git, assume two branches will both append the same record and prepare for a 3-way merge of last-occurrence-as-add. One-line `.gitattributes` + a 30-line canonicalizer script + a 6-line hook installer usually fixes it for good.

## When to use this skill

Use this skill when any of the following is true:

- A tracked file is line-oriented (JSONL / NDJSON / `.log` / `.po` / lockfile-style appender / audit log) and uses **per-line IDs**.
- The same dedup / reconcile / repair commit has shipped **3+ times in recent history** (`git log --grep -iE '(dedup|reconcile|fix.*(jsonl|json))'`).
- A `git diff` between `origin/main` and a long-running branch shows the **SAME record ID on both `+` and `-` sides** (convergent duplicate — the strongest signal).
- Multiple worktrees, agents, or processes each write to the file independently (beads-rs `br create` on each worktree, audit-trail writers per subprocess, cron logs that flush back to git, etc.).
- The file is too large for a server-side canonicalizer to handle (>500 MB) and must be committed as-is.

**Do NOT use this skill** for:
- Hand-written docs that go through normal PR review (those don't need a merge driver — humans resolve conflicts).
- Files that are intentionally regenerated every commit (e.g. `package-lock.json` if you're using a tool like `npm ci` to re-pin; `.json` files that are mostly code-generated).
- Binary files (use `merge=binary` or LFS).

## The three-layer defense (the canonical pattern)

### Layer 1 — git merge driver via `.gitattributes`

Append this line (with the existing LFS / other entries preserved) to the repo's `.gitattributes`:

```
# <Kind of log>: union merge keeps lines added on both sides,
# then post-merge canonicalizer dedups by id.
<path> merge=union
```

`git`'s built-in `union` merge driver has shipped since git 2.7 (2014) and is the canonical answer to "two branches appended to the same file." Both sides' added lines survive; nothing is lost. Resolution happens later in Layer 2.

For the entry to take effect:
- `.gitattributes` must be **committed** to the branch (it's per-path, like `.gitignore`, and travels with the branch).
- No `[merge "union"]` block is needed — union is built-in. (Custom merge drivers require `.git/config` or `.gitconfig` settings.)
- The fix applies to every clone that has the `.gitattributes` line — there's no per-clone install required for Layer 1.

**Pinned examples:**
- `.beads/issues.jsonl merge=union`  (beads-rs, worldarchitect.ai + dark-factory)
- `CHANGELOG.md merge=union`  (the canonical handbook example)
- `translations/*.po merge=union`  (gettext catalogs, long-standing pattern)
- `audit/*.jsonl merge=union`  (any per-process audit log)

### Layer 2 — idempotent canonicalizer (dedup-by-id canonicalizer)

A small **stdlib-only** Python script in `scripts/` that:
1. Parses every line as the line's natural format (JSON for JSONL, etc.).
2. **Deduplicates by `id` (or equivalent)**: keep the first occurrence; on tie, keep the one with the LATER `updated_at` (ISO 8601 string compare is UTC-safe); fall back to first-occurrence when either is missing `updated_at`.
3. Sorts ascending by `id` using a stable sort.
4. Writes atomically (`tmp` + `os.replace`).
5. Exits 0 on success; 1 only on fatal I/O error.
6. Reports: line count kept, dup count collapsed, byte count — same one-line format regardless of whether anything changed.
7. **Idempotent**: running it twice never changes the output byte-for-byte.
8. Preserves malformed lines (reports to stderr with `line:N:content` prefix and appends them at end — never silently drop; recovery is hard).

Existing examples this skill preserves:
- `dark-factory/scripts/sort_beads_jsonl.py` — hardened version that adds dedup-by-id (148-line rewrite from the 60-line sort-only predecessor).

### Layer 3 — install a post-merge + post-checkout hook that re-runs the canonicalizer

A one-shot bash installer that, when run from the repo root, idempotently installs three git hooks:

| Hook | Trigger | What it runs |
|---|---|---|
| `pre-commit` | `git commit` | canonicalizer — only if the log file is staged |
| `post-merge` | `git merge` / `git pull` | canonicalizer unconditionally — second line of defense for contributors without Layer 3 installed |
| `post-checkout` | `git checkout` / `git switch` worktrees | canonicalizer only if `git checkout` updates the log file (cheaper than post-merge; catches worktree switches) |

Hook logic must be **idempotent** (re-running the installer overwrites all three hooks safely), **silent on missing script** (don't block commits/merges if the canonicalizer has been deleted), and print a one-line summary: `Installed 3 hooks at <path>: pre-commit, post-merge, post-checkout`.

For per-clone installation: hooks don't transfer across clones (this is git's design). Run the installer once per clone. For shared infra (where all contributors use the same setup), add the installer call to `setup.sh` / the repo's `Makefile` `setup` target.

## Worked example — `.beads/issues.jsonl` at worldarchitect.ai (2026-08-05)

**Symptom:** 6+ dedup commits in 2 weeks; `dark_factory_trust_manifest` worktree file had 3759 records vs origin/main's 2533; `git diff origin/main..HEAD` showed convergent dups in the hunks.

**Root cause:** Concurrent worktrees each spawned `br create`, generating local `rev-*` IDs that overlapped when merged back to `main`. Git's default 3-way merge kept both copies because there was no `merge=` driver on the JSONL.

**Fix landed as PR [#8798](https://github.com/jleechanorg/worldarchitect.ai/pull/8798)** (3 files, +257 / -35):

| File | Change |
|---|---|
| `.gitattributes` | added `.beads/issues.jsonl merge=union` |
| `scripts/sort_beads_jsonl.py` | hardened sort → dedup-by-id canonicalizer (148 lines) |
| `tests/test_beads_jsonl_canon.py` | 6 regression cases (sorted noop, unsorted, dup→latest-updated_at, missing-updated_at, malformed-line preservation, idempotent-2-runs) — `6 passed in 0.24s` |

**Hook installer extension** was outside the PR scope but should be a follow-up (one PR extending `scripts/install-beads-hook.sh` to install `post-merge` and `post-checkout` hooks in addition to the existing `pre-commit`).

## Verification recipes

### Confirm the merge driver is wired

```bash
git check-attr -a -- .beads/issues.jsonl
# Expected: merge: union
```

### Confirm the canonicalizer is idempotent

```bash
md5_before=$(md5sum .beads/issues.jsonl | awk '{print $1}')
python3 scripts/sort_beads_jsonl.py
md5_after=$(md5sum .beads/issues.jsonl | awk '{print $1}')
test "$md5_before" = "$md5_after" && echo "idempotent: ok"
python3 scripts/sort_beads_jsonl.py
test "$md5_before" = "$(md5sum .beads/issues.jsonl | awk '{print $1}')" && echo "two-runs: ok"
```

### Confirm duplicate IDs are now collapsed

```bash
# Before the fix: 4000+ records with 1500+ duplicates
# After the fix:
python3 -c "
import json
ids = [json.loads(l)['id'] for l in open('.beads/issues.jsonl') if l.strip()]
total, uniq = len(ids), len(set(ids))
print(f'lines={total} unique={uniq} dups={total-uniq}')
assert total == uniq, 'still has duplicates'
"
```

### Round-trip: simulate a convergent-dup merge

```bash
# Make a branch
git checkout -b test/dup-merge origin/main
echo '{"id":"rev-test","updated_at":"2026-08-05T00:00:00Z"}' >> .beads/issues.jsonl
git add .beads/issues.jsonl && git commit -m "add rev-test on branch"
git checkout main
echo '{"id":"rev-test","updated_at":"2026-08-05T00:00:01Z"}' >> .beads/issues.jsonl
git add .beads/issues.jsonl && git commit -m "add rev-test on main"

# This merge should produce NO conflict (union), and the
# post-merge hook (when installed) collapses to the latest updated_at.
git merge test/dup-merge  # should auto-resolve
python3 scripts/sort_beads_jsonl.py  # canonicalize and confirm only one rev-test
grep -c '"id":"rev-test"' .beads/issues.jsonl  # expect 1
git branch -D test/dup-merge
```

## Pitfalls

- **`merge=union` plus a 3-way conflict → both sides' adds appear, but if git ALSO sees a real conflict in the line text (e.g. one branch rewrote a line, the other appended), git still aborts.** Union avoids the **append-vs-append** conflict; it does NOT prevent every conflict. The canonicalizer only sees union-merged content, so plan for occasional manual merge of the file regardless.
- **The canonicalizer is idempotent but NOT commutative across versions.** If two canonicalizer versions disagree on dedup policy (old keeps first, new keeps latest-updated_at), re-running the newer one over the older's output may drop lines. Always bump the canonicalizer behind a `br doctor`-style check or with an explicit migration commit.
- **`post-merge` hook runs on EVERY merge — including fast-forward merges into feature branches.** On big repos that merge frequently, the hook fires hundreds of times a day. Keep the canonicalizer linear in file size (O(n log n) sort + O(n) dedup); don't load the whole file into memory more than once.
- **Layer 1 (.gitattributes) applies retroactively ONLY to commits that have not yet been merged into the branch the user is on.** Once a dup is in `origin/main`, Layer 1 doesn't help; the fix is a one-shot dedup commit (PR #8763 in the worked example). Do NOT try to retroactively "un-corrupt" with the canonicalizer without committing it explicitly.
- **The hook installer must detect the script's existence gracefully.** A missing canonicalizer should NOT block `git commit` from running — that turns the hook into a process hazard. `exit 0` silently when the script is missing, with a stderr note.
- **Per-clone install is git's design choice; don't fight it.** Either ship the installer call in the repo's bootstrap script (`./install.sh`, `make setup`) or accept that fresh clones need one extra invocation. Trying to wire pre-commit via `git config core.hooksPath` to a shared file has caused more problems than it solves.

## Common follow-ups (separate PRs)

These belong in distinct PRs from the defense itself — the defense is infrastructure, not a one-shot cleanup:

- **One-shot dedup commit on `origin/main`** (the same fixes the recurring corruption already shipped in the worked example as PR #8763). Once that's merged, the canonicalizer keeps it clean.
- **Doc note in `AGENTS.md` / `CLAUDE.md`** pointing operators at the canonicalizer so they know it exists.
- **Metric: `git diff --shortstat origin/main..HEAD -- <log-file>` should be near-zero unless the file actually changed.** Long diffstats on append-only files are a smoke alarm for missing layers — wire this into `br doctor` or a `make pre-commit-check` if your repo has one.
- **Pre-commit-style CI check that the JSONL parse + dedup is clean** — defense in depth if a contributor bypasses the hook (e.g. on a CI runner that runs `git commit --no-verify`).

## Recovery: when a worker already pushed a polluted branch

The 3 layers above prevent corruption. They DO NOT recover a worktree that already committed `.beads/issues.jsonl` (or any other append-only file) into a PR — which happens routinely when a dispatched coder worker (claudem / AO / codex) is dropped into a stale-base worktree, runs `git add -A`, and ships the polluted staging area alongside the intended diff. Real incident: 2026-08-06, jleechanorg/worldarchitect.ai#8794 — a claudem worker created `feat/campaign-share-url-phase1` on a worktree forked from `bdb560fd84` (the origin/main SHA from the moment of dispatch), and by push time `origin/main` had advanced to `53dddccdfb`. The PR's diff against the new origin/main showed 5657 lines across 16 files, 4228 of which were `rev-*` duplicate-ID JSONL plus 5 unrelated tier_pressure-revert files. Green-CI failed; `test_beads_integrity:test_beads_issue_ids_are_unique` reported `877 duplicate ids`.

**Detection (smoke signals before pushing):**

```bash
git diff --shortstat origin/main..HEAD
# > 1500 lines on a feature PR usually means scope drift or wrong base.

git diff origin/main..HEAD --name-only
# ANY entry matching <log-file> (e.g. .beads/issues.jsonl, CHANGELOG.md) is wrong.

git log --oneline origin/main..HEAD --grep='^Merge remote-tracking branch'
# Any result = the worktree was forked from a stale base.
```

**Recovery recipe (preserve the wanted diff; drop the pollution):**

```bash
# 1. Confirm the wanted commit exists with the wanted files alone
git show <polluted-sha> --stat
# Identify exactly which files you wanted (vs auto-included JSONL + scope drift).

# 2. Close the polluted PR (preserve the commit so step 3 works)
gh pr close <N> --comment "Replaced by <new-pr> — see reason below"

# 3. Spin up a FRESH worktree at current origin/main
git worktree add -b fix/<topic>-clean origin/main ~/wt-<topic>-clean

# 4. Extract only the wanted files from the polluted commit,
#    onto the new clean base. This skips ALL auto-staged pollution
#    (JSONL, unrelated scope creep) by addressing them by path.
cd ~/wt-<topic>-clean
git checkout <polluted-sha> -- \
  path/to/wanted-file-1.py \
  path/to/wanted-file-2.js \
  docs/plans/spec.md
git status   # MUST show only the wanted files

# 5. Local quality gates on the clean worktree
./run_tests.sh <touched-tests>
ruff check <touched-py-files>
ruff format --check <touched-py-files>

# 6. Commit + push + open a fresh PR
git -c user.email=... -c user.name=... commit -m "<proper prefix>"
git push -u origin HEAD
gh pr create --base main --head <new-branch> --title "..." --body "..."
```

**Why `git checkout <sha> -- <files>` rather than cherry-pick:** cherry-pick brings the commit's full tree including any auto-staged append-only file edits. Path-limited checkout brings only the named files — equivalent to a surgical extract. Use this whenever the polluted commit contains the wanted diff AND scope drift; cherry-pick is only safe when the polluted commit is otherwise clean.

**Companion recipe in `references/polluted-worktree-recovery-2026-08-06.md`** — verbatim transcript of the jleechanorg/worldarchitect.ai#8794 → #8805 recovery with commands, lint output, and the 13/13 test re-run, written so a future operator can execute it without context.

## Why this isn't in `agent-harness-engineering`

`agent-harness-engineering` covers repo-level docs (`AGENTS.md`, `docs/agent/`, mechanical checks). It is agnostic to git plumbing. Tracked-append-only-git-defense is about a **git-level merge behavior + canonical script + hook installation** — a different surface. Keeping them separate lets each grow without forcing merge friction between docs and git plumbing.

## Acceptance checklist

Before shipping a fix using this skill, confirm:

- [ ] `.gitattributes` has the `merge=union` line and is **committed** (not just local).
- [ ] Canonicalizer script is **stdlib-only**, **idempotent**, reports what it did.
- [ ] At least 4 regression tests covering: sorted noop, unsorted, dedup→latest, idempotent-2-runs.
- [ ] Hook installer is **idempotent** (re-running overwrites cleanly) and **silent-on-missing-script**.
- [ ] One-shot dedup of the existing corruption is a SEPARATE PR (not bundled).
- [ ] PR body documents the 3 layers + before/after behavior on the same file.
- [ ] Operator-visible evidence: pytest green output pasted verbatim.

## References (support files in this skill)

- `references/canonicalizer-template.py` — stdlib-only starter script (≈ 90 lines) adapted from `dark-factory/scripts/sort_beads_jsonl.py`. Drop into `scripts/`, change `JSONL` / `ID_FIELD` / `TIE_FIELD` to your schema, then expose it from your hook installer.
- `references/hooks-installer.sh` — idempotent installer template for the three hooks (`pre-commit`, `post-merge`, `post-checkout`). Adapt `SORTER` and `TARGET_FILE` at the top.
- `references/test-fixtures.py` — six pytest cases (sorted noop, unsorted, dup→latest-updated_at, missing-updated_at, malformed-line preservation, two-runs-idempotent). Copy into `tests/test_<your-name>_canon.py`, point `SCRIPT` at your canonicalizer.
- `references/polluted-worktree-recovery-2026-08-06.md` — verbatim recovery transcript for when a worker has already pushed a polluted branch (16-file / 5657-line diff that should have been 8 files / +1430). Includes detection commands, the path-limited `git checkout <sha> -- <files>` surgical extract, lint fixes that commonly apply during cleanup, and a before/after metrics table.

## Related real-world PRs

- [jleechanorg/worldarchitect.ai#8798](https://github.com/jleechanorg/worldarchitect.ai/pull/8798) — origin PR for this skill (`.beads/issues.jsonl` defense, +257/-35, 3 files).
- [jleechanorg/worldarchitect.ai#8763](https://github.com/jleechanorg/worldarchitect.ai/pull/8763) — the companion one-shot dedup commit that cleans up the existing corruption the defense will then keep clean (the two must ship as separate PRs).
