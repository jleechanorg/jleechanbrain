# 2026-08-22: `worker-local-green-not-pr-green` failure class

## Canonical counter-example

**Where:** Slack thread `C0AH3RY3DK6/p1787299543490919` (jleechanorg/worldarchitect.ai PR #9227)
**When:** 2026-08-22, dropped-thread followup fired ~12h after worker exit
**Trigger message:** U09GH5BR3QU — *"Let's have it only trigger after like multiple combat successes. Also living world events seem too antagonistic. I want neutral or positive things too. Let's have living world only trigger once per day and not per turn and then only one antagonist thing every two weeks"*

## What happened

### Phase 1 — Worker dispatch

claudem worker spawned via `bash -lic 'claudem -p "<brief>" --max-turns 80 --output-format text'` on a clean worktree from `origin/main`. Brief contained:

- The user's full goal text (UC streak gate, LW 24h cadence, antagonist 14d cooldown)
- BQ data showing 518 UC mentions / 19,227 turns (33.8% antagonist rate across 151 LW turns)
- The recipe line: *"exit with PR URL when PR is open; do NOT poll for CI green — that's an operator/babysit job"*

### Phase 2 — Worker delivered

Worker pushed branch `feat/uc-streak-gate-lw-tone-24h-cd14`. PR #9227 opened:

- 7 files changed, +642/-16
- CodeRabbit APPROVED
- Local pytest of the 2 NEW test files: `test_unforeseen_complication_prompt_rules.py` (1/1) and `test_living_world_tone_cooldown.py` (1/1)

Worker exit message included the line: *"both test files green locally"* — gateway agent relayed this verbatim.

### Phase 3 — Dropped-thread followup caught it

Dropped-thread cron fired after worker exit. Re-checking `gh pr view 9227 --json statusCheckRollup` revealed:

```
STATE: OPEN
MERGEABLE: MERGEABLE
FAILS: ['Design Doc Grep Gates', 'Schema Coverage Guard', 
        'Directory tests (core-mvp-1(self hosted))', 
        'Directory tests (core-mvp-2(self hosted))', 
        'Directory tests (core-mvp-3(self hosted))']
```

5 of the workflow gates were FAILURE. The 2 tests the worker ran green do not appear in any of those workflow names — they're exercised by `mvp_site/tests/...` directories scanned by the `Directory tests` shards, but those shards ALSO scan the whole `mvp_site/tests/` tree including pre-existing tests for adjacent features. The worker never ran `scripts/check_schema_coverage.py` (the `Schema Coverage Guard`), never read `.github/workflows/design-doc-gate.yml` (the `Design Doc Grep Gates` rule), and never let the self-hosted MVP shard runners actually run.

### Phase 4 — Recovery

Gateway agent then:
1. Reported the 5 failing checks honestly (no fabrication)
2. Created worktree `${HOME}/projects/worldarchitect.ai/.worktrees/pr9227-ci` at PR head SHA `14cd6ced8a`
3. Wrote a new dispatch brief at `/tmp/pr9227-brief.md` with the explicit rule: *"Do NOT declare PR green by running only the test files you added. You MUST run `gh pr view <N> --json statusCheckRollup` after push and confirm zero FAILURE conclusions across the entire rollup."*
4. Dispatched a follow-up claudem worker to fix the 5 failing gates
5. Created babysit cron `babysit-pr-9227-ci-green` (job_id `73ff43b4c59b`) to watch PR #9227 CI to green

## Root cause (what the failure-mode catalog fix should prevent)

The dispatch brief told the worker *"exit with PR URL when PR is open; do NOT poll for CI green."* This correctly offloaded CI polling — but it ALSO left a gap: the worker was never required to enumerate the PR's actual gate set before declaring the PR delivered. The worker followed the recipe literally ("don't poll for green") and reported "tests pass" using only the tests it could see locally — without ever querying `gh pr view --json statusCheckRollup` to see the workflow-level gates that had already failed.

This is **the same shape as `fabricated-proof` (existing class)** but more specific: the proof artifact isn't arbitrary terminal output, it's specifically `gh pr view --json statusCheckRollup` showing zero FAILURE conclusions. Adding it as a separate class makes the dispatch-brief fix actionable — the brief can include a one-line rule *"Worker-local test green is necessary but not sufficient; verify `statusCheckRollup` shows zero FAILURE"*.

## Recipe (also in the catalog entry)

The fix has three parts:

### A. SOUL.md `## COMMIT: pr-green-requires-full-gate-set`

Trigger: *"any message declaring a PR is green, ready, or fix-complete."* Action: *"run `gh pr view <N> --json statusCheckRollup` in the same turn; if any `conclusion == FAILURE`, do NOT post green; post the failing gate names instead."*

### B. Dispatch-brief template

When spawning a `claudem -p` worker that will open or push to a PR, the brief MUST include:

> **Do NOT declare PR green by running only the test files you added.** You MUST run `gh pr view <N> --json statusCheckRollup` after push and confirm zero FAILURE conclusions across the entire rollup. Worker-local pytest green is necessary but not sufficient — workflow-level gates (Schema Coverage Guard, Design Doc Grep Gates, Directory tests on self-hosted runners, Evidence Gate, Skeptic) run independently of the worker's local pytest and can FAIL even when the worker's tests pass.

### C. finish-the-job end-state tightening (user-owned skill)

The "PR open with green CI awaiting user merge" end-state in `finish-the-job` currently says *"gh pr view <N> --json mergeStateStatus,reviewDecision shows MERGEABLE + review clean."* The verification should also include `statusCheckRollup` with zero FAILURE — `mergeStateStatus=MERGEABLE` only means GitHub-side merge conflicts are clear, not that CI is green. (Filed as a recommendation; user-owned skill requires adopt.)

## Repro

To reproduce the failure class:

1. Open a small PR on jleechanorg/worldarchitect.ai that adds a new schema path (e.g. new key on `world_events.background_events[]`).
2. Push to `feat/<name>` and let CI run.
3. Before pushing, run only `./run_tests.sh test_<new_file>` locally — confirm it passes.
4. Push. Observe `gh pr view --json statusCheckRollup`: `Schema Coverage Guard` will FAIL because `mvp_site/schemas/game_state.schema.json` doesn't yet list the new path. The worker's local pytest does not exercise `scripts/check_schema_coverage.py`.
5. Report "PR is ready" without checking `statusCheckRollup`.
6. **Failure reproduced.** The PR ships with `Schema Coverage Guard: FAILURE` even though "the tests pass locally."

## Cross-references

- Catalog entry: `worker-local-green-not-pr-green` (verification-layer, FC3)
- Sibling: `fabricated-proof` (existing class — same shape, broader scope)
- Dispatch recipe: `bash -lic 'claudem -p "<brief-with-gate-set-rule>" --max-turns N'`
- Verification: `gh pr view <N> --json statusCheckRollup`
- Filed but not yet adopted: SOUL.md `## COMMIT: pr-green-requires-full-gate-set`
