# Claudem worker takeover budget — 2026-08-19 avatar-grok PR #9112

## Verified incident

Slack thread `C0AH3RY3DK6/p1787119923.214439` ("Make a PR to allow users to AI generate an avatar during campaign creation or when they do edit avatar. It should use grok API for image gen and this prompt"). Dispatched as a bucket-2 thin-slice feature PR for `jleechanorg/worldarchitect.ai`.

## What we asked for vs what the budget allowed

**User-visible scope**:
- Backend route `POST /api/avatar/generate-grok` + single-seam helper module (`mvp_site/avatar_image_gen.py`)
- Frontend "✨ Generate with AI" button + inline modal + campaign-wizard integration
- Unit tests (mocked xAI HTTP + mocked firestore upload)
- Existing multipart upload paths unchanged

**Actual diff at landing**: 8 files, +1301 / -1 (added the design-decision doc + BEFORE/AFTER PNGs after the fact).

## Worker pass timeline (per session log)

### Pass A — implementation (`proc_4ced81c794fe`)

- **Dispatch**: `--max-turns 80`
- **End state on disk**: 5 files modified (frontend_v1/app.js +163, css/avatar.css +171, index.html +1, js/campaign-wizard.js +88/-1, main.py +132), 2 files created (`avatar_image_gen.py` 348 LOC, `test_avatar_grok_gen.py` 339 LOC).
- **End state for the worker**: max-turns hit with `WORKER_EXIT=1`. Nothing committed, nothing pushed, no PR opened, no tests run, no visual proof.
- **Cost paid**: ~80 worker turns of pure implementation polish; 0 of the 4 end-state gates (`commit`, `push`, `pr create`, `tests/proof`) reached.

### Pass B — resume (`proc_3088d430d1f7`)

- **Dispatch**: `--max-turns 30` (deliberately smaller — implementation already done)
- **End state on disk**: 2 commits (`e98f5f4550` impl, `35e989baa7` design doc), force-pushed to `origin/feat/avatar-grok-gen-2026-08-19`, PR #9112 opened with body and full description.
- **End state for the worker**: max-turns hit with `RESUME_EXIT=1`. Got to `gh pr create` but did not run tests, did not capture visual proof, did not fix the `Design Doc Grep Gates` Gate 0 failure that surfaced 23s after PR opened.
- **Cost paid**: 30 turns including 2 turn-costly interactive rebases to fix author + commit prefix.

### Inline finish (gateway session)

After both worker passes maxed out, the gateway session finished inline (~15 min, ~30 tool calls):

1. Force-pushed amend to fix author (`Hermes <hermes@MiniMax.local>` → `${GITHUB_USER} <${GITHUB_USER}@users.noreply.github.com>`)
2. Force-pushed amend to fix commit prefix (`claude/MiniMax-M3:` → `claude/minimax-M3:`)
3. Wrote `docs/design/2026-08-19-avatar-grok-generation.md` (NEW, 59 lines) — satisfies Gate 0's "linked .md artifact" requirement
4. Updated PR body via `gh pr edit --body-file` to add `## Tenets` section + linked design doc path
5. Built self-rendered HTML harness with real avatar.css inlined (BEFORE/AFTER pages), captured PNGs via headless Chrome (with `--virtual-time-budget=5000` to bypass Chrome hang on the AFTER page)
6. Committed PNGs to branch under `docs/pr9112-evidence/`, force-pushed
7. Updated PR body to embed PNGs via raw.githubusercontent.com URLs

**Total cost across the full flow**: 80 + 30 + ~30 inline = ~140 turns, ~$8 estimated, ~25 minutes wall-clock.

## What we should have done

**Pass A should have been split from Pass B at the dispatch decision**, not after Pass A died. The diff was multi-domain (backend helper + 3 frontend files + new test module) and clearly above the bucket-2 single-pass ceiling. Recommended re-bucketing:

| Phase | Worker | Budget | Scope |
|---|---|---|---|
| Pass A | `claudem -p` | 80 turns | Implementation + unit tests. End state: `git add` + `git commit` on the worktree branch, no push. |
| Pass B | `claudem -p` | 50 turns | Pre-push self-audit + rebase onto current `origin/main` + author/prefix correction + push + `gh pr create` + run tests + capture visual proof. |
| Inline | gateway | 20–30 tool calls | Fix Gate 0 (write design doc + amend PR body), commit evidence PNGs, embed in PR body, set follow-up cron. |

Total: 130 worker turns + 30 inline tool calls = same budget consumed, but the inline finish was scoped to the FIX step rather than the COMBINED implementation + push + CI-fix.

## Anti-pattern recap

- **Don't let one worker own impl + push + CI-fix + visual proof** for any multi-domain diff >1000 LOC. The 4 end-state gates are independently budgetable; any one can blow the budget.
- **Don't bury the design-doc requirement in the pre-push audit** — it must be IN the worker brief from the start when the diff touches `mvp_site/*.py` (WA-specific Gate 0).
- **Don't trust `git log origin/main..HEAD` from worker Pass A** without `git fetch origin` in Pass B — the worker may have branched from a stale `origin/main` SHA. Always `git fetch && git rebase origin/main` before force-pushing.
- **The `--max-turns 80` default in claudem worker dispatches is sized for the "remove dead code" bucket-1 task, NOT for a thin-slice feature PR.** For multi-domain thin-slice features, raise the budget to 150 OR split into 2 passes.

## Reference commands (verbatim)

```bash
# Pre-dispatch budget sizing
DIFF_LINES=$(git diff --shortstat origin/main..HEAD 2>/dev/null | awk '{print $4}')
DIFF_FILES=$(git diff origin/main..HEAD --name-only 2>/dev/null | wc -l)

# 1242 LOC / 8 files → 150 turns OR split
# 500 LOC / 4 files → 100 turns
# 200 LOC / 2 files → 60 turns
```

## Provenance

- PR: [#9112 feat(avatar): AI-generate avatar via Grok image API](https://github.com/jleechanorg/worldarchitect.ai/pull/9112)
- Worker A session: `proc_4ced81c794fe` (impl, 80 turns, exit 1)
- Worker B session: `proc_3088d430d1f7` (resume, 30 turns, exit 1)
- Inline finish: gateway session, ~30 tool calls, ~15 min
- Slack thread: `C0AH3RY3DK6/p1787119923.214439`
- Captured: 2026-08-19
