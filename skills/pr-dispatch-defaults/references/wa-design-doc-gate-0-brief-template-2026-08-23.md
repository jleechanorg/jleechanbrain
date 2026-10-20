# Design Doc Gate 0 — brief template + post-PR-open recovery (added 2026-08-23, jleechanorg/worldarchitect.ai PR #9270)

## TL;DR

`jleechanorg/worldarchitect.ai` has a `Design Doc Grep Gates` workflow that fails
any PR with >50 non-test `mvp_site/*.py` delta lines unless the PR body contains
a `## Tenets` / `## Design Decision` section AND inside that section a linked
bead (`rev-xxxx`) or `.md` artifact.

**The gateway session MUST include the literal Tenets template (in this file)
in every bucket-2 brief that touches `mvp_site/**` non-test files.** A worker
that ships without the Tenets section in the PR body costs an extra code
push + CI cycle + worker turn ≈ 8–12 min wall clock.

## Verified failure case (PR #9270, 2026-08-23)

Branch `feat/agentic-hosting-hygiene`. Dispatched via claudem print-mode with
a 21KB brief listing four hosting-shape items. Worker shipped the code change
(`mvp_site/main.py` +204 lines, `frontend_v1/index.html` +41 lines, etc.),
opened the PR, ran tests locally (15/15 PASS). First CI run on the PR:

```
Design Doc Grep Gates    fail    20s    ❌ Gate 0 FAIL: PR has 204 non-test delta lines (>50) but lacks a Tenets / Design Decision section
Green Gate               pass    4s
CodeRabbit               pass    0s     (review rate-limited)
```

`mergeStateStatus` flipped to `UNSTABLE`. The worker had no instruction to
produce a design doc. The brief had no Tenets template.

## Recovery path (verified on PR #9270, total ≈ 90 seconds)

1. **Write the design doc on the branch.** `docs/<feature-slug>-design-decision.md`,
   commit on the same branch. The gate regex matches the path string verbatim,
   so a relative path inside the body works.

2. **`gh pr edit --body-file <new-body.md>`** to add the `## Tenets` section
   linking the design doc. Section shape (verified working):

   ```markdown
   ## Tenets (Design Decision)

   Linked artifact: [`docs/agentic-hosting-design-decision.md`](https://github.com/jleechanorg/worldarchitect.ai/blob/feat/agentic-hosting-hygiene/docs/agentic-hosting-design-decision.md)

   1. **Don't SSR the game.** ...
   2. **Don't add `Accept: text/markdown` negotiation to the game origin.** ...
   3. **Static landing copy in raw HTML is the right answer for #1 + #2 together.** ...
   4. **JSON-LD as `SoftwareApplication`, not `Organization`.** ...
   ```

3. **`gh run rerun <failed-run-id>`** to re-trigger ONLY the failed job. The
   new commit on the branch is not strictly required (the gate reads the PR
   body via GraphQL, not the diff), but adding the design doc as a commit
   gives the reviewer a findable artifact URL.

4. Poll `gh pr checks <N>` for ~30s. The Design Doc Gate flips from `fail` to `pass`.
   `mergeStateStatus` flips from `UNSTABLE` back to `CLEAN` once all required
   checks are pass.

5. The design-decision doc body itself follows the template in
   `pr-dispatch-defaults` SKILL.md "WA-specific pitfall" section — copy that
   template verbatim, fill in the bracketed fields, commit.

## Why "include the Tenets template in the brief upfront" is cheaper than "recover post-PR-open"

| Path | Cost (wall clock) | Tool calls | User-visible state |
|------|-------------------|------------|---------------------|
| Include Tenets template in brief (worker ships full PR on first try) | 0 extra | 0 extra | clean open + green |
| Recover post-PR-open (PR #9270 path) | ~90 sec + 1 wasted CI cycle | 4 (commit design doc, push, gh pr edit, gh run rerun) | briefly "UNSTABLE" before flipping CLEAN |
| Worker re-dispatches with tighter brief | ~10 min | many | full re-spin |

The 90s recovery is fine if you catch the gate failure fast. But the
user-visible "is this PR ready?" signal flips red for those 90s, which is
the actual UX cost — not the wall clock.

## Pre-flight check for any bucket-2 brief on jleechanorg/worldarchitect.ai

Before dispatching the worker, run:

```bash
# What gates does this repo actually have?
gh workflow list --repo jleechanorg/worldarchitect.ai --json name,path \
  | jq -r '.[] | select(.name | test("[Dd]esign|[Dd]oc|[Tt]enet")) | .path'

# How much mvp_site/*.py delta is this brief going to produce?
# (rough estimate — count \.py$ non-test files in the brief's "FILES CHANGED" list)
```

If the gate exists AND the brief estimates >50 non-test `mvp_site/*.py`
delta lines, include the literal template from `pr-dispatch-defaults`
SKILL.md "WA-specific pitfall: Design Doc Grep Gates Gate 0" in the
worker brief, in the GATES / pre-push self-audit section.

## Companion skills

- `pr-body-grep-gate-fix` — the canonical 5-step recipe for fixing a body-driven
  gate after PR creation (REST PATCH + rerun-failed-jobs). Use it on the
  "recover post-PR-open" path.
- `pr-dispatch-defaults` SKILL.md "WA-specific pitfall: Design Doc Grep Gates
  Gate 0" — the literal Tenets template to include in the brief upfront.
- `claude-code-claudem` — the dispatcher wrapper that takes the brief via
  `cat <worktree-path>/branch-brief.md` (NOT `/tmp/...`).
