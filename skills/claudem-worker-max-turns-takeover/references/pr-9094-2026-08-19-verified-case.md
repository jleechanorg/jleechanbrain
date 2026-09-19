# PR #9094 — jleechanorg/worldarchitect.ai, frontend god-mode narrative render-swap (2026-08-19)

## Context

User directive (Slack thread `C0BDEAJH8PK / 1786844858.028199`, parent ts `1786844858.028199`):
> "Run /repro https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/game/7HHDMPe0wNLBDTfymzfT whenever the god mode text is the same as the narrative let's just replace the narrative text and say hmsomehtjgn generic like god mode turn no narrative"
> "Make this PR and fullrun until its /ready"

Prior triage identified 4 interpretations of the symptom. User chose interpretation #3 (frontend render swap). Bead: `rev-noctune-narrative-dup-3rd-sibling-pj83v`.

## Dispatch shape

- Worktree: `git worktree add ${HOME}/projects/worldarchitect.ai-wt-noctune-narrative-render origin/main -b feat/god-mode-no-narrative-render` at HEAD `88756c1f8b`.
- Worker invocation: `bash -lic 'PROMPT=$(cat /tmp/wa-claudem-brief.md); claudem -p "$PROMPT" --max-turns 60'` in `terminal(background=true, notify_on_complete=true)`.
- Brief: 7.5KB at `/tmp/wa-claudem-brief.md` — verbatim user directive, canonical reference path, sibling cluster context, scope boundary (frontend-only — backend `narrative=""` contract untouched), contract-test recipe, BEFORE/AFTER visual proof requirements, full pitfall list, skill load order, hard contract.

## Worker outcome

Background process `proc_d202cfbf3ede` (pid 19921) ran ~52 min wall-clock, hit `Error: Reached max turns (60)`. Tee output was 3 lines (bash startup banner + auth warning + exit error) — the Ink TUI swallowed stdout per pitfall #7.

Worktree state at worker exit:
- `M  mvp_site/frontend_v1/app.js` (3 render sites updated to call `window.GodModeNarrativeRender.resolve(...)`)
- `M  mvp_site/frontend_v1/index.html` (added `<script>` tag for the new helper before consumers)
- `M  mvp_site/frontend_v1/js/streaming.js` (streaming finalizer uses `.PLACEHOLDER`)
- `?? mvp_site/frontend_v1/js/godModeNarrativeRender.js` (NEW — 71 lines, exposes `PLACEHOLDER` constant + `resolve(narrative, godModeResponse)` function)
- `?? mvp_site/tests/test_god_mode_narrative_render_swap.py` (NEW — 246 lines, 12 tests)
- 0 commits ahead of `origin/main HEAD 88756c1f8b`
- 5 files / +350 / -7 (no `git diff origin/main..HEAD` since worker did not commit)

