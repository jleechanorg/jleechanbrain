---
name: repo-agents-evidence-contract
version: 1.1.0
description: "Honor AGENTS.md /es proof before declaring a PR done."
tags: ["autonomy", "evidence", "AGENTS-md", "es", "PR-done-criterion", "deploy-verification"]
category: workflow
triggers:
  - "is this proven"
  - "show me screenshots"
  - "es level proof"
  - "/es"
  - "/er"
  - "make sure we have"
  - "fresh account proof"
  - "captioned video"
  - "AGENTS.md requires"
changelog:
  - "1.0.0 (2026-08-14): New umbrella skill. Verified PR #8923 caught Cloud Run commit-sha label overwrite via deployed-preview Playwright screenshot. Recipe: gcloud revision verification + Playwright headless capture + codex /er trigger + fresh-account code-path walkthrough."
  - "1.1.0 (2026-08-16): Added anti-patterns for AI-Terminal-lobby self-report false-green (PR #8829) — agent's own summary markdown claimed '21 CI checks passing / /er PASS / Green Gate PASS' but actual `gh pr checks` showed FAIL; AND stitched-mock-HTML labels being captioned as real /es evidence. New pitfall: verify the lobby's claims against `gh pr checks` output, not the polished markdown. New pitfall: mock HTML labeled 'Mock HTML; rendered statically' is a smoking gun, never /es contract evidence."
  - "1.2.0 (2026-08-22): New 'Post-merge /es cleanup' section + new trigger row for operator signal 'remove evidence from PR into PR desc with gist url per /es standards'. Verified PR #9206 (mobile UX) → PR #9260 (chore: remove in-repo evidence). Canonical pattern: gist URL in PR body, not `docs/evidence/<N>/` trees. Source of truth: `.claude/skills/evidence-standards.md` line 190. Also flagged three user-owned skills that need curator adopt + patches — see the dedicated section below."

  - "**User-owned skills that need curator adopt + a small patch to absorb lessons from this session (2026-08-22, PR #9260):**"
  - "`workflow/drive-pr-to-green` — needs a '`gh pr checks` shows stale cancelled runs as fail' pitfall and a 'worldai has ZERO required status checks; only MERGE APPROVED gates merge' pitfall. The current 'never run gh pr merge directly' rule applies only when skeptic-cron exists; for repos that don't have it (e.g. worldai), the explicit `MERGE APPROVED` signal supersedes. Run `hermes curator adopt workflow/drive-pr-to-green` to enable."
  - "`workflow/always-pr-never-local-edit` — needs a one-line clause on `claudem -p --max-turns N` scaling: a 2-file deletion fix finishes in ~40 turns; don't always default to 120. Run `hermes curator adopt workflow/always-pr-never-local-edit`."
  - "`pr-ready-checklist` — Gate 3 currently treats `CANCELLED` conclusions as failures, but on every draft→ready flip the prior run is cancelled and shows up as noise. The gate should distinguish 'real FAILURE' from 'cancelled draft-stage run' (filter on workflowName matching `detect-changes|limit-pr-runs|skepti` is the canonical pattern). Also the example PASS reply assumes Skeptic-cron — for repos without it (worldai, per AGENTS.md), the merge gate is operator-typed `MERGE APPROVED`. Run `hermes curator adopt pr-ready-checklist`."
related_skills:
  - finish-the-job
  - drive-pr-to-green
  - wa-visual-proof-playwright
  - inline-attach-evidence
---

# Repo AGENTS.md Evidence Contract

The umbrella for any finish-the-job task that touches paths flagged by a repo's AGENTS.md as requiring `/es`, `/er`, captioned video, or fresh-account proof. Closes the half-finished-rollout gap where the agent stops at CI green without honoring the repo's evidence contract.

## Why this skill exists

`finish-the-job` defines the end-state contract for any user goal: green PR merged, PR open with green CI awaiting review, local state change verified, or dry-run to local machine. **But every repo's AGENTS.md can add layers on top of that contract** — most commonly `/es` evidence for non-test changes under `mvp_site/**`, captioned video for user-visible changes, fresh-account proof for default-value changes, or `/er` Evidence Review as a separate gate from Green Gate.

