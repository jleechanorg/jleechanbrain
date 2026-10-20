---
name: claudem-worker-max-turns-takeover
description: "Recover when claudem --continue hits max-turns."
version: 1.5.0
tags: ["claudem", "max-turns", "ironclad", "finish-the-job", "pr-takeover", "tee-buffering", "max-turns-budget", "delegate-task-timeout", "retry-with-tighter-scope", "review-comment-staleness", "partial-edit-recovery"]
changelog:
  - "1.3.0 (2026-08-13): Two new pitfalls + one verified recovery pattern from PR #8863 v3 review-comment iteration. (12) Review comments are pinned to the PR's base SHA — branching off newer origin/main means comments may reference functions that no longer exist or edge cases already covered. Pre-verify each comment is still valid on the worktree base BEFORE dispatching a fix worker; this can collapse 3 fixes into 1. (13) When a worker hits max-turns mid-edit, it may leave an uncommitted half-edit with duplicate function definitions (Python syntax-OK because the second def wins). Recovery: `git checkout -- <file>` since uncommitted work is safe to revert. (14) Pre-compute exact line numbers, file paths, and 'do not read AGENTS.md/skills' instructions into the dispatch prompt — a 4.5KB targeted prompt completes what a 6.5KB open-scope prompt burned 60 turns on."
  - "1.4.0 (2026-08-18): Pitfall 15 — When a clean-replay worker hits max-turns with implementation done but no commit/push/PR-create yet (the bash-script + shell-test dispatch shape), do NOT re-dispatch round 2. Accept the dirty tree and finish inline. Verified PR #828 (clean replay of PR #817 onto current origin/main, scripts/ao-progress-reporter.sh + tests/test_ao_progress_reporter_cross_machine.sh). Worker exited at the canonical-bash-test step with the two files fully edited but uncommitted. Re-dispatch would have re-applied the edits and produced a SECOND commit on top. The correct recovery: (a) `bash -n` both files; (b) run the focused shell test inline; (c) commit with the worker's model prefix `claudem/minimax-M3:` — NOT a fresh `claude/<model>:` prefix, because the work was started by the worker; (d) push via the upstream remote (NOT the worker's polluted-branch head); (e) open the PR via REST `gh api POST /repos/{owner}/{repo}/pulls` (more reliable than `gh pr create` when reviewer-rate-limit pressure is the reason the original PR was stuck). The broader class: when a worker times out at the boundary BETWEEN two phases — between 'implement' and 'ship' — finish shipping inline rather than restarting implementation. The remaining work is always shorter than the work already done."
  - "1.6.0 (2026-09-16): Pitfall 25 verified on PR #9874 sibling-test follow-up — worker landed a *clean, minimal, direction-wrong* diff (1-line test fixture change that contradicted the test's own title and reintroduced the inverse bug the PR was meant to fix). Parent had to `git checkout HEAD -- <file>` and re-derive inline. Distinct from #13 (dupe defs), #15 (mid-phase), #24 (scope-incomplete). Title-vs-fixture diagnostic added: when a sibling test fails after a contract change, check whether the test's title matches its fixture under the new contract; if not, update the assertions (not the fixture). Brief-design rule added: when parent has identified a single correct path, name it and forbid alternatives — do NOT enumerate alternatives 'in priority order'. See `references/pitfall-25-worker-landed-correct-shape-wrong-direction.md`."
  - "1.5.0 (2026-08-19): Two new verified pitfalls from jleechanorg/worldarchitect.ai PR #9094 (frontend god-mode render-swap contract test). (16) The 5-step inline takeover recipe from pitfall #15 is class-level, not shell-script-specific — verified on a non-script frontend change: 5 files in worktree (3 modified, 2 untracked) → 12/12 pytest pass inline → commit with `claudem/minimax-M3:` prefix → `git push -u origin HEAD:refs/heads/feat/...` → REST `gh api -X POST repos/.../pulls` with `draft:true` body returned 201 → flip to ready via GraphQL `markPullRequestReadyForReview` mutation (REST PATCH silent-no-ops on draft flag, see `github-pr-draft-toggle` skill). (17) When the target repo has its own `.claude/skills/pr-green-definition.md` (verified: WA repo redefines `/green` as 2 gates = CI + mergeable; CodeRabbit/Bugbot/Codex are explicitly NOT gates), use THAT file as the source of truth for the green gate — NOT the global 7-condition Green Definition umbrella. PR #9094 had CodeRabbit + Bugbot + Codex all hit vendor usage limits simultaneously; per WA's local definition none of those are gates, so the PR was reported green without waiting 36 min for CR to unblock. See new reference `references/pr-9094-2026-08-19-verified-case.md` for full transcript."
  - "1.2.0 (2026-08-13): Three new pitfalls verified in REVISIT-backlog sweep. (9) delegate_task has a hard 600s timeout that kills PR cycles mid-push — use claudem --bg for any coding dispatch that includes commit/push/PR-creation. (10) When a delegate_task subagent times out, retry with TIGHTER SCOPE (skip slow paths, hit local cache first) — verified 45s retry on a 600s-timeout task. (11) Background claudem workers should pass notify_on_complete=true for bounded tasks."
