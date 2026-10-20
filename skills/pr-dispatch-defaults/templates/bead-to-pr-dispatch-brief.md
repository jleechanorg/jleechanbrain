# Brief template: dispatch a PR from an existing bead (recipe is already proven)

Copy this template to `<worktree>/branch-brief.md` (or a `~`-anchored path), then run:

```bash
bash -lic 'claudem -p "$(cat <worktree>/branch-brief.md)" --max-turns <N> --output-format text'
```

NEVER `/tmp/<name>.md` — claudem's first action is `cat <path>` and a tmp-cleanup race
kills the dispatch. See `pr-dispatch-defaults` SKILL.md "Writing the brief to
/tmp/" pitfall.

---

```
WORKTREE: <absolute path> (branched from origin/main @ <sha>, clean, tracking set).
Do NOT create a new worktree. Do NOT touch any other worktree. Branch is yours.

BEAD: <rev-XXX> — read with `br show <rev-XXX>` from the source repo
(NOT from this worktree; the bead store is gitignored here). The bead body is the
canonical recipe. Key facts already proven in the bead:

ROOT CAUSE: <one-paragraph restatement — file + line + mechanism>

EVIDENCE:
- src: <relative path>:<line>
- src: <relative path>:<line>
- live repro: <command, log excerpt, or campaign_id>
- live impact: <latency / payload / error count>

FIX (N layers, ship all in this PR):

LAYER 1 (PRIMARY — REQUIRED for the PR to merge):
1.a. <concrete change to file:line>
1.b. <concrete change to file:line>
1.c. <verification condition>

LAYER 2 (SECONDARY — payload / UX):
2.a. <concrete change>

LAYER 3 (TERTIARY — resilience / retry):
3.a. <concrete change>

REGRESSION TESTS (REQUIRED — write all N, must pass before push):
- <path>: <what it asserts>
- <path>: <what it asserts>
- <path>: <what it asserts>

GATES:
- Run scoped tests: ./run_tests.sh <test paths>
- /es required for mvp_site/** changes — run it and capture the bundle SHA
- CodeRabbit/Bugbot are advisory, but address CHANGES_REQUESTED before /green
- /green = current-HEAD CI success + no merge conflicts
- **Design Doc Gate 0 (jleechanorg/worldarchitect.ai ONLY — verify the gate
  exists with `gh workflow list --repo jleechanorg/worldarchitect.ai --json name,path | jq -r '.[] | select(.name | test("[Dd]esign|[Dd]oc|[Tt]enet")) | .path'`)**:
  if you ship >50 non-test `mvp_site/*.py` delta lines, you MUST (a) write
  `docs/<feature-slug>-design-decision.md` on the branch using the template in
  `~/.smartclaw/skills/pr-dispatch-defaults/references/wa-design-doc-gate-0-brief-template-2026-08-23.md`,
  (b) commit it on the same branch as the code, (c) include a `## Tenets` section
  in the PR body that links that file. See `pr-dispatch-defaults` SKILL.md
  "WA-specific pitfall" section for the full template. Verified on PR #9270
  (Aug 2026) — skipping this costs the gateway ~90s + a wasted CI cycle.

EXIT CRITERIA (the only thing that counts as "done"):
1. PR is OPEN at https://github.com/<owner>/<repo>/pull/<N>
2. PR CI is GREEN (all required checks pass)
3. ZERO merge conflicts (mergeable == MERGEABLE)
4. Final reply gives: PR URL, branch name, HEAD SHA, evidence bundle SHA, and
   a 1-line summary of the diff (files changed, lines added/removed)

DO NOT:
- Do NOT push to any branch other than <branch>.
- Do NOT absorb unrelated work (no drive-by skill patches, no /web-advice ladder
  fixes, no memory/policy edits — those are separate beads).
- Do NOT touch .beads/issues.jsonl (gitignored here; use --no-auto-flush).
- Do NOT merge. For this repo, merge requires the operator's explicit
  "MERGE APPROVED" in the most recent live user message. Your job is to land a
  GREEN PR. Open it, post the PR URL in your final reply, stop there.
- Do NOT poll/wait for CI green after pushing — exit with PR URL as soon as
  the PR is open and tests-local pass. Babysitting is a separate job.
- Do NOT use --max-turns above 120 for a 3-layer fix OR 150 for a 7+ file
  thin-slice. 80 hits the ceiling ~52min before PR create.

RETURN FORMAT (final reply):
PR URL: https://github.com/<owner>/<repo>/pull/<N>
Branch: <branch>
HEAD: <sha>
Evidence bundle: <sha> or N/A
Diff: <N> files, +X/-Y
Local tests: PASS/FAIL
Status: OPEN + GREEN | OPEN + waiting for CI | OPEN + CHANGES_REQUESTED | BLOCKED: <reason>

If you hit a HARD BLOCKER (CI infra down, missing secret, conflicting files),
post the blocker and STOP. Do not synthesize a fake PASS.
```

---

## When this template fits

- The bead body already contains the root cause, evidence, and fix layers.
- The dispatch is bucket-2 (multi-component, requires worktree, requires PR).
- The user has approved "ok how to fix? let's make a PR" type wording.
- You do NOT have live read/write access to the bead store from the worktree.

## When NOT to use this template

- The diagnosis is still in flight (use a research brief, not a fix brief).
- The work is bucket-1 (≤30 tool calls, single PR scope). Do it inline per
  `pr-dispatch-defaults` decision matrix.
- /af, /auto-factory, /claw, or any explicit AO trigger — use `ao spawn` per
  `agento` skill.
- The user wants a one-shot local patch with no PR — `always-pr-never-local-edit`
  says no, but if the user explicitly says "just patch it locally, don't PR",
  skip the template.

## Pre-dispatch checklist (run before invoking claudem)

1. `git -C <repo> fetch origin` + `git -C <repo> log --oneline origin/main -5` —
   confirm the worktree HEAD is current.
2. `git -C <worktree> status -sb` — must read `## <branch>...origin/main` with
   no local changes.
3. `br show <rev-XXX>` from the SOURCE repo (not the worktree) — confirm the bead
   body still has the recipe and is not stale.
4. Save the brief at `<worktree>/branch-brief.md` (NEVER `/tmp/...`).
5. `bash -lic 'claudem -p "$(cat <worktree>/branch-brief.md)" --max-turns <N> --output-format text'`
   with `notify_on_complete=true` for the non-blocking tail.