The implementation was clean (no duplicate defs per pitfall #13, helper is well-documented with bead reference, all 3 render sites use the helper consistently, single source of truth for the placeholder constant). Worker exhausted budget on implementation + verification, never reached the shipping phase.

## Inline takeover (5-step recipe from pitfall #15)

### Step 1 — Snapshot

```bash
$ cd ${HOME}/projects/worldarchitect.ai-wt-noctune-narrative-render
$ git status -sb
## feat/god-mode-no-narrative-render...origin/main
$ git log --oneline origin/main..HEAD
(empty)
$ git status --short
 M mvp_site/frontend_v1/app.js
 M mvp_site/frontend_v1/index.html
 M mvp_site/frontend_v1/js/streaming.js
?? mvp_site/frontend_v1/js/godModeNarrativeRender.js
?? mvp_site/tests/test_god_mode_narrative_render_swap.py
```

### Step 2 — Inline tests

Venv symlinked: `ln -sf ~/projects/worldarchitect.ai/venv venv` (worktree-local).

```bash
$ PYTHONPATH=. venv/bin/python -m pytest mvp_site/tests/test_god_mode_narrative_render_swap.py -v
============================= test session starts ==============================
collected 12 items

mvp_site/tests/test_god_mode_narrative_render_swap.py::GodModeNarrativeRenderSwapContract::test_god_mode_with_empty_narrative_renders_placeholder PASSED [  8%]
mvp_site/tests/test_god_mode_narrative_render_swap.py::GodModeNarrativeRenderSwapContract::test_god_mode_with_non_empty_narrative_unchanged PASSED [ 16%]
mvp_site/tests/test_god_mode_narrative_render_swap.py::GodModeNarrativeRenderSwapContract::test_legacy_undefined_string_treated_as_empty_god_mode PASSED [ 25%]
mvp_site/tests/test_god_mode_narrative_render_swap.py::GodModeNarrativeRenderSwapContract::test_module_exposes_api PASSED [ 33%]
mvp_site/tests/test_god_mode_narrative_render_swap.py::GodModeNarrativeRenderSwapContract::test_non_god_mode_with_empty_narrative_unchanged_empty PASSED [ 41%]
mvp_site/tests/test_god_mode_narrative_render_swap.py::GodModeNarrativeRenderSwapContract::test_non_god_mode_with_non_empty_narrative_unchanged PASSED [ 50%]
mvp_site/tests/test_god_mode_narrative_render_swap.py::GodModeNarrativeRenderSwapContract::test_placeholder_is_single_source_constant PASSED [ 58%]
mvp_site/tests/test_god_mode_narrative_render_swap.py::GodModeNarrativeRenderSwapContract::test_undefined_string_god_mode_response_with_real_narrative_unchanged PASSED [ 66%]
mvp_site/tests/test_god_mode_narrative_render_swap.py::GodModeNarrativeRenderSwapContract::test_whitespace_only_narrative_with_god_mode_renders_placeholder PASSED [ 75%]
mvp_site/tests/test_god_mode_narrative_render_swap.py::GodModeNarrativeRenderSwapSourceGuard::test_app_js_canonical_render_uses_helper PASSED [ 83%]
mvp_site/tests/test_god_mode_narrative_render_swap.py::GodModeNarrativeRenderSwapSourceGuard::test_helper_module_is_loaded_before_streaming_and_app PASSED [ 91%]
mvp_site/tests/test_god_mode_narrative_render_swap.py::GodModeNarrativeRenderSwapSourceGuard::test_streaming_js_finalizer_uses_helper PASSED [100%]

============================== 12 passed in 0.28s ==============================
```

12/12 PASS in 0.28s. Contract covers:
- 4 required cases (god+empty→placeholder, god+non-empty→unchanged, non-god+empty→empty, non-god+non-empty→unchanged)
- Legacy `"undefined"` string coercion (existing call sites pass the literal string)
- Whitespace-only narrative
- Both-empty
- Single-source-of-truth constant guard
- Source-load-order guard

Generic phrasing only — no campaign-specific content (Warcraft / Noctune BANNED from tests per spec).

### Step 3 — Commit with worker prefix

```bash
$ git add mvp_site/frontend_v1/js/godModeNarrativeRender.js \
        mvp_site/frontend_v1/app.js \
        mvp_site/frontend_v1/index.html \
        mvp_site/frontend_v1/js/streaming.js \
        mvp_site/tests/test_god_mode_narrative_render_swap.py

$ git -c user.name='hermes-claudem' -c user.email='noreply@hermes.local' \
    commit -m 'claudem/minimax-M3: feat(frontend): swap god-mode narrative fallback to generic placeholder
...'
[feat/god-mode-no-narrative-render 66402d8be3] claudem/minimax-M3: feat(frontend): swap god-mode narrative fallback to generic placeholder
 5 files changed, 350 insertions(+), 7 deletions(-)
```

Commit `66402d8be3` uses the WORKER's `claudem/minimax-M3:` prefix, NOT the parent session's model prefix — because the WORKER started the work. Lying about commit attribution is a SOUL.md violation.

### Step 4 — Push to clean branch

```bash
$ git push -u origin HEAD:refs/heads/feat/god-mode-no-narrative-render
remote: Create a pull request for 'feat/god-mode-no-narrative-render' on GitHub by visiting:
remote:      https://github.com/jleechanorg/worldarchitect.ai/pull/new/feat/god-mode-no-narrative-render
To https://github.com/jleechanorg/worldarchitect.ai
 * [new branch]            HEAD -> feat/god-mode-no-narrative-render
branch 'feat/god-mode-no-narrative-render' set up to track 'origin/feat/god-mode-no-narrative-render'.

$ git ls-remote origin feat/god-mode-no-narrative-render
66402d8be340784da0b551972dadfd3104c2b313	refs/heads/feat/god-mode-no-narrative-render
```

Remote HEAD matches local commit. Push clean, no force needed (first push).

### Step 5 — Open PR via REST draft

```bash
$ gh_token=$(gh auth token)
$ python3 -c "
import json, urllib.request
gh_token = ...
payload = {
    'title': 'feat(frontend): swap god-mode narrative fallback to generic placeholder',
    'body': open('/tmp/wa-pr-body.md').read(),
    'head': 'feat/god-mode-no-narrative-render',
    'base': 'main',
    'draft': True,
}
req = urllib.request.Request(
    'https://api.github.com/repos/jleechanorg/worldarchitect.ai/pulls',
    data=json.dumps(payload).encode(),
    headers={'Authorization': f'Bearer {gh_token}', 'Accept': 'application/vnd.github+json', 'Content-Type': 'application/json', 'User-Agent': 'hermes-agent'},
    method='POST',
)
with urllib.request.urlopen(req, timeout=30) as resp:
    data = json.loads(resp.read())
    print(f\"STATUS: {resp.status}  NUMBER: {data.get('number')}  URL: {data.get('html_url')}  HEAD_SHA: {data.get('head', {}).get('sha')}\")"
STATUS: 201  NUMBER: 9094  URL: https://github.com/jleechanorg/worldarchitect.ai/pull/9094  HEAD_SHA: 66402d8be340784da0b551972dadfd3104c2b313
```

PR body passed `~/.smartclaw/lib/outbound_secret_gate.py check` clean (exit 0, no redacted values).

### Step 6 — Flip to ready via GraphQL

First attempt with REST PATCH:
```bash
$ python3 -c "
import json, urllib.request
req = urllib.request.Request(
    'https://api.github.com/repos/jleechanorg/worldarchitect.ai/pulls/9094',
    data=json.dumps({'draft': False}).encode(),
    headers={'Authorization': '...', 'Content-Type': 'application/json'},
    method='PATCH',
)
with urllib.request.urlopen(req, timeout=15) as resp:
    data = json.loads(resp.read())
    print('draft after PATCH:', data.get('draft'))"
draft after PATCH: True
```

**REST PATCH silent-no-op confirmed** (per `github-pr-draft-toggle` skill). Switch to GraphQL:

```bash
$ node_id=$(gh api repos/jleechanorg/worldarchitect.ai/pulls/9094 --jq .node_id)
PR_kwDOO8L8Qs8AAAABAO5yXg

$ echo '{"query":"mutation($prId: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $prId}) { pullRequest { id isDraft number } } }","variables":{"prId":"'"$node_id"'"}}' \
  | gh api graphql --input -
{
  "data": {
    "markPullRequestReadyForReview": {
      "pullRequest": {
        "id": "PR_kwDOO8L8Qs8AAAABAO5yXg",
        "isDraft": false,
        "number": 9094
      }
    }
  }
}

$ gh api repos/jleechanorg/worldarchitect.ai/pulls/9094 --jq .draft
false
```

PR #9094 ready for review.

## CI green per WA repo's local `/green` definition

WA repo's `.claude/skills/pr-green-definition.md` redefines `/green` as **2 gates**: CI green + no merge conflicts. CodeRabbit/Bugbot/Codex are advisory only.

### Check-run progression

Polled every 60-90s for ~10 min. Final state:

**PASSING (12)**:
- Design Doc Grep Gates ✅ (12/12 sub-gates)
- Detect Changed Paths ✅ (x2)
- Green Gate ✅ (load-bearing WA gate)
- Directory tests (core-mvp-1/2/3) ✅✅✅
- Light/Fantasy Compliance Gate ✅
- Python Linting (Ruff) ✅
- Python Type Checking (mypy) ✅
- Tests Required Gate ✅
- Wizard Mobile Scroll/CSS Regression ✅
- Planning Choices Composer Placement ✅
- deploy-preview ✅
- Merge commit validation ✅
- import-validation ✅
- detect-changes ✅ (x2)
- limit-pr-runs ✅ (x2)

**IN_PROGRESS (1)**:
- Directory tests (core-tests) — the only remaining check

**NEUTRAL (1)**: Cursor Bugbot — couldn't run (vendor usage limit)

**MERGEABLE: TRUE**. **DRAFT: FALSE**. **STATE: OPEN**.

### Vendor review capacity limits (NOT gates per WA repo local rule)

All three vendor review bots hit capacity limits simultaneously:
- **CodeRabbit**: "Review limit reached. 82 included PR review attempts over the past 7 days set your current allowance at 1 review per hour. Next review available in 36 minutes."
- **Cursor Bugbot**: "Bugbot couldn't run - usage limit reached"
- **Codex (chatgpt-codex-connector[bot])**: "You have reached your Codex usage limits for code reviews"

Per WA repo's `.claude/skills/pr-green-definition.md`: *"CodeRabbit and Bugbot are optional advisory reviewers, never gates."* These are advisory noise, not blockers. Documented in the in-thread reply; not re-triggered blindly.

## Merge commit validation: verified locally

Per WA repo's "Slow CI never blocks `/green`" rule + env-preferences.md "Slow/backlogged CI" rule:

```bash
$ git log origin/main..HEAD --oneline --merges
(empty)
$ git log origin/main..HEAD --oneline
66402d8be3 claudem/minimax-M3: feat(frontend): swap god-mode narrative fallback to generic placeholder
$ git log origin/main..HEAD -1 --format="%H %P"
66402d8be340784da0b551972dadfd3104c2b313 88756c1f8ba996c6475604abc8dcf10f91b37740
```

1 commit on top of `origin/main` HEAD `88756c1f8b`. No merge commits. Single non-merge parent. **Clean replay off `origin/main`.** Per `pr-clean-branch-from-main-no-history-bloat` ✅.

## Babysit cron armed

```bash
$ hermes cron create --name wa-9094-babysit-merge-self-cancel --schedule 5m ...
job_id: 0bc4d9dba999
```

Per `babysit-cron-self-cancel-discipline`: cron polls `gh pr view 9094 --json state`, self-cancels via `cronjob action=remove job_id=$CRON_JOB_ID` when `state in {MERGED, CLOSED}`. 2-hour max lifetime.

## Outcome

- **Worker hit max-turns at the implement→ship boundary** (60-turn budget exhausted on implementation + verification).
- **Inline takeover recipe (pitfall #15) executed verbatim** on a non-script frontend change — confirms class-level applicability.
- **PR #9094** open at https://github.com/jleechanorg/worldarchitect.ai/pull/9094, ready for review, mergeable=true.
- **All 12 contract tests pass + 12 of 13 active CI checks PASS** (only core-tests in_progress at babysit start).
- **WA repo's local `/green` definition applied** — CodeRabbit/Bugbot/Codex vendor limits documented but not blocking per repo rule.
- **Awaiting human `MERGE APPROVED`** per WA repo policy (most recent live message must contain `MERGE APPROVED` before any merge).

## Lessons learned

1. **Pitfall #15 (implement→ship boundary inline takeover) is class-level, not shell-script-specific.** Verified on frontend contract test + Python tests + JS changes. The 5-step recipe generalizes cleanly.

2. **Pitfall #16 (new) — REST PATCH silent-no-ops on draft flag.** First REST PATCH returned `draft: True` (no-op despite HTTP 200). Must use GraphQL `markPullRequestReadyForReview` with `--input -` (the only known-working invocation per `github-pr-draft-toggle` skill).

3. **Pitfall #17 (new) — Repo-local `.claude/skills/pr-green-definition.md` overrides the global 7-condition Green Definition.** WA repo explicitly redefines `/green` as 2 gates (CI + mergeable). CodeRabbit/Bugbot/Codex vendor capacity limits are NOT blocking under the local rule.

4. **Worker provenance in commit attribution matters.** Used `claudem/minimax-M3:` (worker's prefix) not `claude/<other-model>:` or `human:` (parent session's) — because the worker started the work. SOUL.md provenance requirement.

5. **`tee` output is fully buffered for claudem TUI** (pitfall #7 confirmed again). Worker produced only 3 lines of tee output despite ~52 min runtime. Worktree-state polling is the only reliable observability surface.
