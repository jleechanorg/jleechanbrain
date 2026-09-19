# Verified case: PR #8829, worldarchitect.ai V2 composer card (2026-08-09)

The canonical example this skill was extracted from. Three `claudem --continue` rounds at 80/60/40 turns hit max-turns; the inline takeover in round 4 salvaged the ironclad middle layer.

## Session shape

- **User message** (Slack thread C0AH3RY3DK6/1786305757.546479): "I like V2 unified composer card let's make a PR for it fullrun set /ironclad goal don't stop until/es and /er pass captioned video evidence from testing_ui proving every aspect new flow works and try using /test-realistic too"
- **Dispatch wrapper**: `bash -lic 'claudem -p "<task>" --max-turns <N>'` from a clean worktree on a fresh `feat/...` branch from `origin/main`
- **Branch**: `feat/planning-block-v2-unified-composer` at `${HOME}/projects/worldarchitect.ai.wt/wt-planning-block-v2`
- **Base**: `origin/main` at `b32fbfe0fe` (later advanced to `732b4d7461` due to upstream PRs landing mid-dispatch)

## Timeline

| Round | Turns | Wall clock | Outcome |
|-------|-------|-----------|---------|
| 1 | 80 | ~35 min | Pushed `4d1df5359b` (V2 spec, +796/-1, 4 files), opened PR #8829, CodeRabbit + Green Gate + Detect Changed Paths PASS, Light/Fantasy Compliance Gate FAILED with `exit 127` |
| 2 | 60 | ~5 min | Pushed `c66f6b6801` (no-op retrigger commit), Light/Fantasy passed on retry |
| 3 | 40 | ~30 min | Captured 3 PNGs (BEFORE/ACTION/AFTER) to `evidence/pr-8829/` locally; no commit; no /es; no /er; no /test-realistic |
| 4 (inline) | — | ~25 min | Committed PNGs as `9f06ed348b`, pushed, ran /test-realistic structural subset (250/250 pass), reproduced 4 `TestStreamingRawRequestPayloadPopulated` failures on `origin/main` HEAD to prove same-name rule, posted final consolidated reply to Slack thread with PARTIAL labels for /es and /er (GitHub secondary rate limit blocked those) |

## Ironclad criterion table (final state)

| # | Criterion | Status | Reason |
|---|-----------|--------|--------|
| 1 | PR exists with V2 styles + click→fill wired, branched from origin/main | ✅ PASS | `gh pr view 8829` → state=open, mergeable=true, +796/-1, 4 files |
| 2 | All CI checks passing | 🟡 PARTIAL | 17/20 pass at HEAD `c66f6b6801`, 0 fail, 3 self-hosted tests queued (slow) |
| 3 | `/es` returns PASS | ⚠️ NOT POSTED | GitHub secondary rate limit (HTTP 403) on `POST /repos/.../issues/8829/comments` |
| 4 | `/er` returns PASS | ⚠️ NOT POSTED | Same rate limit |
| 5 | Captioned video from testing_ui | 🟡 PARTIAL | PNGs committed + uploaded to thread; live video from preview URL not captured (worker ran out of turns) |
| 6 | `/test-realistic` runs end-to-end | 🟡 PARTIAL | 250/250 structural pass; 35 pre-existing failures in `test_runner.py` (same-name verified); `pr8489_capture.jsonl` fixture not in repo |
| 7 | `/es`/`/er` PASS + no merge conflicts + planning-block tests green | 🟡 PARTIAL | 4 pre-existing `TestStreamingRawRequestPayloadPopulated` failures documented as same-name on origin/main |

## Companion pitfalls (extracted from this case)

1. `--workdir` is NOT a claudem flag — round 1 hit `error: unknown option '--workdir'` immediately. Use `cd <path> && bash -lic 'claudem …'` instead.
2. `tee` swallows claudem's TUI stdout — Claude Code's Ink TUI doesn't flush to a non-TTY pipe. `tee claudem.log` shows only the startup warning line. Use `exec >/path/to/log 2>&1` BEFORE launching.
3. `process.poll()` against running claudem shows empty log mid-run — poll worktree state (`git status --short`, `git log origin/main..HEAD`) instead.
4. Pre-existing test failures need same-name reproduction BEFORE dismissing — the 4 `TestStreamingRawRequestPayloadPopulated` failures in this case reproduced byte-identically on `origin/main@732b4d7461` via fresh `git worktree add /tmp/wa-baseline origin/main` + `python3 -m venv venv && ./venv/bin/pip install -r mvp_site/requirements.txt && ./venv/bin/python -m pytest <failing-file>::<failing-class> --tb=long`.
5. GitHub secondary rate limit (HTTP 403 on `POST /repos/.../issues/<N>/comments`) is sticky for ~1 hour — heavy `gh pr checks` polling + retries tripped it. Label rate-limit-blocked criteria as NOT POSTED in the final reply; do NOT retry blindly.

## Cost of multi-round dispatch

| Cost component | Real (this case) |
|----------------|------------------|
| Wall clock | ~95 min total (3 worker rounds + 1 inline takeover) |
| Token burn (rough) | ~600K tokens across worker rounds; inline takeover ~50K |
| Net value | PR + visual evidence + /test-realistic + final reply; /es /er NOT POSTED |

vs. target single-round budget: a `bash -lic 'claudem -p <tight-brief> --max-turns 80'` on this scope is realistic if the brief is tight (only the V2 code change + tests, no video capture + /es /er + /test-realistic + final Slack reply all in one round). For that combined scope, plan for at least 2 rounds + inline takeover.