---

# Claudem worker max-turns takeover

> **Quick dispatch to the right pitfall:**
> | Worker exit shape | Pitfall |
> |---|---|
> | Dupe function defs in diff | #13 |
> | Worker landed edits, stopped at implement→ship seam | #15 |
> | Worker wrote a test but missed prod-code sites | #24 |
> | Worker landed a clean but **direction-wrong** edit | #25 |
> | Worker committed but evidence missing | #19 |
> | Worker wrong author on commit | #18 |
> | PR green per repo-local rules, not 7-condition global | #17 |


Three `claudem --continue` rounds at 80/60/40 turns are not enough for "produce a PR + wait for CI + capture video + post /es + /er + run /test-realistic + final Slack reply". Each round costs ~30-50 min wall clock and stalls on infrastructure steps. When a round hits max-turns with the ironclad middle layer provable (PR open + mergeable, evidence committed, tests green for the worker's diff), **take over INLINE rather than dispatching round 4**.

## Verified case (2026-08-09, PR #8829 worldarchitect.ai V2 composer card)

- Round 1: 80 turns — pushed commit `4d1df5359b` + opened PR + most CI green.
- Round 2: 60 turns — pushed a no-op retrigger commit `c66f6b6801`; Light/Fantasy Compliance Gate passed on retry.
- Round 3: 40 turns — captured 3 PNGs (BEFORE/ACTION/AFTER) locally; no commit, no /es, no /er, no /test-realistic.
- Round 4 (inline): committed PNGs (`9f06ed348b`), ran /test-realistic structural subset (250/250 pass), documented pre-existing `TestStreamingRawRequestPayloadPopulated` failures via same-name reproduction, posted final reply with PARTIAL labels on /es and /er (GitHub secondary rate limit blocked those).

## Verified case (2026-08-10, jleechanorg/worldarchitect.ai#8839 cache-churn fix)

Single-round dispatch with `--max-turns 80`. Worker hit max-turns at 52 min wall-clock after committing `2ab7c6a865` and pushing `fix/cache-churn-6aXYri` but BEFORE running `gh pr create`. Branch was clean (5 files / +507/-15) and on origin/main; the only remaining work was `gh pr create` + initial CI probe.

Recovery: took over inline from Hermes session. Wrote the PR body directly (cache-buster source list, cross-campaign evidence #8501, RED→GREEN test summary, reference jleechanorg/worldarchitect.ai#8839) and POSTed via REST to `https://api.github.com/repos/jleechanorg/worldarchitect.ai/pulls` with `Authorization: Bearer $GH_TOKEN`. PR #8839 opened as draft on first try. The canonical `gh-safe-publish` wrapper was NOT used because of its known line-14 case-parse bug.

This is the new canonical case for **single-round max-turns takeover on PR-creation dispatch**, distinct from the multi-round case above. Key differences:

| Property | Round-1 (#8829) | Single-round (#8839) |
|---|---|---|
| Number of rounds before inline | 3 (80/60/40 turns) | 1 (80 turns) |
| Wall-clock to max-turns | ~120 min cumulative | 52 min |
| Branch state at takeover | committed + pushed + PR open + CI mostly green | committed + pushed, no PR |
| Ironclad middle layer | committed evidence + green tests for worker's diff | n/a (no diff yet at takeover — takeover IS creating the PR) |
| Remaining work at takeover | post /es, /er, /test-realistic; upload PNGs | open PR via REST; probe initial CI |
| Skill to load for the inline | `finish-the-job` | this skill (single-round variant) |

For the raw session evidence — worker bash PIDs, tee-log buffering proof, the literal curl that recovered the PR, and the turns-per-phase table that motivated the `--max-turns 120` rule — see `references/pr-8839-2026-08-10-verified-case.md`.

## Decision rule

After a `claudem --continue` round hits max-turns, check three things in order:

1. **Is the PR open and mergeable?** (`gh pr view <N> --json state,mergeable` → `state=open, mergeable=true`) — YES → middle layer salvaged; take over inline.
2. **Is the ironclad middle layer provable?** (evidence committed, tests green for the worker's diff, pre-existing failures documented) — YES → take over inline.
3. **Is the remaining work purely mechanical?** (post comments, upload evidence, run /test-realistic) — YES → take over inline.

If all three answer YES, do not dispatch round 4 — take over inline.

## Pitfalls 15 — finish shipping inline when the worker timed out at the implement→ship boundary

Some worker dispatches cover an unusually long phase plan: read live evidence + implement in two files (script + shell test) + run shell tests + commit + push + open PR + verify head SHA + post Slack reply. Even at `--max-turns 60` (matching the 2026-08-18 PR #828 case — a clean replay of PR #817 onto current `origin/main`), the worker can hit max-turns at the implement→ship boundary with both implementation files fully edited but uncommitted.

**Default reaction of "re-dispatch round 2" is wrong here.** A fresh worker would re-read the worktree, re-derive context, and re-apply the edits (or worse, add a SECOND commit on top of the uncommitted ones, polluting the replay branch). The right action is the ironclad-middle-layer-snapshot recovery pattern:

```bash
# 1. Snapshot what the worker did
cd "$WT"
git status --short                     # expect 2 M files (no commits, no adds)
git diff --stat origin/main..HEAD      # expect NOTHING (worker did not commit)
bash -n scripts/ao-progress-reporter.sh
bash -n tests/test_ao_progress_reporter_cross_machine.sh

# 2. Run the focused test inline (NOT via re-dispatched worker)
bash tests/test_ao_progress_reporter_cross_machine.sh 2>/tmp/r.stderr >/tmp/r.stdout
tail -2 /tmp/r.stdout
# expect: ==== Cross-machine reporter tests: PASS=N FAIL=0 ====

# 3. Commit with the WORKER'S model prefix (the worker started the work)
git add scripts/ao-progress-reporter.sh tests/test_ao_progress_reporter_cross_machine.sh
git -c user.name='<worker-attributed>' -c user.email='<noreply>' \
  commit -m 'claudem/minimax-M3: <short subject>'

# 4. Push to a CLEAN branch (NOT the worker's mid-edit branch name)
git push -u origin HEAD:refs/heads/fix/<slug>-current-<date>

# 5. Open PR via REST (more reliable than `gh pr create` when reviewer
#    rate-limit pressure is why the original PR was stuck).
gh api -X POST repos/<owner>/<repo>/pulls \
   -f title='...' -f head=<branch> -F base=main -F body='...'
```

**Three error paths this avoids:**

| Anti-pattern | Failure mode |
|---|---|
| Re-dispatching the SAME prompt "give it more turns" | Worker re-derives worktree context, re-applies edits, may add 2nd commit, blurs the 1-commit clean-replay identity |
| Re-dispatching a TIGHTER-SCOPE prompt asking to commit-and-ship | Worker without test/implementation memory may amend in ways that break tests; even if it succeeds, you've consumed a second round's worth of dispatch overhead |
| Inlining but **committing under a `claude/<other-model>` prefix** because the *parent session* uses a different model | The commit message lies; the work was started by a worker, attributed to a different one. Use the worker's prefix. |

**Class: the implement→ship boundary is the classic recovery seam.** Workers blow budgets between implementation verification and shipping because the two phases have different latency profiles — implementation is interactive (model reasoning per turn), shipping is mostly API-bound (commit, push, PR-create each take 1-3 turns with sub-second model work). When a worker burns 60 turns on implementation and lands both files, the shipping work is roughly 6-10 more turns (a separate worker could do it in 8 minutes — same as inline). Inlining saves the worktree-setup overhead and the model-context re-derivation cost.

Verified case: PR #828 (2026-08-18 clean replay of PR #817) — worker hit max-turns at the canonical-bash-test step (between implement and ship). Inline parent-session finished commit + push + PR-create in 4 tool calls. Without this pattern, the clean replay would have been a round-2 dispatch with a polluted branch and review-blurring commit history.

## Pitfall 16 — Inline-takeover recipe verified on non-script work (frontend contract test, 2026-08-19 PR #9094)

The 5-step inline takeover recipe from pitfall #15 is class-level — it generalizes to any worker dispatch that lands implementation files but burns the budget at the implement→ship boundary. Verified on PR #9094 (jleechanorg/worldarchitect.ai, frontend god-mode render-swap contract test):

1. **Snapshot**: `git status --short` showed `M  mvp_site/frontend_v1/app.js`, `M  mvp_site/frontend_v1/index.html`, `M  mvp_site/frontend_v1/js/streaming.js`, `?? mvp_site/frontend_v1/js/godModeNarrativeRender.js`, `?? mvp_site/tests/test_god_mode_narrative_render_swap.py` (5 files, 0 commits ahead of origin/main HEAD `88756c1f8b`).
2. **Inline tests**: `PYTHONPATH=. venv/bin/python -m pytest mvp_site/tests/test_god_mode_narrative_render_swap.py -v` → **12/12 PASS** in 0.28s. The contract test pin covered 4 required cases + legacy `"undefined"` coercion + whitespace narrative + both-empty + single-source-of-truth constant guard + source-load-order guard.
3. **Commit with worker prefix**: `git -c user.name='hermes-claudem' -c user.email='noreply@hermes.local' commit -m 'claudem/minimax-M3: feat(frontend): swap god-mode narrative fallback to generic placeholder'` → commit `66402d8be3`, 5 files / +350/-7. Use the worker's `claudem/minimax-M3:` prefix, NOT the parent session's — the worker started the work.
4. **Push to clean branch**: `git push -u origin HEAD:refs/heads/feat/god-mode-no-narrative-render` → remote HEAD matches local `66402d8be3`.
5. **Open PR via REST draft**: `gh api -X POST repos/jleechanorg/worldarchitect.ai/pulls` with body `{title, body, head:feat/..., base:main, draft:true}` → returns `STATUS:201 NUMBER:9094 STATE:open DRAFT:True`.
6. **Flip to ready via GraphQL** (REST PATCH silent-no-ops on draft flag): REST PATCH `{draft:false}` returned `draft: True` (no-op). Use `gh api graphql --input -` with mutation `markPullRequestReadyForReview(input: {pullRequestId: $prId})`. Verified: `markPullRequestReadyForReview` returned `isDraft=False`; REST re-verify confirmed `draft=False`.

The recipe is identical to PR #828 — only the file types changed (frontend JS + Python test instead of bash script + bash test). Any dispatch that ends at "implementation done, ship phase pending" should use this recipe.

## Pitfall 17 — Repo-local `/green` definition overrides the global 7-condition gate (verified PR #9094)

The global umbrella `~/.claude/skills/pr-green-definition/SKILL.md` defines `/green` as 7 conditions (CI, conflicts, CodeRabbit APPROVED, Bugbot clean, comments resolved, evidence-gate, Skeptic PASS). **Repo-local `.claude/skills/pr-green-definition.md` files override this.** The WA repo (`jleechanorg/worldarchitect.ai`) is the canonical example:

- Redefines `/green` as **2 gates**: CI green + no merge conflicts.
- *"CodeRabbit and Bugbot are optional advisory reviewers, never gates."*
- *"Slow CI never blocks `/green`. If a check has been running >10 minutes past its normal runtime, run the equivalent test locally and post proof labeled 'local run — CI still pending'."*

When driving a WA PR cycle (or any repo with its own `.claude/skills/pr-green-definition.md`):
1. **First** check `cat .claude/skills/pr-green-definition.md` in the target repo. If present, that file is the source of truth — NOT the global 7-condition definition.
2. **Then** check the repo's `AGENTS.md` for project-specific rules. WA explicitly: *"CodeRabbit and Bugbot are optional advisory reviewers, never gates."*
3. **Vendor review capacity limits are NOT gates** when the repo's local definition doesn't require them. PR #9094 simultaneously hit:
   - CodeRabbit "Review limit reached" (36-min wait, 82 reviews in 7 days)
   - Bugbot "couldn't run - usage limit reached"
   - Codex "usage limits for code reviews"
   
   Per WA's local definition, none of these are gates — they are advisory noise. Document the limits in the in-thread reply, do NOT re-trigger blindly, do NOT block.
4. **Slow CI handling**: when a single check has been in_progress >10 min past its normal runtime, run equivalent local verification AND post proof. Sibling check runs (e.g. core-mvp-1/2/3 PASSING when core-tests is still in_progress) are acceptable interim evidence.

Without pitfall #17, the prior pattern would have been: "wait 36 min for CodeRabbit to unblock, then verify CR APPROVED" — a 36-min stall on a vendor-side capacity limit, not a real defect. With pitfall #17, the PR is reported green as soon as `mergeable=true` + CI green + 2 of 2 local-definition gates met.

See `references/pr-9094-2026-08-19-verified-case.md` for full transcript + worker bash session + tee-log buffering proof + the 6-step GraphQL flip.

## Inline takeover checklist

1. Snapshot the ironclad middle layer (`gh pr view <N> --json …`, `git log origin/main..HEAD`).
2. Commit any uncommitted evidence; push to the PR branch.
3. Run missing verification locally (`PYTHONPATH=. venv/bin/python -m pytest testing_ui/realistic/ --ignore=<known-broken>`).
4. Reproduce any failing CI test on origin/main HEAD to prove the same-name rule: `git worktree add /tmp/wa-baseline origin/main` → install deps → run failing test → byte-diff traceback.
5. Post the pre-existing-failures comment to the PR with the same-name rule evidence (4/4 checks).
6. Post /es and /er to the PR via `gh pr comment <N> --body "/es …"` and `/er`. If GitHub returns 403 secondary rate limit, label the criterion as NOT POSTED in the final reply (do NOT retry blindly).
7. Post the consolidated final reply in the originating Slack thread with the ironclad criterion table, PARTIAL labels for rate-limit-blocked criteria, the pre-existing-failures link, and the memory ledger.

## Anti-patterns

- ❌ Dispatching round 4 after three max-turns rounds. Spend the compute on parts that need model judgment, not on CI polls.
- ❌ Pretending /es and /er PASSED when they were not posted. Label them NOT POSTED (with reason) in the ironclad table.
- ❌ Skipping the same-name reproduction step on pre-existing failures. Dismissal is invalid without 4/4 same-name checks.
- ❌ Polling the claudem log file for progress. `tee` swallows TUI output — poll the worktree state (`git log origin/main..HEAD`) instead.

## Companion pitfalls (fold into `claude-code-claudem` + `finish-the-job` once curator-managed)

1. `--workdir` is NOT a claudem flag — `error: unknown option '--workdir'`. Use `cd <path> && bash -lic 'claudem …'`.
2. `tee` swallows claudem's TUI stdout (Ink TUI doesn't flush to non-TTY pipe). Redirect via `exec >/path/to/log 2>&1` BEFORE launching.
3. `process.poll()` against running claudem shows empty log mid-run — poll worktree state instead.
4. Pre-existing test failures need same-name reproduction BEFORE dismissing — fresh `origin/main` worktree, byte-identical traceback, 4/4 checks.
5. GitHub secondary rate limit (HTTP 403 on `POST /repos/.../issues/<N>/comments`) is sticky for ~1 hour. Switch to GraphQL bucket, batch comments, label NOT POSTED criteria in the final reply.

## New pitfalls (verified 2026-08-10, jleechanorg/worldarchitect.ai#8839)

6. **`--max-turns 80` is too tight for any PR-creation dispatch.** Verified at 52 min wall-clock: a worker on the cache-churn fix landed commit + push but stalled before `gh pr create`. The cost was: ~5 extra minutes of inline takeover + a parallel REST call (which `gh-safe-publish` couldn't do because of its own bug). For any dispatch that includes commit + push + PR-creation + initial CI probe, **default to `--max-turns ≥ 100` (preferably 120)**. The compute cost of an unused turn is much smaller than the cost of a stalled worker. Specific budget table (measured 2026-08-10, M3 model):

| Phase | Turns |
|---|---|
| Read SOUL.md / memory / relevant skills | 5-8 |
| Pull live evidence (BQ / gcloud) | 5-10 |
| Phase 1 code investigation (find all busting sources) | 15-25 |
| Phase 2 apply fixes | 10-15 |
| Phase 3 write tests + run them | 8-12 |
| Phase 4 commit + push | 3-5 |
| Phase 4 gh pr create + initial CI probe | 5-10 |
| Phase 5 iterate on CI / CodeRabbit / bugbot | 10-30 |
| **TOTAL** | **61-115** |

   Round to the nearest 20 for safety; default `--max-turns 120`.

7. **`tee` output is fully buffered when claudem is run with `--dangerously-skip-permissions --effort high`.** Verified: a 52-min worker produced only 307 bytes of tee output (the bash startup banner and the `claude.ai connectors disabled` warning) — zero assistant text, zero tool calls. The Ink TUI runs in interactive mode and doesn't flush to a non-TTY pipe. **For live worker observation, do NOT rely on tee/stdout.** Two correct alternatives:

   a. **Poll the worktree state** (`git log origin/main..HEAD`, `git status --short`, `git ls-remote origin <branch>`) — this is the source of truth and gives you phase progression (commits, files modified, branch pushed) without depending on stdout.

   b. **Tail the per-project Claude Code JSONL** at `~/.claude/projects/-Users-jleechan-*/<session>.jsonl` — every assistant message, tool call, and tool result streams here in real time. Find the right file with `find ${HOME}/.claude -path '*projects/-Users-jleechan-projects-<repo>*' -name '*.jsonl' -newer <dispatch-start-time>`.

   The companion skill `babysit-ao-pr-loop` uses approach (a) (worktree-state polling) as its primary monitoring source.

8. **REST fallback for `gh pr create` when worker times out.** The canonical `gh-safe-publish` wrapper at `~/.smartclaw/scripts/gh-safe-publish` has a known `case "$1 $2"` parse bug at line 14 (`gh pr create` is listed but the wrapper's argument-parsing loop emits `error: unsupported publishing command: gh pr create` even when the case matches). When a worker times out after `git push` but before `gh pr create`, take over inline with a direct REST POST:

   ```bash
   GH_TOKEN=$(gh auth token)
   curl -fsS -X POST "https://api.github.com/repos/{owner}/{repo}/pulls" \
     -H "Authorization: Bearer $GH_TOKEN" \
     -H "Accept: application/vnd.github+json" \
     -H "Content-Type: application/json" \
     -d @- <<'EOF'
   {"title": "...", "body": "...", "head": "<branch>", "base": "main", "draft": true}
   EOF
   ```

   Verified on PR #8839 — first call returns 201 with `html_url`, `number`, `state=open`, `draft=true`. Run `gh pr checks <N> --repo {owner}/{repo} --watch=false` to verify CI is queued. Outbound body MUST still pass `~/.smartclaw/scripts/lib/outbound_secret_gate.py` (the `outbound-secret-publication-gate` SOUL.md rule) — wrap the curl with the gate if the body could contain a credential.

## New pitfalls (verified 2026-08-13, REVISIT backlog sweep)

9. **`delegate_task` has a hard 600s timeout that kills full PR cycles mid-push.** Two coding dispatches this session (dice natural-1/natural-20 fix + /web-advice UI redesign batch, both `leaf` model) hit `status=timeout, api_calls=5` and `status=timeout, api_calls=47` at the 600s mark — both mid-PR-cycle, no push, no PR open. **For any coding dispatch that includes commit + push + PR-creation, default to `bash -lic 'claudem --bg "<task>"'`** — background mode has no timeout cap and survives the full PR cycle. Trade-off: `delegate_task` returns a transcript path you can `tail -f`; `claudem --bg` returns a `session_id` you `process(action='poll')` on. Both work; pick by timeout expectation. **Rule of thumb:** ≤5-min lookup → `delegate_task`; ≥5-min OR any work that pushes to a remote → `claudem --bg` or `claudem` in `terminal(background=true, notify_on_complete=true)`.

10. **When a `delegate_task` subagent times out, retry with TIGHTER SCOPE — not the same prompt.** The hanji Stevens research subagent (#114) timed out at 600s with 5 API calls — stuck on a slow firestore WA campaign query. The retry prompt explicitly skipped firestore as last-resort and hit `~/llm_wiki` first (local, fast), then beads (`br search`), then `~/.claude/projects/*/memory/`, then `~/.smartclaw/state.db` via FTS5. The retry came back in **45 seconds** with full triangulation (campaign ID `2G4YpEKFCPAVC7gjS3ET`, source paths, slack thread URL, 24 logged errors flag). Anti-pattern: re-dispatching the same prompt "to give it more time" — it will hit the same 600s wall. Pattern: read the transcript, identify the slow API call, reorder sources by latency, put local cache first.

11. **For background claudem workers, always pass `notify_on_complete=true` or plan to poll.** `terminal(command="...", background=true)` without `notify_on_complete=true` runs SILENTLY — you get a `session_id` but no completion notification. For bounded tasks (test runs, PR cycles, deploys), always set `notify_on_complete=true`. For genuinely long-lived processes (servers, watchers, the new launchd `ai.smartclaw.schedule.dropped-thread-followup`-style crons), the silent default is correct. Bug-ref this session: 5 background claudem workers dispatched for the coding wave all required manual `process(action='poll')` to read state; would have been one-shot with `notify_on_complete=true`.

## New pitfalls (verified 2026-08-13, PR #8863 v3 review-comment iteration)

12. **Review comments are pinned to the PR's base SHA — branching off newer origin/main may invalidate them.** PR review comments are anchored to a commit SHA on the PR's branch (typically the base SHA at review time, not the current head). When iterating on review comments from a fresh worktree off a newer `origin/main`, the referenced functions may have been renamed, refactored, or the edge case may already be covered upstream. **Always pre-verify each comment is still valid on the worktree base BEFORE dispatching a fix worker.** Concrete recipe:

   ```bash
   # 1. List comments with their commit_ids
   gh api "repos/OWNER/REPO/pulls/N/comments" --jq '.[] | {commit: .commit_id[0:7], path, body: .body[0:100]}'
   # 2. For each "fix X in function Y at line Z" comment, verify the function exists and the bug is reproducible
   grep -n "function_name" path/to/file.py
   PYTHONPATH=. python3 -c "from module import function_name; print(function_name('malformed_input'))"
   ```

   Verified on PR #8863 v3: of three review comments, two were on stale parser code (`_is_pure_compound_notation`) that origin/main had already replaced with a stricter `_parse_dice_notation` (lines 37-121 of `mvp_site/action_resolution_utils.py`); the malformed inputs the reviewer worried about (`1d20+1d0`, `1d20+1d6++++`, `1d20+1d6kh`, `1d20+5+1d6+`, `1d20+5_+1d6`) ALL return `(None, None, 0)` on origin/main. This collapsed the work from "fix three bugs" to "fix one routing bug + add tests + leave audit_helpers.py alone for ZFC reasons". Dispatching without this verification would have burned a worker on dead-code fixes.

13. **Worker mid-edit partial states often leave duplicate function definitions.** When a worker hits max-turns mid-edit, it may have started writing a new function but not yet deleted the old one — leaving two `def foo(...)` definitions in the same module. Python parses this without error (the second definition silently shadows the first), but downstream callers get the second definition and the first is dead code. **Recovery recipe when worker exits with no commit:**

   ```bash
   cd <worktree>
   git status --short                    # M = modified, ?? = untracked
   git diff <modified_file>              # inspect the partial edit
   # If the diff shows duplicate functions / half-applied logic:
   git checkout -- <modified_file>       # safe — uncommitted, no commits to undo
   ```

   Verified on PR #8863 v4 dispatch: worker hit max-turns with `scripts/audit_dice_rolls.py` modified, containing two `_is_compound_notation` defs (line 59 and line 625) and two `_group_rolls_by_die_type` defs (line 98 and line 662). `git checkout -- scripts/audit_dice_rolls.py` reverted cleanly; the next worker dispatched against the clean worktree.

14. **Pre-compute exact line numbers, file paths, and "don't read skills" instructions into the dispatch prompt.** A 6.5KB open-scope prompt with "first read AGENTS.md and .claude/skills/root-cause-first/SKILL.md" instructions burned 60 turns on skill-loading rituals without producing a single commit. A 4.5KB prompt with the same info pre-computed (exact file path, exact function names, exact line numbers, explicit "do NOT read AGENTS.md or any skill files unless blocked" rule) completed the same fix scope in a fraction of the budget. **Pre-dispatch prompt recipe:**

   - Run `grep -n "<function_name>" <file>` and paste the line numbers into the prompt.
   - For each review comment, include the full comment text + commit_sha + path + line.
   - Add an explicit "TIME BUDGET: --max-turns N. Should easily fit. If you're at turn 60 and not done with at least fixes + tests + 1 commit, you are wandering." warning.
   - Forbid skill-loading rituals: "Do not read AGENTS.md or any skill files unless you hit a real blocker."
   - Mark which review comments are already-obsolete vs load-bearing (the staleness check from pitfall #12).
   - Default `--max-turns` to 120 for any PR-cycle dispatch (per pitfall #6).

   Concrete prompt size guidance: under 5KB for any dispatch where you know the exact scope; 5-10KB only when discovery IS the work; over 10KB is almost always a sign you're trying to push context into the worker instead of letting it investigate.

## Decision rule (extended: round-1 vs round-N)

A new decision branch applies when round 1 hits max-turns with NO commits:

1. **Was the worktree modified by the worker?** `git status --short` shows `M` or `??` files.
   - YES → run pitfall #13 recovery: inspect the diff, `git checkout -- <file>` if half-edited with dupes, then dispatch round 2 with the tighter-scope prompt (pitfall #14).
   - NO → worker burned its budget on exploration (likely reading skills/AGENTS.md). Re-dispatch with pitfall #14's tighter-scope prompt; do NOT inline-take-over because there is nothing to take over.

2. **Is the worker state clean (no uncommitted edits)?**
   - YES → same as above: dispatch round 2 with tighter scope.
   - NO → FIRST recover the worktree state (pitfall #13), THEN dispatch round 2.

Round 2 itself follows the original decision rule: if PR open + ironclad provable + remaining work mechanical, take over inline.
