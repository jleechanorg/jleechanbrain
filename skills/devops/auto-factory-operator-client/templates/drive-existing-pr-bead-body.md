# Drive-existing-pr bead body template

Paste-ready. Run via `br create` from jeff-ubuntu. Keep the body under 4096 chars (AO spawn prompt cap).

## Template

```
factory: drive PR #<NUMBER> — <branch-name> to /green + READY

## Drive-existing-pr fields (intake normalizer)
## existing_pr: <NUMBER>
## existing_branch: <exact headRefName from gh pr view>
## target_repo: <owner>/<name>

## Context (<date> snapshot)
- HEAD: <sha>
- mergeable: MERGEABLE | <reason>
- reviewDecision: <APPROVED|CHANGES_REQUESTED|"">
- CI: <green | <list of failing checks>>
- 3-way gate summary from latest GATE_ASSESSMENT in daemon.jsonl: <one line>
- No current bead in `br list --status all` owns this branch — clean claim slot.

## Contract
- Same work spec as siblings: drive current-HEAD gates (CI, conflict, /er, /advice, comments), refresh evidence per repo standards. No content changes expected.
- No AGY evidence generation; verifier ticks run from local evidence only.
- Never weaken/skip/xfail tests. .beads/issues.jsonl must stay identical to origin/main.
- Do not force-push; fetch before commit/push.

Commit often (crash-recovery insurance).
```

## Fill-in example for PR #7886 (real 2026-08-18 case)

```
factory: drive PR #7886 — fix/repro-spell-list-shgGj4Jx133993pZ4erw to /green + READY

## Drive-existing-pr fields (intake normalizer)
## existing_pr: 7886
## existing_branch: fix/repro-spell-list-shgGj4Jx133993pZ4erw
## target_repo: jleechanorg/worldarchitect.ai

## Context (2026-08-18 snapshot)
- HEAD: <sha from gh pr view 7886>
- mergeable: MERGEABLE
- reviewDecision: ""
- CI: green
- 3-way gate summary: no prior GATE_ASSESSMENT
- No current bead owns this branch — clean claim slot.

## Contract
- Drive current-HEAD gates (CI, conflict, /er, /advice, comments), refresh evidence per repo standards. No content changes expected.
- No AGY evidence generation; verifier ticks run from local evidence only.
- Never weaken/skip/xfail tests. .beads/issues.jsonl must stay identical to origin/main.
- Do not force-push; fetch before commit/push.

Commit often (crash-recovery insurance).
```

## Why each section is required

- **`existing_pr`** — daemon knows which PR's PR head to compare against for tracking.
- **`existing_branch`** — daemon refuses to create a fresh `factory/<id>-r1` branch.
- **`target_repo`** — daemon needs to disambiguate from other repos the daemon may be watching.
- **`## Context`** — gives the future coder subagent the state-of-PR-when-this-was-filed so it doesn't redo diag.
- **`## Contract`** — explicit constraints prevent the common code-base regressions (test weakening, force-pushes, .beads drift).

## AO spawn prompt-cap (4096 chars)

This template as-is is well under 4096 chars (~700 chars). If you expand the Context section with verbose gate transcripts, BE CAREFUL — AO will silently swallow the prompt if it overflows. Keep the body focused; reference longer transcripts via URL or `references/<bead-id>.md`.