When the user replies *"Is this finally working/proven? Make sure we have /es level proof"* after the agent reported *"✅ Done: PR #N open + green, awaiting your review"*, the agent must treat that as a finish-the-job re-pivot — NOT a new task. The repo's evidence contract was not honored on the first pass; honor it now.

## When this fires

| Trigger | Meaning |
|---|---|
| User replies *"is this finally working/proven?"* after a "done" reply | The repo's evidence contract was not honored; re-pivot to `/es` |
| User says *"show me screenshots"* on a PR that touched frontend | Visual evidence is owed; capture + inline-attach |
| User says *"fresh account proof"* or *"prove new users get X"* | Code-path walkthrough + runtime check needed |
| User types `/er` as a PR comment | Codex Evidence Review gate; poll for verdict |
| The repo's AGENTS.md says *"Non-test changes under `<path>` require `/es`"* and the agent is about to declare done on such a PR | `/es` evidence is mandatory before "done" |
| The repo's AGENTS.md says *"User-visible changes require captioned video"* | Capture video + embed |
| The PR description or skill list mentions `/es`, `/er`, captioned video, or fresh-account proof | The contract applies; verify before claiming done |
| User says "remove evidence from PR into PR desc with gist url per /es standards" (post-merge) | The PR's evidence has done its job; canonical pattern is gist URL in PR body, not in-repo `docs/evidence/<N>/` trees — see "Post-merge /es cleanup" section |
| An AI Terminal lobby post (e.g. `worktree_<name>`) auto-posts an "Evidence & Preview Summary" to a Slack channel with numbered checklist claims like "21 CI checks passing / /er PASS / Green Gate PASS" | The lobby's polished markdown is unverified until proven against `gh pr checks <N>` output — re-run the gates yourself before accepting the claim |
| A "screenshot" PR attachment is captioned BEFORE / ACTION / AFTER but a side-by-side diff shows two frames are pixel-identical, OR the page source literally contains "Mock HTML; rendered statically" | The visual evidence is a stitched mock, not a Playwright capture of the deployed preview — re-capture via `wa-visual-proof-playwright` against the live `*.run.app` URL |

## How to apply — the 4-step `/es` pass

### Step 1 — Read AGENTS.md (or equivalent contract)

Before claiming done, `read_file` the repo's `AGENTS.md`, `CLAUDE.md`, `.claude/skills/evidence-standards.md`, or `.cursor/rules/*.mdc`. Identify:

- **/es** requirement — usually *"Non-test changes under `mvp_site/**` require `/es`. Unit tests and mock-mode results are supporting evidence only."*
- **/er** gate — usually *"`/er` Evidence Review verdict required"*
- **Captioned video** — usually *"User-visible changes require captioned video tied to the tested SHA"*
- **Fresh-account proof** — usually implicit; any default-value change
- **Live-LLM evidence** — usually for changes affecting inference behavior

If any applies, the PR's done-criterion extends past CI green.

### Step 2 — Codex `/er` Evidence Review (when required)

```bash
gh pr comment <N> --repo <owner>/<repo> --body "/er"
```

Then poll:

```bash
for i in {1..20}; do
  sleep 30
  CNT=$(gh api "repos/<owner>/<repo>/issues/<N>/comments" --jq \
    '[.[] | select(.user.login | test("codex|chatgpt-codex"; "i"))] | length')
  echo "[$i] codex comments: $CNT"
  [ "$CNT" -gt 0 ] && break
done
gh api "repos/<owner>/<repo>/issues/<N>/comments" --jq \
  '.[] | select(.user.login | test("codex|chatgpt-codex"; "i")) | {user: .user.login, body: .body}'
```

**Wait — verify before posting another `/er`.** The skill `finish-the-job` auto-arm cron + inline `/er` trigger + cron babysit can all generate `/er`-prefixed comments in the same minute (verified PR #8923, three `/er` comments at `23:48Z`, `23:58Z`, `23:58Z`). Check `gh api graphql` for prior `/er` comments before posting.

### Step 3 — Browser screenshot of deployed preview

Get the preview URL from the deploy-preview workflow output (`https://mvp-site-app-s1-i6xf2p72ka-uc.a.run.app` is the canonical pattern for jleechanorg/worldarchitect.ai). Then:

```bash
# Re-verify the live revision at capture time (NOT at workflow-finish time)
gcloud run revisions list \
  --service=mvp-site-app-s<N> \
  --region=us-central1 \
  --project=worldarchitecture-ai \
  --format="table(metadata.name,metadata.labels.commit-sha,status.conditions[0].status)" \
  --limit 3
```

**Pitfall — Cloud Run commit-sha label overwrite (verified 2026-08-14, PR #8923):** the deploy-preview workflow reports `Service correctly labeled: pr-number=N, commit-sha=<HEAD>` at workflow-finish time, but the live revision's label can be overwritten by a later deploy. If the live revision's commit-sha does NOT match your PR HEAD, the deploy is stale — file a follow-up issue, do NOT take the screenshot, do not claim `/es`.

Then capture (Playwright Python — works when `browser_exec` is blocked by Chrome remote-debugging approval):

```python
from playwright.sync_api import sync_playwright

URL = "https://mvp-site-app-s1-i6xf2p72ka-uc.a.run.app/settings"

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, args=["--no-sandbox", "--disable-dev-shm-usage"])
    context = browser.new_context(viewport={"width": 1440, "height": 900})
    page = context.new_page()
    page.goto(URL, wait_until="networkidle", timeout=30000)
    page.screenshot(path="/tmp/wa-evidence/01_settings_loaded.png", full_page=True)

    # Force-open the Gemini model select (settings.js renders a native <select>)
    page.evaluate("""
        const selects = document.querySelectorAll('select');
        for (const s of selects) {
            const opts = Array.from(s.options).map(o => o.text);
            if (opts.some(t => t.toLowerCase().includes('gemini'))) {
                window.__geminiSelect = s;
            }
        }
        if (window.__geminiSelect) {
            window.__geminiSelect.setAttribute('size', '10');
            window.__geminiSelect.style.position = 'static';
        }
    """)
    page.wait_for_timeout(500)
    page.screenshot(path="/tmp/wa-evidence/03_dropdown_open.png", full_page=True)

    options = page.evaluate("Array.from(window.__geminiSelect.options).map(o => ({value: o.value, text: o.text}))")
    default_value = page.evaluate("window.__geminiSelect.value")
    print(f"Default: {default_value!r}")
    for o in options:
        print(f"  - {o['value']!r}: {o['text']!r}")

    browser.close()
```

Then `vision_analyze` the screenshot to verify the rendered dropdown matches the printed option list — the user's bar is "show me the new settings working," not "tell me the dropdown has 5 options."

Commit the screenshot into the PR branch under `evidence/<topic>.png` and embed via markdown image syntax:

```markdown
![Settings dropdown showing gemini-3.7-flash + gemini-3.6-flash default](https://github.com/OWNER/REPO/blob/BRANCH/evidence/settings_dropdown.png?raw=true)
```

### Step 4 — Fresh-account proof

For default-value or catalog changes, prove the new default lands for a brand new user. Two methods:

(a) **Code-path walkthrough** — grep for where the default is set on user creation, confirm it matches the new value, confirm no override path on signup.

```bash
grep -rn "DEFAULT_GEMINI_MODEL\|model_preference\|gemini_model" \
  mvp_site/main.py mvp_site/constants.py mvp_site/frontend_v1/js/settings.js
```

(b) **Live signup test** — programmatically create a fresh Firebase Auth account, hit the user-creation path, verify the resulting user document has `model_preference: <new default>`. Requires API access; only available when the env has Firebase Admin SDK credentials.

For catalog-only changes, the screenshot from Step 3 IS the fresh-account proof (new users see the same dropdown).

## Final reply shape

When the `/es` pass completes, the final reply MUST list each piece of evidence with its proof artifact. Format:

```
🚨 /es evidence caught a real bug — PR #N source is correct, but deployed preview is stale.

| Item | Status |
|---|---|
| Source code (PR #N) | ✅ Correct: ... |
| Local unit tests | ✅ N passed, M subtests passed |
| Codex `/er` verdict | ✅ PASS / ⚠️ NOT APPROVED / ⏳ pending |
| Deployed preview (gcloud verify) | ✅ live revision label matches HEAD / ❌ label = <other-sha> |
| Browser screenshot | ✅ evidence/<file>.png committed to branch |
| Fresh-account proof | ✅ / 🚨 / N/A |
| Live-LLM evidence | ✅ / N/A |

Smoking gun: <one-line if any>

PR: https://github.com/<owner>/<repo>/pull/<N>
Branch: <branch> @ <sha>
Evidence: evidence/<file>.png in the branch
```

No follow-up question if `/es` passed. If `/es` caught a bug, surface it directly with the specific deploy-mismatch evidence and let the user decide whether to investigate the deploy pipeline or merge on source-only.

## Post-merge /es cleanup (verified PR #9206 → PR #9260, 2026-08-22)

When a PR is merged, in-repo evidence trees become redundant — the canonical `/es` pattern keeps evidence at a **gist URL**, not in `docs/evidence/<N>/`. Per `.claude/skills/evidence-standards.md` line 190: *"The `/es` draft-phase evidence check accepts `gist.github.com/` URLs; prefer that over `docs/evidence/` tree links in the PR body."*

Operator signal: "remove evidence from PR into PR desc with gist url per /es standards" (often paired with "merge approved") = open a follow-up PR that:

1. **Deletes** in-repo evidence trees:
   - `docs/evidence/<N>/` (per-PR claim map + mp4/gif if any)
   - `evidence/<pr-slug>_<date>/` (raw PNG/GIF screenshots)
2. **Replaces** them in the new PR's description with the original **gist URL** (e.g. `https://gist.github.com/<user>/<id>`).
3. Uses a fresh branch from `origin/main` (`git worktree add -b chore/remove-merged-pr-<N>-evidence ../wt-remove-<N>-evidence origin/main`).
4. Single commit, scoped tight — `git rm -r` only the two paths, no other code.
5. **Do NOT auto-merge** — the operator's "merge approved" only authorizes merging THIS follow-up, not later ones; default to draft + flip ready + merge.

Why a follow-up PR (not amending the merged commit): upstream-first merge policy + AGENTS.md merge contract require operator approval for every merge; amending a merged commit would be a force-push and bypass that contract.

Scope warning: worldai's `evidence/` top-level dir is full of historical `evidence/<PR-N>/` subdirs (e.g. `evidence/8794/`, `evidence/8952/`, `evidence/composer-alignment/`). Only delete the specific `<N>` paths from the merged PR — never wildcard `evidence/*`.

## Anti-patterns

- � **Stopping at "PR is /ready, Green Gate PASS"** when AGENTS.md mandates `/es` — the done-criterion extends past CI green.
- ❌ **Trusting deploy-preview workflow's commit-sha label at workflow-finish time** — the live revision label can be overwritten by a later deploy. Re-verify at capture time.
- 🚨 **Posting multiple `/er` comments in the same minute** — check `gh api graphql` first.
- ❌ **Claiming /es based on source-diff only** — the user wants the deployed preview to show the new behavior, not just the source.
- ❌ **Skipping fresh-account proof on default-value changes** — explicit default flip requires explicit fresh-account proof.

## Cross-references

- `finish-the-job` — parent skill; defines the 4 end-states
- `drive-pr-to-green` — PR-fix phase; this skill extends its done-criterion
- `wa-visual-proof-playwright` (USER-OWNED; recommend `hermes curator adopt wa-visual-proof-playwright`) — Playwright capture recipe; add Cloud Run label pitfall
- `inline-attach-evidence` (USER-OWNED) — 3-stage Slack upload recipe
- `workflow/evidence-review-non-production-adapter` — adapter for `/er` on docs/skill/test-only diffs (does NOT apply when `mvp_site/**` is touched — canonical `/er` applies)
