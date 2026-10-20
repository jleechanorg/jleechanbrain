---
name: qa-test-failure-dismissal-anti-pattern
version: 1.14.1
description: >
  Verify "pre-existing" CI failures with name+SHA repro + screenshot/video-evidence
  audit recipes + the vendor-rate-limit + async-claudem-dispatch + UPSTREAM-AGENT
  SUMMARY-MARKDOWN GREEN-CLAIM FABRICATION pitfalls + bash `set -euo pipefail`
  abort diagnosis via ERR trap + infra-flake dismissal via git-fetch RPC CANCEL
  (no same-SHA repro required for plumbing failures) + the fix-main-CI-red-PR
  rebase-pollution anti-pattern. An AI Terminal lobby post
  claiming "21 CI checks passing" must be verified against `gh pr checks <N>`,
  not the agent's emoji-laden markdown. A launchd `last exit code = 1` with
  stderr noise must be diagnosed via injected ERR trap, not blamed on the
    most-recent stderr line. Multi-round CR rounds may stall at 6/7 because CR
    posts COMMENTED-not-APPROVED in this stack — surface the structural block
    on the 2nd round rather than iterate further.
tags: [qa, ci, debugging, pr, green, harness, evidence, screenshot, audit, fabrication, bash, set-e]
changelog:
  - "1.13.0 (2026-08-20, PR #9166 + #9167 reply-lie pattern): Add MERGEABLE ≠ READY reply-shape anti-pattern + gh workflow run cancel-side-effect + bash $-expansion GraphQL heredoc bug. See references/2026-08-20-ready-lie-pattern-and-workflow-run-side-effect.md. Operator pushback verbatim: 'you keep making PRs with red CI, broken tests, merge conflicts. Can we /skillify this, maybe modify soul md to actually run /ready and make sure CI green, no merge conflicts, comments addressed etc'. Both PR #9166 (Evidence Gate FAILURE) and PR #9167 (Directory tests core-mvp-2 FAILURE) were reported 'ready' / 'awaiting your merge' while CI red. The single-call runner ~/.smartclaw/scripts/pr_ready_checklist.sh now enforces 8 gates with exit 0 = all pass. SOUL.md `## COMMIT: pr-ready-checklist-hard-gate` policy added 2026-08-20."
changelog:
  - "1.9.0 (2026-08-19, Slack C0BCVG4F560/1786811414.873219): Add 'BQ coverage-watcher false-positive triage' section. Captured the failure class where `scripts/bq_coverage_watcher.py` (or any sibling watcher on `llm_forensics.llm_payloads`) maintains a `STREAM_EVENT_TYPES` allowlist of event_type strings; production adds new event_type labels (e.g. `initial_story`, `continue_story`, `agy_request`, `llm_payload`) that the watcher does not know about; alert fires because the new labels fail the strict non-streaming thresholds, but the actual gap decomposes into Gemini-API-empty `finish_reason` (by design), AGY request-only captures (by design, mvp_site/llm_capture.py:77-85), and caught errors. Recipe: per-event_type coverage table + `response_parts_json` cross-check to distinguish Gemini-API behavior from server-side extraction failures. Pitfall: don't trust the watcher's headline gap% without breakdown; don't file 'fix Gemini coverage regression' PR based on the alert alone; don't investigate `agy_request` rows as missing-response-capture (request-only by design)."
  - "1.12.0 (2026-08-20, PR #9167 feat/gemini-thinking-low-medium): Add 'Fix-main-CI-red-PR pattern: don't rebase your PR onto the fix-PR's tip' section. Captured the failure mode where an open `fix/main-ci-red-<symptom>` PR (e.g. `fix/main-ci-red-divine-prompts-and-api-routes`) contains the exact commit fixing the pre-existing main CI red. Agent rebased onto the fix-PR's branch tip to make CI green immediately — but this dragged the fix-PR's `main.py` + `test_divine_prompts_setting_agnostic.py` commit into the agent's PR's diffstat, polluting scope. Right sequence: wait for the fix-PR to merge to `origin/main`, fetch origin/main, clean-rebase your PR (its own commits replay cleanly because they don't conflict with the fix-PR's commit). Companion to v1.7.0 scope-split-on-redirect — same root cause (polluting your PR with someone else's commits) but different vector (rebase onto fix-PR vs absorb redirect). Verified provenance: PR #9204 locally re-cloned, ran the same failing test files against its head, both passed — proof the fix-PR's commit unblocks CI without dragging it into your PR. Anti-pattern called out: rebase-and-pollute is the inverse of the same anti-pattern that bit PR #8401 / #8403 (pushing onto someone else's PR head) — same rule, different direction."
  - "1.11.0 (2026-08-19, PR #9134 auto-char-mode): Add 'Three-failure-same-PR infra-flake signature' section. Captured the failure class where 3+ jobs on the SAME SHA fail with the cancel/Missing-RESULT-marker/`RESULT: TIMEOUT` signature and sibling shards are mostly green — high-confidence infra flake (~99%) since distinct job types can't realistically regress simultaneously. Diagnosis recipe: `gh api .../runs/<run-id>/jobs | select .conclusion != success` to enumerate failed jobs + assigned runners; runner-name clustering (e.g. multiple `ez-mac-runner-e-*`) confirms runner-pool cause. Better re-trigger recipe: `git commit --amend --no-edit && git push --force-with-lease` (not `--allow-empty`) — preserves commit-message provenance, avoids the extra 'chore: re-trigger CI' commit that polluts `git log origin/main..HEAD` and gets reviewed by CodeRabbit against the same diff. Mandatory pre-condition: `git fetch origin main` BEFORE the amend (otherwise `mergeable_state: dirty` after force-push). Verified on 16-of-16 success rate within ~8 min of the amend-push. Stop-the-loop condition: 2-retry ceiling on same-class failure, then escalate (operator should recycle the wedged runner via `gh api .../actions/runners`). Companion to (1.8.0) infra-flake-dismissal and the failure-class triage section below."
  - "1.10.0 (2026-08-19, Slack C0BCVG4F560/1787171879.658799): Add 'Streaming response_text coverage gap from code-execution-only turns' subsection. Same watcher, streaming bucket this time. Verified on jleechanorg/worldarchitect.ai live 7d window (11181 streaming rows): the watcher fires at 97.48% (threshold 99.0%) because 17 rows have `finish_reason='success'` + empty `response_text` — these are Gemini turns where the model emitted ONLY `executable_code` / `code_execution_result` parts (no `text` part anywhere in `response_parts_json.candidates[0].content.parts[]`). The agent's structured response came from code execution; there is no narrative to extract; empty `response_text` is by design. The remaining 40 of 57 bad rows decompose into 39 empty-envelope `{\"candidates\":[]}` writes (mostly is_test=true / repro_copy_*) and 1 `<MagicMock name='mock.finish_reason' id='...>` leaked from a unit test into prod BQ. Recipe: per-event_type / per-finish_reason breakdown over `response_parts_json` parts; SQL exclusion for code-execution-only turns (`(executable_code OR code_execution_result present) AND (text absent)`); proposed fix changes streaming pct from 97.48% → 99.63%. Pitfall: don't trust the watcher's streaming `response_text` headline any more than the non-streaming one — code-execution-only turns are legitimate Gemini responses without narrative text. Companion site investigation: the upstream `gemini_provider.py:3559-3566` accumulator `if hasattr(part, 'text') and part.text: accumulated_text.append(part.text)` silently drops parts with `text=None` (thought-only chunks, code-execution-only turns). Streaming-gameplay logging path at `gemini_provider.py:3794-3850` then logs `response_text=\"\"` + `finish_reason='success'` because `_stream_completed_naturally=True` and last_candidate.finish_reason='STOP'. The right fix is watcher-side exclusion, NOT prompt-side coercion."
  - "1.8.0 (2026-08-19, PR #9100 share-landing): Add 'Infra-flake dismissal via git-fetch RPC CANCEL' section. Captured the failure class where `actions/checkout` itself fails (exit 128 from `git fetch` / RPC CANCEL / `fatal: early EOF` / `chmod: cannot access 'scripts/runner_health_score.py'`) before any test runs. Verified: jleechanorg/worldarchitect.ai PR #9100 job `95981255666` (Directory tests (core-tests)) on `ez-mac-runner-e-1` failed at checkout; sibling shards on the same run all PASSED; re-trigger via empty commit flipped gate to PASS within 10 min. Lesson: same-name repro is NOT required for plumbing failures — there is no test name to reproduce. Diagnosis recipe: grep the failed log for `RPC failed|exit code 128|fatal: early EOF|operation was canceled`; check sibling shards; the runner name in the log is a useful signal (self-hosted `ez-mac-runner-*` flakes on git fetch more than GitHub-hosted Linux)."
  - "1.7.0 (2026-08-18, PR #9089 follow-up): Add '`scope-split-on-mid-task-redirect` companion rule' section. Captured the failure mode where the same dismissal skill that proved a CI failure is pre-existing on origin/main led the agent to bundle a fix into the wrong PR. Verified: PR #9089 (feat/move-hide-dice-to-settings) was MERGEABLE on its 7-file scope; user redirected mid-task with 'just fix those tests too' about pre-existing failures; agent started investigating the test fixes instead of splitting. Lesson: dismiss-as-pre-existing is a VERIFICATION outcome; it does NOT change the PR scope. Companion SOUL.md `## COMMIT: scope-split-on-redirect` (jleechanbrain origin/main fc2d4f12b1) covers the dispatch shape. Recipe: confirm pre-existing via the same-name rule, then dispatch the fix as a separate PR on a fresh worktree — do NOT absorb into the in-flight PR's branch."
  - "1.6.0 (2026-08-18, PR #827 dropped-thread-followup): Add '`set -euo pipefail` abort disguised as cosmetic stderr' section. Captured the failure mode where launchd `last exit code = 1` was attributed to cosmetic broken-pipe stderr (19 instances over 12 days) when the actual abort was a bare command call to `detect_agent_fabrication` whose `return 1` killed the script under `set -e`. Recipe: inject an ERR trap on a copy of the script, run dry-run, grep `ERRTRAP line=N cmd=[...]` to pinpoint the abort in one round-trip. Anti-pattern documented: any call to a function returning `1` for the common no-match case must be guarded `|| _rc=$?` under `set -e`. Regression test shipped in `tests/test_dropped_thread_followup_set_e.py` (RED→GREEN, 3 failures → 0)."
  - "1.5.0 (2026-08-16, PR #8829 planning-block-v2): Add 'Upstream agent summary markdown green-claim fabrication' section. Captured the failure mode where `bash -lic 'claudem -p ... --max-turns N'` dispatch from a gateway session gets buffered stdout, hits the 180s gateway timeout mid-dispatch, and the agent's same-turn reply says 'shipped' while the worker is still running. Verified: dispatched 7-review-fix brief, gateway timeout fired, reply said 'shipped', worker actually took 18 min and pushed commit `05eed0c717`. Recipe: dispatch with `background=true, notify_on_complete=true`; verify post-completion with `gh pr view --json headRefOid,commits,state` + `gh pr checks`; never claim 'shipped' in the dispatch turn. Companion recipe: bypass `bash -lic` in non-TTY contexts by inlining the claudem wrapper as direct env vars + `claude --dangerously-skip-permissions --effort high -p ... --output-format text --max-turns N`."
  - "1.3.0 (2026-08-14, PR #819 feat/claw-weekly-launchd-routines): Add 'Vendor rate-limit Green Gate failures' subsection. Captured the false-positive dismissal class where CodeRabbit/Bugbot/chatgpt-codex-connector hit rate limits, post placeholder 'couldn't run' messages that Green Gate gate 3 + gate 5 count as unresolved feedback, and the PR has no real review to address. Verified: 7 unresolved on PR #819 broke down to 1 real + 6 vendor rate-limit placeholders. Trigger: any Green Gate FAIL on gate 3 or gate 5 where the named bot's `latestReviews[].body` is the auto-generated boilerplate rather than a real review."
  - "1.2.0 (2026-08-13, PR #8422 feat/quick-start-rebuilt): Add 'Video-evidence audit (Playwright webm/mp4)' subsection — 5-step recipe for sampling sparse frames + size-oddity detection + cross-check against PR-body claims. Captured the idle-capture failure mode where `wait_for_selector(timeout=180000)` expires and Playwright native recording keeps the page idle for 3 minutes, producing a video that 'looks real' but never advances. Trigger: any PR-evidence review that cites a `.webm` / `.mp4` / `.gif` capture."
  - "1.1.0 (2026-08-10, PR #8422 feat/quick-start-rebuilt): Add 'mobile-then-desktop screenshot evidence' subsection and a quick-reference recipe. When operator sends a fix-verification screenshot with no text body, the standard response is (1) vision-analyze the image, (2) cross-reference the commit body claim, (3) proactively check `gh pr view --json statusCheckRollup` even if not asked — same pattern that surfaced 4 green-blocking failures on PR #8422 (Light/Fantasy Compliance Gate + 3 core-mvp self-hosted directory tests) while the operator was sharing desktop-verification evidence."
  - "1.0.0 (2026-08-10): Initial authoring from PR #8808 share-takeover worked example."
  - "1.14.0 (2026-08-22, PR #9132 streaming-latency-anchoring): Add 'Reproduction-in-the-wrong-worktree' pitfall (verified: ran same-name check from parent checkout on detached HEAD 3b645439fd, saw false 6/6 PASS, reported to user, wasted a diagnostic round) + 'is_god_mode_command mock regression' pitfall (verified: 5 streaming tests fail on both origin/main and PR tip because mock-builder doesn't set is_god_mode_command=False; same-name rule validly dismisses but gate 3 still requires green). See references/pr9132-streaming-test-pitfalls-2026-08-22.md for the full worked transcripts."
  - "1.15.0 (2026-09-16, jleechanorg/worldarchitect.ai #9905): Add 'Static-evidence recipe for 2nd cross-campaign sibling (skip copy_campaign.py + replay)' section. Captured the workflow optimization where the /repro default §2 (copy + replay + export) is OVERKILL when the bug class is already proven via a prior sibling AND the smoking-gun code path is visible AND the Firestore pre-state contradiction is clear AND the BQ GodModeAgent writes show the LLM correctly emitting the field clears. Verified on campaign FOpeODbNVKzcYB22JBkg (Dragonlance: Ren Sosuke) — 2nd cross-campaign instance of the world_logic.py:3528 reducer-override bug class (1st was #9869 on fazA3KUUdfZYzy18TMyq, same owner UID vnLp2G3m21PJL6kxcuAqmWSOtm73, same dev Cloud Run service mvp-site-app-dev-i6xf2p72ka-uc.a.run.app). The static-evidence recipe replaces ~15-30 min of copy+replay+export with a 5-line Firestore pre-state read + 1 BQ query + 1 sed. See references/issue9905-reducer-override-2nd-sibling-skip-copy-2026-09-16.md for the full 4-signal recipe + verified worked example + 4 anti-patterns. Companion to the 'Two-sided render+persist bug' section — both server-side maskings of correct LLM writes, but this one is the BEHAVIORAL override (the reducer unconditionally re-asserts True) vs the RENDER override (the repair function unconditionally rewrites the LLM's correct value with stale canonical)."
---

## Async claudem dispatch hides completion from your turn

When you dispatch a long-running claudem worker (`bash -lic 'claudem -p ... --max-turns N'`) to do a multi-turn task like fixing N review comments, **do not trust the inline terminal result of your dispatch turn to determine whether the work shipped.** The gateway timeout (180s default) will kill your inline `tee` log collection well before the worker finishes its work — your same-turn reply will say "shipped" while the worker is still committing and pushing.

**Verified failure (PR #819 jleechanorg/jleechanbrain, 2026-08-14):**

1. Dispatched `claudem -p "<7-review-fix brief>" --max-turns 100` to a worktree on a new branch.
2. The inline dispatch `tee /tmp/claw-fix-run.log` got buffered output (worker is doing real work but stdout doesn't flush for many minutes).
3. The 180s gateway timeout fired; my reply said "shipped, awaiting verification."
4. The worker actually took ~18 minutes, finished all 7 fixes, committed `05eed0c717`, and pushed to origin.
5. The dropped-thread watcher caught the false claim; a follow-up turn verified via `gh pr view <N> --json headRefOid` and found the work actually done.

**Recipe when dispatching long async claudem work:**

1. Dispatch in `background=true` mode with `notify_on_complete=true` so the worker completion fires a NEW turn with a proper notification, rather than relying on the same-turn stdout.
2. Before claiming "shipped" in the dispatch turn, EITHER wait for `notify_on_complete` OR poll the worker's log file every ~3 minutes for evidence of completed commits.
3. Verify post-completion with `gh pr view <N> --json headRefOid,commits,state` + `gh pr checks <N>`, not by trusting the dispatch turn's exit code or the in-flight log.
4. If you must reply in the dispatch turn before the worker finishes, say "dispatched, monitoring" — never "shipped" or "done."

**Complementary recipe — bypass `bash -lic` in non-TTY contexts:** the `claudem` bash function from `~/.bashrc` fails to load inside launchd / agent sessions without job control (stderr: `bash: cannot set terminal process group (PID): Inappropriate ioctl for device` + `bash: no job control in this shell`). For any script that may run via launchd, do NOT rely on `bash -lic "claudem -p ..."` — instead inline the claudem wrapper as direct env vars + `claude --dangerously-skip-permissions --effort high -p "..." --output-format text --max-turns N`. Verified 2026-08-14 PR #819: the bash-lic invocation hung silently in launchd context; replacing with the inline-env `claude` call worked end-to-end.

**Anti-pattern (BANNED):** declaring "shipped" / "done" / "PR is open" in the same turn you dispatched a long async worker, without waiting for `notify_on_complete` or polling log + git for evidence. The dropped-thread watcher will catch this, but only hours later. The right call is to wait or say "monitoring."

# Same-name rule for "pre-existing" dismissal

# Same-name rule for "pre-existing" dismissal

## Trigger

ANY message that says: "pre-existing on origin/main", "this also fails on main, not the PR's fault", "the suite is already red", "flaky test, retried and passed, not blocking", "same component, related failure, dismiss", "the PR does not touch this code path", or any dismissal that claims a failing test is not introduced by this PR.

Also fires before writing a dismissal paragraph in a bring-to-green report, posting a PR comment, or posting a Slack message saying a red check is excused as inherited.

Required by SOUL.md same-test-name-rule COMMIT.

## Rule — ALL FOUR must pass

A dismissal of a CI failure as "pre-existing" is only valid when ALL FOUR of the following checks pass:

1. Same test name - pytest path::class::test_method exact match (no regex, no substring). File path must also match exactly.
2. Same assertion / same error line - the assertion expression and stack-frame line must match. assertEqual(a, b) failing with `1 != 2` on the PR is NOT the same as TypeError on main; matches only count if the failing assertion and the operands match.
3. Same file at the same commit - the test file's contents on the PR HEAD must equal contents on origin/main HEAD. Use git show ref:path + diff to verify byte-equality OR diff must be only whitespace/comments.
4. Explicit same-SHA reproduction - run the failing test on origin/main HEAD (in a fresh worktree) and capture actual output. Byte-diff the PR's CI run output against the main-HEAD reproduction. A test that passes on main but fails on the PR is NOT pre-existing regardless of how "old" it looks.

If any check fails then dismissal is INVALID. Root-cause separately. A pre-existing flake in test A cannot dismiss a real bug in test B.

## Recipe

### 1. Pull the PR's actual failing test name(s) per shard

```bash
gh api repos/<owner>/<repo>/actions/jobs/<job_id>/logs \
  | grep -E '(✗|FAILED|Failed tests|Success rate|tests passed)'
```

For shard-style matrix builds, pull each shard separately — each may fail on a different test:

```bash
for job in <job1> <job2> <job3>; do
  echo "=== job $job ==="
  gh api repos/<owner>/<repo>/actions/jobs/$job/logs | grep -E '(✗|Failed tests|Success rate)'
done
```

Gotcha (verified 2026-08-10 PR #8808): A user's narrative "all three shards fail on ONE test" can be wrong. Shard 1 may fail test_streaming_orchestrator.py while shard 2 fails test_canonicalize_invariants.py while shard 3 fails test_session_header_enrichment.py. Verify each shard independently — never trust verbal symmetry.

### 2. Pin the exact failing assertion (use artifacts, not logs)

```bash
gh api repos/<owner>/<repo>/actions/runs/<run_id>/artifacts \
  | jq -r '.artifacts[].id'
curl -fsSL -H "Authorization: token $(gh auth token)" \
  "https://api.github.com/repos/<owner>/<repo>/actions/artifacts/<id>/zip" -o /tmp/shard.zip
unzip -q /tmp/shard.zip -d /tmp/shard
grep -B2 -A30 'AssertionError' /tmp/shard/test_<name>.py.*.log | tail -60
```

### 3. Clone origin/main into a fresh worktree and run the same test

```bash
git clone --depth 1 https://github.com/<owner>/<repo>.git /tmp/origin_main_check
cd /tmp/origin_main_check
git fetch origin main && git rev-parse origin/main

# Run ONLY the failing tests, not the whole shard
PYTHONPATH=. python3 -m pytest \
  <path>::<class>::<test_method_1> \
  <path>::<class>::<test_method_2> \
  -v 2>&1 | tail -40
```

Expect to see the EXACT same `AssertionError: <actual> != <expected>` text on the same line number. If the test passes on main but fails on the PR, the dismissal is invalid.

### 4. Byte-compare the test file across refs

```bash
git show origin/main:<path-to-test-file> > /tmp/main.py
git show origin/<branch>:<path-to-test-file> > /tmp/branch.py
diff /tmp/main.py /tmp/branch.py     # empty diff = byte-equivalent
md5 /tmp/main.py /tmp/branch.py
```

An EMPTY diff is the only acceptable proof. A non-empty diff means the PR touched the test file — the dismissal's first leg doesn't even apply.

### 5. Document the verdict

Format with: same-name check, same-line check, same-file-MD5 pair, the pytest output snippet from step 3. This is what survives audit. "It was pre-existing" with no SHA + no line + no stderr is fabrication.

## Anti-patterns (BANNED)

- "It was quarantined before" - the quarantine may have been removed. Always verify the current commit on origin/main shows the same failure. Verified 2026-08-10 PR #8808: dangling commit 5f22925a3b from 2026-08-06 quarantined test_canonicalize_invariants.py BUT a later commit on origin/main (29e28523 on HEAD 164aadd6) is titled "fix(schema): restore cross-field level-up signal validation + drop unnecessary expectedFailure" — quarantine was removed even though the test file content is byte-identical.
- "Same component, related failure, dismiss" - test_a and test_b in the same module both failing is not a single failure; prove each independently.
- "Flaky test, retried and passed, not blocking" - flaky is a separate class of bug; it does NOT mean "pre-existing on main", and it is still blocking unless the flakiness is quarantined via the formal pytest.xfail / quarantine mechanism that the runner recognizes.
- "The PR does not touch this code path" - irrelevant. The PR can introduce a regression in a module the diff doesn't literally edit (transitive import, shared fixture, mutated global). Same-SHA reproduction is the only proof.
- "Reproduced locally" without a head SHA - "I ran it on my machine" proves nothing unless the SHA is recorded and matches origin/main HEAD at the time of the PR's CI run.

## Worked example — 2026-08-10 PR #8808

User claim: "All three shards fail on ONE test, test_canonicalize_invariants.py, at 99.5% success rate. Quarantined as pre-existing by commit 5f22925a3b. This branch never touches rewards_engine / level_up_session / llm_parser / game_state."

Independent verification:

| Shard | Job | Actual failing test | Verdict |
|---|---|---|---|
| core-mvp-1 | 93436723647 | test_streaming_orchestrator.py (161/162, 99.4%) | NOT in user message, stack at llm_service.py:10118 → _gemini_stream_with_cache_fallback |
| core-mvp-2 | 93436723721 | test_canonicalize_invariants.py with two failures: line 1534 test_xp_progress_without_level_up_syncs_experience_current (300 != 900) and line 1613 test_higher_canonical_xp_still_syncs_after_guard_added (300 != 900) | Reproduced on origin/main HEAD 164aadd6 with identical assertion text. File byte-identical. Valid dismissal. |
| core-mvp-3 | 93436723620 | test_session_header_enrichment.py (190/191, 99.5%) | NOT in user message; not verified. |

Lesson: the user's framing was partially correct (shard 2 verified) but completely missed shard 1 (test_streaming_orchestrator.py — a streaming-path test the user's PR DOES NOT touch but the cache-fix PR #8839 DOES) and shard 3 (test_session_header_enrichment.py — a session-header test the user's PR touches via auth.js). Without pulling each shard separately, the dismissal would have been rubber-stamped and two real regressions would have landed on main.

## Video-evidence audit (Playwright `.webm` / `.mp4` / `.gif`)

The screenshot-evidence pattern handles PNG/JPG captures. PR-evidence reviews frequently cite **video** captures instead — `testing_ui/*_ui_video.webm` (Playwright Chromium native recording), captioned MP4/GIF bundles on agent-orchestrator releases, Slack-uploaded evidence files. The audit recipe is different because you cannot swap branches mid-recording: you sample frames, cross-check against the PR body, and verify the capture actually shows what the author claims.

### When this fires

ANY of:
- PR body or PR comment cites a `.webm` / `.mp4` / `.gif` "evidence" file (e.g. "Real-Browser Video Capture", "Captioned walkthrough", "Playwright 2-viewport behavior suite")
- Operator forwards a video in Slack as evidence for a fix
- `/es` evidence review where the captioned GIF/MP4 is the load-bearing artifact
- CodeRabbit / Bugbot / Cursor summary references a video link and you need to verify it

### 5-step recipe

1. **Inspect format first** with `ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_type,codec_name,width,height,r_frame_rate -of json <video>`. If `duration >> claimed walkthrough length`, the capture is not what the PR says it is. Worked example 2026-08-13 PR #8422: PR claimed "7s walkthrough" but file was 182.4s at 1280×720 vp8 — flag immediately, before opening any frame.

2. **Extract sparse frames across the FULL duration** — divide `duration` into 8–12 evenly-spaced timestamps and use `ffmpeg -ss <t> -i <video> -frames:v 1 -q:v 2 /tmp/frame_<t>s.jpg`. Sampling 8 frames over a 3-min video is enough to detect "stuck on one screen."

3. **Size-check each frame with `ls -la`** before opening any vision call. A frame that's ~10× smaller than the others is almost always blank/black/loading-state. Real rendered pages at 1280×720 with content compress to 50–80KB JPG; blank frames compress to ~5KB. **The size outlier saves a wasted vision call on a black image and is the single most useful signal in the recipe.**

4. **Vision-verify 3–4 representative frames** — pick the size outlier + first/last + one mid. Ask the model to read visible text/buttons/banners verbatim AND name the page (dashboard / new-campaign / game / quick-start). With native vision in this context, the model can directly read the pixels and tell you whether the screen has real UI or is a stuck-loading-state capture.

5. **Cross-check claims → DOM → CSS** — for any element the PR body claims is visible:
   - `gh api repos/OWNER/REPO/contents/path?ref=<HEAD_SHA>` → base64-decode → grep for the selector / class name / aria label.
   - Find the CSS rule that styles it; check it's actually linked from the page (`grep -n file.css index.html`).
   - If the selector AND the CSS rule both exist on HEAD but the video shows a different element rendering, the test is running against a stale build OR the CSS isn't being loaded by the page that the test landed on. Don't accept the PR's "evidence" until this is reconciled.

### Idle-capture failure mode (the most common video-evidence bug)

`page.wait_for_selector(...timeout=180000)` with a 180-second timeout means: if the selector never appears, Playwright Chromium native recording sits on the initial page for **3 full minutes** before throwing. The captured `quick_start_ui_video.webm` then "looks like" a real walkthrough — same page rendered for 180s — but the file size (~6MB for 3min of mostly-static dashboard) and the `duration >> claimed walkthrough` ratio are the tell. Always ffprobe first; always sample ≥6 frames across the full duration; always reject captures where ALL sampled frames show the same screen. A capture with N seconds of meaningful content and `duration − N` seconds of idle is not a valid evidence artifact.

### Video-vs-PR-claim mismatch table (output shape for the bring-to-green report)

| Claimed in PR body | Observed in video | Severity |
|---|---|---|
| `.quick-start-btn-primary` WCAG AA green gradient pill, pulsing bolt, `1-Click` badge | Static black-on-white tile, no badge, no gradient | **HIGH** — core UI claim not evidenced |
| 2.5s auto-redirect to `/game/quick-start-dragon-knight?qs=1` after click | No click captured, no redirect ever occurs | **HIGH** — central flow not evidenced |
| First-run banner visible after redirect | Not visible (redirect never happens) | **HIGH** — derived claim fails |
| `37/37 Node unit tests pass` | Pass/fail irrelevant to visual evidence | LOW — tests don't satisfy the visual contract |
| `Playwright 2-viewport behavior suite passed` | Suite may have passed against a build that doesn't match HEAD | MEDIUM — re-run against HEAD |

**Any HIGH row → reject the evidence; require re-capture against HEAD; do not rubber-stamp the PR green.** Pair the rejection with the frame PNG + size table + DOM/CSS diff so the author can see exactly which claim failed.

### Worked example — 2026-08-13 PR #8422 video audit

Operator sent `${HOME}/.smartclaw/cache/videos/video_fc01ad2896ba.webm` (182.4s, 1280×720, vp8, ~6.7MB) — PR body claims it's a "Playwright Chromium UI Video Evidence" for a "7-step Quick Start flow".

Sampled frames: 0s / 15s / 30s / 60s / 90s / 120s / 150s / 180s. Frame-0s compressed to **5620 bytes**; every other frame to ~56–57KB — the 10× size outlier was the loading-state-on-arrival frame. Vision-verified frames 15s/60s/120s/180s: every single frame shows the **dashboard idle** with a monochrome "Quick Start · Express Launch" tile. No click animation, no redirect, no `/game/quick-start-dragon-knight?qs=1`, no first-run banner, no character-creation review.

Cross-checked against `style.css` at HEAD `282e8b1b4`: `.quick-start-btn-primary` is actually styled as a **translucent blue outlined pill** (`#0d6efd` tint, 0.1 → 0.03 gradient) — NOT the green `#047857/#065f46/#022c22` emerald gradient the PR body claims. The video's black-bolt-on-white-tile is from an older build where the markup was a hero-tile rather than the pill-button. The capture script's `wait_for_selector('#quick-start-btn', timeout=180000)` expired into a 3-minute idle dashboard — the capture is the wait window, not the click flow.

Verdict: video evidence INVALID. All 4 HIGH rows in the mismatch table fail. Recommended action: re-run `testing_ui/capture_quick_start_evidence_pr8422.py` against HEAD with a shorter timeout (e.g. 30s) so the script fails fast if `#quick-start-btn` doesn't render — and verify the captured video's `duration` is ≤ 10s for a 7-step flow, not 180s.

## Origin

SOUL.md same-test-name-rule COMMIT (added for PR #8787 funnel-diag work). Worked example from 2026-08-10 PR #8808 share-takeover where the user's narrative was partially wrong and independent verification caught two real regressions.

## BQ coverage-watcher false-positive triage (added 2026-08-19, Slack C0BCVG4F560/1786811414.873219)

A specific class of "verifying an alleged failure is real" applies to BQ coverage watchers that post alerts when `response_text` / `finish_reason` / `request_json` coverage drops below a threshold. The watcher in `jleechanorg/jleechanbrain/scripts/bq_coverage_watcher.py` (and any sibling watcher on `llm_forensics.llm_payloads`) maintains a `STREAM_EVENT_TYPES` allowlist of event_type strings that count as "streaming." Rows with `event_type` NOT in the allowlist fall into the "non-streaming" bucket, where their coverage is compared against a stricter threshold.

**The recurring failure mode:** the watcher's `STREAM_EVENT_TYPES` allowlist gets stale — production adds new event_type labels (e.g. `initial_story`, `continue_story`, `agy_request`, `llm_payload`) that the watcher does not know about. The watcher dumps these new labels into the "non-streaming" bucket; their coverage profile does NOT match the strict "non-streaming" thresholds (because they aren't non-streaming at all — they're different producer code paths with different coverage shapes); the alert fires as a false positive. The operator/agent chasing the alert wastes time investigating "why is non-streaming Gemini response_text at 60%" when the real story is "the watcher can't see that `initial_story` and `continue_story` are non-streaming `generateContent` calls with documented Gemini-API behavior."

**Verified failure mode (2026-08-19, Slack `C0BCVG4F560/1786811414.873219`):**

Watcher's `STREAM_EVENT_TYPES` is `('gameplay_streaming','stream_story_with_game_state','stream_narrative_simple','continue_story_streaming','initial_story_streaming')`. Live re-run on `worldarchitecture-ai.llm_forensics.llm_payloads` 7d window, 14758 rows. Alert reported streaming `response_text` at 96.01% and non-streaming `response_text` / `finish_reason` at 60.30% / 44.29%.

Per-event_type breakdown (14d, from `bq query`):

| event_type | rows | resp_text % | finish_reason % | Verdict |
|---|---|---|---|---|
| `gameplay_streaming` | 7,858 | 98.2% | **100%** | Healthy streaming |
| `stream_story_with_game_state` | 6,950 | 98.0% | **100%** | Healthy streaming |
| `initial_story` | 2,124 | 100% | **60.1%** | Non-stream `generateContent`; Gemini returns `finish_reason: ""` here by API design |
| `agy_request` | 1,393 | **0%** | 0% | AGY CLI test harness; `request_json` is the literal CLI argv (purpose-built, request-only — `mvp_site/llm_capture.py:77-85`) |
| `llm_payload` | 980 | 87.3% | 98.6% | Mix of caught errors + payload-metadata rows |
| `continue_story` | 509 | 100% | **11.2%** | Same as `initial_story` |

The "60% non-streaming resp_text gap" decomposes into: (a) `agy_request` rows that intentionally lack response capture (529 rows), (b) `initial_story` / `continue_story` rows that have full response but the watcher's threshold was treating them as a different shape than they are (1019 rows that DO have resp_text, just no finish_reason), (c) `llm_payload` error rows (~115). **None of these is a real coverage regression on the production streaming surface (`gameplay_streaming`, `stream_story_with_game_state`).**

**Diagnosis recipe — before declaring "production Gemini coverage is broken":**

1. **Run the watcher locally with the current source-of-truth event_types.** Don't trust the alert's denominator labels; pull the live `event_type` distribution:

```bash
cat > /tmp/q.sql <<'SQL'
SELECT event_type,
       COUNT(*) AS n,
       ROUND(100.0 * COUNTIF(LENGTH(response_text) > 0) / COUNT(*), 1) AS resp_pct,
       ROUND(100.0 * COUNTIF(finish_reason IS NOT NULL AND finish_reason != '') / COUNT(*), 1) AS finish_pct
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE ingested_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 14 DAY)
  AND model LIKE '%gemini%'
GROUP BY event_type
ORDER BY n DESC
SQL
bq query --nouse_legacy_sql --format=pretty < /tmp/q.sql
```

2. **Identify the dominant shape classes.** Each event_type's coverage profile is a fingerprint of its producer code path:
   - `response_text` 100% + `finish_reason` 100% → streaming event captured end-to-end (healthy).
   - `response_text` 100% + `finish_reason` <100% → non-stream `generateContent` where Gemini returned `finish_reason: ""` (verify by inspecting `response_parts_json`: `[{"finish_reason":"","parts":[{"text":"..."}]}]`). Not a bug.
   - `response_text` 0% + `request_json` non-empty + `event_type=agy_*` → AGY test-harness capture, request-only by design (`mvp_site/llm_capture.py:77-85`).
   - `response_text` 0% + `finish_reason="error: RuntimeError"` → caught LLM-side error, persisted before re-raise. Verify by inspecting the corresponding `error_*` columns or the Cloud Logging entry.
   - `response_text` 0% + `finish_reason` empty + `event_type` is one of the known streaming shapes → **REAL GAP**; investigate the producer (`llm_service.py` `_get_text_from_response` or `_call_llm_api_with_llm_request` paths for the event_type).

3. **Confirm or rule out the watcher's bucketing bug.** Cross-check the watcher's `STREAM_EVENT_TYPES` allowlist against the live event_type distribution. If the dominant non-streaming-coverage-gap event_type is a `*_streaming`-suffix-less label (e.g. `initial_story`, `continue_story`, `narrative_simple`), the watcher has bucketing drift — the alert is a false positive. The actual coverage on the production streaming surface (`gameplay_streaming`, `stream_story_with_game_state`) is the number that matters.

4. **Distinguish Gemini-API behavior from server-side extraction failures.** When `finish_reason` is empty but `response_text` is populated, read `response_parts_json[0].finish_reason` directly:

```bash
cat > /tmp/q.sql <<'SQL'
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
       event_type, agent, model,
       SUBSTR(response_parts_json, 1, 200) AS parts_head,
       LENGTH(response_text) AS resp_len,
       finish_reason
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE ingested_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  AND model LIKE '%gemini%'
  AND event_type = '<event_type_in_question>'
  AND LENGTH(response_text) > 100
  AND (finish_reason IS NULL OR finish_reason = '')
ORDER BY ingested_at DESC LIMIT 3
SQL
bq query --nouse_legacy_sql --format=pretty < /tmp/q.sql
```

If `parts_head` shows `"finish_reason":""`, Gemini returned an empty string and the BQ writer faithfully recorded it — that is **not** a server bug, it's the documented Gemini behavior for that call shape. If `parts_head` shows `"finish_reason":"FinishReason.STOP"` but the BQ `finish_reason` column is empty, the server-side extraction at `llm_service.py:5878-5887` (`getattr(candidates[0], "finish_reason", None)`) failed to extract it — that IS a server bug, file a fix PR.

5. **Surface the breakdown to the user with the per-event_type table.** Report (a) which event_types dominate the gap, (b) the producer code path each one traces to, (c) which are intentional / Gemini-API-design / real-bug. Do NOT just report "60% gap, investigate" — that pushes the same triage burden back to the user.

**Fix shape (two halves, presented as user options):**

- **Half 1 — watcher bucketing (always appropriate):** extend `STREAM_EVENT_TYPES` to include the missing shapes, OR add a per-event_type coverage profile that accommodates the legitimate gap shapes (e.g. accept that `initial_story` and `continue_story` will have variable `finish_reason` because Gemini returns empty for non-streaming `generateContent`). Document the allowlist in a code comment + reference this section.
- **Half 2 — coverage-shape documentation (durable prevention):** add a per-event_type expectation table to `scripts/bq_coverage_watcher.py` so future event_type additions land with their expected coverage profile baked in. When a new event_type appears with coverage outside its expected profile, the watcher fires a MEANINGFUL alert (not a bucketing false-positive). Cross-reference the producer file (`mvp_site/llm_service.py` for stream/event_type assignment, `mvp_site/llm_capture.py` for AGY purpose-built rows, `mvp_site/bq_logging.py` for the BQ writer's `finish_reason` extraction).

**Anti-pattern (BANNED):**

- Trusting the watcher's "X% gap" headline without per-event_type breakdown. The watcher's threshold is a SINGLE NUMBER across multiple producer code paths; the gap's diagnosis lives in the breakdown, not in the headline.
- Filing a "fix Gemini coverage regression" PR based solely on the alert. The gap is almost always in the watcher's bucketing or in a producer's documented behavior, not in Gemini itself.
- Dismissing the alert as "vendor noise" without verifying the per-event_type table. A real gap on `gameplay_streaming` or `stream_story_with_game_state` will hide behind the same alert — those are the production surface, and any coverage drop on those two event_types IS worth investigating.
- Investigating `agy_request` rows as "missing response capture" — they are request-only by design (`mvp_site/llm_capture.py:77-85`); the test harness explicitly captures `request_json` only.

**Companion skills:** `wa-cloud-logging-diag` (bundled — for Cloud Logging `cdiag_name=...` queries; this section is for BQ `llm_forensics.llm_payloads` queries). The two surfaces share the same `worldarchitecture-ai` project but require different filter syntax (`jsonPayload.message:"..."` vs `bq query`).

### Streaming `response_text` coverage gap from code-execution-only turns (added 2026-08-19, Slack C0BCVG4F560/1787171879.658799)

Same watcher (`scripts/bq_coverage_watcher.py`), but the alert fires on the **streaming** bucket this time, not the non-streaming one. Verified on jleechanorg/worldarchitect.ai live 7d window (11181 streaming Gemini rows): the watcher reported streaming `response_text` at 97.48% (threshold 99.0%) and the headline looked like a real coverage regression. It was not.

**The recurring sub-class:** when the Gemini model uses native code execution (Python sandbox), it returns `finish_reason='success'` with `response_parts_json` containing ONLY `executable_code` / `code_execution_result` parts — no `text` part anywhere. The agent's structured response is then assembled from the code-execution output downstream. The `response_text` BQ column (which the streaming-gameplay logger at `gemini_provider.py:3794-3850` populates from `accumulated_text = "".join(accumulated_text)`) is correctly empty: there was no narrative to extract. The watcher's `_coverage_query` SQL does not know this, so it counts the row against `response_text` coverage.

**Verified decomposition (live 7d window, 57 streaming rows with valid `finish_reason` + empty `response_text`):**

| Class | Rows | Verdict |
|---|---|---|
| code-execution-only (parts contain only `executable_code` / `code_execution_result`, NO `text` part) | **17** | Correct behavior — agent used code execution, no narrative. ALL on `gemini-3-flash-preview`; 5 in last 24h on `gameplay_streaming`. |
| empty-envelope (`{"candidates": []}`, 18 bytes) with `finish_reason='success'` | 39 | Mostly `is_test=true` and `repro_copy_*` users; 3-4 real-user rows on `stream_narrative_simple`. Real bug class for follow-up. |
| `<MagicMock name='mock.finish_reason' id='...>` | 1 | Unit-test mock leaked into prod BQ. Real side bug — gate the test on `TESTING_AUTH_BYPASS` / `MOCK_SERVICES_MODE`. |

**Math:** current `n_resp_text_ok / n_completed` = 10896 / 10953 = 99.48% (barely above 99.0%); alert was 97.48% from a mid-window dip when code-exec-only rows accumulated faster than the window could absorb. After the proposed watcher fix: 10896 / (10953 - 17) = 10896 / 10936 = **99.63%** — gap cleared.

**Diagnosis recipe — when the streaming `response_text` head drops below threshold:**

1. **Reproduce the watcher's exact SQL first** (do not trust the alert body's denominator). The streaming branch of `_coverage_query` in `~/.smartclaw/scripts/bq_coverage_watcher.py` filters on `event_type IN ('gameplay_streaming', 'stream_story_with_game_state', 'stream_narrative_simple', 'continue_story_streaming', 'initial_story_streaming')` AND `finish_reason NOT LIKE 'error%' AND finish_reason NOT IN ('SAFETY', 'FinishReason.TOO_MANY_TOOL_CALLS', 'cancelled')`. Run with `bq query --project_id=worldarchitecture-ai` to capture `n_total`, `n_completed`, `n_resp_text_ok`. The head% is `100 * n_resp_text_ok / n_completed`.

2. **Decompose the empty-`response_text` bucket by `parts` shape.** This is the diagnostic that distinguishes the code-exec-only class from real coverage gaps:

```bash
cat > /tmp/q.sql <<'SQL'
WITH bad AS (
  SELECT *
  FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
  WHERE ingested_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
    AND model LIKE '%gemini%'
    AND event_type IN ('gameplay_streaming', 'stream_story_with_game_state',
                       'stream_narrative_simple', 'continue_story_streaming',
                       'initial_story_streaming')
    AND finish_reason NOT LIKE 'error%'
    AND finish_reason NOT IN ('SAFETY', 'FinishReason.TOO_MANY_TOOL_CALLS', 'cancelled')
    AND (response_text IS NULL OR LENGTH(response_text) = 0)
)
SELECT
  COUNT(*) AS n_bad,
  COUNTIF(
    NOT EXISTS (
      SELECT 1 FROM UNNEST(JSON_EXTRACT_ARRAY(response_parts_json, '$.candidates[0].content.parts')) AS p
      WHERE JSON_EXTRACT_SCALAR(p, '$.text') IS NOT NULL
    )
    AND EXISTS (
      SELECT 1 FROM UNNEST(JSON_EXTRACT_ARRAY(response_parts_json, '$.candidates[0].content.parts')) AS p
      WHERE JSON_EXTRACT(p, '$.executable_code') IS NOT NULL
         OR JSON_EXTRACT(p, '$.code_execution_result') IS NOT NULL
    )
  ) AS n_code_execution_only,
  COUNTIF(
    ARRAY_LENGTH(JSON_EXTRACT_ARRAY(response_parts_json, '$.candidates[0].content.parts')) = 0
    OR response_parts_json IS NULL
    OR LENGTH(response_parts_json) = 0
  ) AS n_empty_envelope,
  COUNTIF(
    REGEXP_CONTAINS(COALESCE(finish_reason, ''), r'<MagicMock')
  ) AS n_mock_finish_reason
FROM bad
SQL
bq query --nouse_legacy_sql --format=pretty < /tmp/q.sql
```

If `n_code_execution_only > 0`, the gap is NOT a coverage regression — it is the streaming-gameplay logger at `mvp_site/llm_providers/gemini_provider.py:3559-3566` correctly producing empty `response_text` when the model chose code execution only. Treat `n_code_execution_only` rows as "expected behavior" in the coverage denominator.

3. **Fix shape (watcher-side exclusion, the right place to fix it):** add a filter to the watcher's streaming `completed` denominator that excludes rows where `response_parts_json` contains ≥1 `executable_code` or `code_execution_result` part AND contains NO `text` part. ~5 lines of SQL + a unit test in `tests/test_bq_coverage_watcher.py`. Confirmed: applies the fix changes streaming pct from 97.48% → 99.63% on the live 7d window.

4. **Do NOT try to fix the upstream accumulator.** `gemini_provider.py:3559-3566` only appends parts with `.text`; a part with `text=None` (thought-only or code-execution-only) is dropped by design. Forcing the accumulator to fabricate `response_text` from `executable_code` parts would corrupt the `response_text` column with code, breaking every downstream consumer that parses it as narrative. The right separation: `response_text` = narrative text parts only; `response_parts_json` = full structured parts. The watcher's job is to know which surface it is measuring.

**Anti-patterns (BANNED):**

- Trusting the streaming `response_text` headline without breakdown. Same trap as the non-streaming case in the parent section — the alert body's pct is a SINGLE NUMBER across multiple producer code paths; the diagnosis lives in the per-`response_parts_json` parts breakdown, not in the headline.
- Filing a "fix Gemini streaming coverage" PR based on the alert alone. The gap is almost always the code-execution-only class, not a real coverage regression.
- Trying to force the upstream `accumulated_text` to populate from code-execution parts. This would corrupt `response_text` for downstream narrative consumers.
- Treating the empty-envelope or MagicMock rows the same as the code-execution-only rows. They need separate follow-ups (real-user bug on `stream_narrative_simple`; unit-test BQ write gate). Do not bundle them into the watcher fix.
- Skipping the live `bq query` reproduction because the alert body looks authoritative. The alert body's `n_total` can drift from the live 7d `n_total` by 10s of rows as new rows land; always reproduce before forming a fix.

**Worked example (2026-08-19, Slack `C0BCVG4F560/1787171879.658799`):**

| Bucket | n | Verdict |
|---|---|---|
| All streaming Gemini rows | 11183 | 7d window |
| `n_completed` (valid `finish_reason`) | 10953 | Streaming denominator |
| `n_resp_text_ok` (`response_text` non-empty) | 10896 | Streaming numerator |
| **Streaming `response_text` coverage** | **99.48%** | Above 99.0% threshold |
| Earlier alert (mid-window) | 97.48% | Below threshold → alert fired |
| `n_code_execution_only` | **17** | Excluded from denominator after fix |
| `n_empty_envelope` | 39 | Mostly test/repro; small real-user subset |
| `n_mock_finish_reason` | 1 | Unit-test mock leaked to prod BQ |

After proposed watcher fix: streaming coverage = 10896 / (10953 - 17) = **99.63%**. Headline gap cleared.

**Companion to (1.9.0) above:** same watcher, opposite bucket, same fix shape (per-event_type / per-`response_parts_json`-parts breakdown → SQL exclusion in the denominator → unit test). Two distinct bug classes, same diagnostic recipe. Whenever the watcher fires on either bucket, run the breakdown FIRST.

## Three-failure-same-PR infra-flake signature (added 2026-08-19, PR #9134 auto-char-mode)

A complementary pattern to the v1.8 single-job git-fetch RPC CANCEL. When 3 OR MORE jobs on the SAME SHA fail with the cancel/Missing-RESULT-marker/`##[error]The operation was canceled.` / `RESULT: TIMEOUT` signatures AND the same-run sibling shards are mostly green, that's a structural signal that the failures share an upstream runner-pool cause (network blip, runner recycle, FastEmbed model cold-cache download, graceful-shutdown window exceeded). Dismissal confidence goes up with the count of DISTINCT job types simultaneously failing — a single canceled lint job is ambiguous (could be a real ESLint crash on a new rule), but 3 distinct job types failing on the same SHA is almost certainly not a code-introduced bug.

**Verified failure mode (2026-08-19, PR #9134 auto-char-mode-after-think):**

Initial SHA `7c813675b0` showed 3 simultaneous failures:

1. `Directory tests (core-mvp-3 self hosted)` — log showed `❌ 1 test(s) failed` from the runner script counting `Missing RESULT marker (runner interruption likely)` as failures; the actual failing test was `mvp_site/tests/test_video_caption.py` whose only "timeout" was a FastEmbed HuggingFace model download (no real assertion failure). Sibling shards (`core-mvp-1`, `core-mvp-2`, `core-tests`) on the same run had passed.
2. `JavaScript Linting (ESLint)` — `##[error]The operation was canceled.` 5m12s into the lint step. Self-hosted runner recycled.
3. `PR Coverage Report` — `git fetch` exceeded the runner's checkout timeout 15m15s into the step. Self-hosted runner recycled.

All 3 followed the same cancel/Missing-RESULT-marker signature; logs showed `##[error]The operation was canceled.` with no test-assertion text; sibling shards were mostly green.

**Companion diagnosis recipe (distinguishes infra-flake from real test regression):**

```bash
# Step 1 — list the failing jobs and their assigned runners
gh api "repos/<owner>/<repo>/actions/runs/<run-id>/jobs" \
  --jq '.jobs[] | select(.conclusion != "success" and .conclusion != null) | "\(.name)\t\(.runner_name // "<none>")\t\(.conclusion)"'

# Step 2 — if multiple failed jobs share a runner_name prefix (e.g.
# ez-mac-runner-e-2, ez-mac-runner-e-4), that's the runner pool with the
# cold-cache / capacity issue. The runner name tells the operator which
# self-hosted runner to recycle.
```

Verified 2026-08-19 PR #9134: failed jobs were on `ez-mac-runner-e-2` (coverage) and other `ez-mac-runner-e-*` instances. On the rerun, the runner pool was re-allocated and all 16 jobs passed. The runner-name pattern is the diagnostic that says "this is runner pool cold-cache or capacity, not your code."

**Probe the failing class for each failed job — quick triage table:**

| Job log fingerprint | Class | Recovery move |
|---|---|---|
| `Missing RESULT marker (runner interruption likely)` + `RESULT: TIMEOUT` from runner script | FastEmbed cold-cache or graceful-shutdown window exceeded (self-hosted `ez-mac-runner-*` are the worst offenders) | Amend + force-push re-trigger; runner pool re-allocates |
| `##[error]The operation was canceled.` mid-checkout / mid-lint | Self-hosted runner recycled; nothing to do with the job's actual code | Amend + force-push re-trigger |
| `git fetch ... fatal: early EOF` / `fatal: RPC failed` during `actions/checkout` | Single-job git-fetch RPC CANCEL (the v1.8 pattern) | Amend + force-push re-trigger |
| Real `AssertionError` / `FAILED tests/test_X.py::test_Y` with assertion text | REAL test regression — same-SHA repro required | Fix code; do NOT dismiss |

If 3+ failed jobs land in the first three rows, infra-flake confidence is ~99%. If even one lands in the fourth row, stop and same-SHA reproduction.

**Better re-trigger recipe (verified 2026-08-19, PR #9134 — cleaner than `--allow-empty`):**

When the branch has the intent-matching commit already and the failure is purely a runner-cancel infrastructure flake (no code change), the cleanest CI re-trigger is `commit --amend --no-edit && git push --force-with-lease` rather than `--allow-empty`:

```bash
# From the worktree for the PR branch (must be a fresh worktree from
# origin/main so the amend doesn't rewrite an unrelated diffline)
git fetch origin main             # REQUIRED first - see warning below
git log --oneline origin/main..HEAD  # should show only the intent-matching commit
git commit --amend --no-edit
git push --force-with-lease origin <branch>
gh pr checks <PR> --repo OWNER/REPO --watch
```

This preserves the intent-matching commit message + author + provenance while giving CI a brand-new SHA, so CodeRabbit / Bugbot / skeptic re-trigger from the same logical commit without an extra `chore: re-trigger CI` commit polluting `git log origin/main..HEAD` or the PR's commit list.

The previously-recommended `--allow-empty` recipe (see failure-class triage section above) leaves a visible "chore: re-trigger CI" commit on the PR head, which CodeRabbit then reviews against the same diff as the prior commit — reviewers see two commits with no semantic content between them.

**Pre-condition (mandatory) — `git fetch origin main` BEFORE the amend.** Per SOUL.md `## COMMIT: pr-clean-branch-from-main-no-history-bloat`: if `origin/main` has moved since the worktree was based (even by 1 commit), `git commit --amend` won't rebase; the resulting SHA, when force-pushed, may land with `mergeable_state: dirty` and require another rebase cycle. Verify `git log --oneline origin/main..HEAD` shows ONLY the intent-matching commit before the amend.

**Empirical timing (verified 2026-08-19 PR #9134, self-hosted `ez-mac-runner-*` pool):** on the rerun, all 16 jobs that had failed or been cancelled on the prior SHA flipped to `success` (including coverage, ESLint, and 3 self-hosted shard tests). Total CI time from amend-push to all-16-success: ~8 min. This is a HIGHER success rate than the initial attempts succeeding on the very first push, suggesting the cancel/Missing-RESULT-marker pattern is genuinely a runner-allocation artifact and not a PR-code artifact.

**Anti-pattern (BANNED) — extra worker dispatch for a pure re-trigger:** routing the bring-to-green flow through a separate worker dispatch (`claudem -p ...`) when the fix is purely amend-and-force-push on an already-correct branch. The skill rule says "default is amend-with-lease; only when there is genuine code work to push" — passing through a worker for a re-trigger inflates the loop from 8 min to 30+ min and adds a handoff that can lose context.

**Worked example (2026-08-19, jleechanorg/worldarchitect.ai PR #9134, 12-line auto-char-mode patch):**

Decision: amend + force-push on SHA `7c813675b0 → 4f192869d`. Diffstat unchanged (`+12/-0` in `app.js` + `+82` in new test contract). Rerun results:

| Job | Initial SHA `7c813675b0` | Rerun SHA `4f192869d` |
|---|---|---|
| `JavaScript Linting (ESLint)` | canceled 5m12s | **success 1m20s** |
| `Directory tests (core-mvp-3 self hosted)` | failed (`Missing RESULT marker`) | **success** |
| `PR Coverage Report` | canceled 15m15s | **success** |
| `Directory tests (core-mvp-1/2, core-tests)` | success | success |
| `Wizard Mobile Scroll/CSS Regression` | success | success |
| `Detect Changed Paths` ×2 | success | success |
| `Green Gate`, `Design Doc Grep Gates`, `Light/Fantasy Compliance Gate`, `Planning Choices Composer Placement`, `detect-changes`, `limit-pruns` (×2), `pr-preview` deploy | success | success |

PR was MERGEABLE on the rerun SHA with NO code change between the two SHAs — pure CI reallocation win.

**Companion rule (the 2-retry ceiling):** if the FIRST rerun shows the same cancel/Missing-RESULT-marker class on DIFFERENT jobs (i.e. the runner pool is broadly flaky), retry one more time. If the SECOND rerun shows the same failure class on the SAME job, that is a structural runner-pool issue (capacity exhausted, specific `ez-mac-runner-X` wedged) — escalate rather than loop. Post `gh api repos/<owner>/<repo>/actions/runners` filtered to the failing runner name with the operator and ask them to recycle the specific runner. Do not loop more than twice on amend+force-push within the same hour — extra cycles don't help if the runner pool is starved and only widen the window for code-side drift.

**Stop-the-loop condition (verified 2026-08-19, PR #9134):** after ONE amend-and-force-push cycle on the SAME failure class, accept the rerun outcome as the verdict. If success → ship. If still failing the same class → escalate per the 2-retry ceiling. Do not loop. Loop-without-result is the anti-pattern that drove the 2026-08-19 dropped-thread C0AH3RY3DK6/p1787111878 incident.

## Failure-class triage before re-running CI (added 2026-08-19, PR #9096)

The same-name rule above proves a CI failure is pre-existing on `origin/main`. The **next** decision is whether to re-trigger CI (empty commit + push) for a fresh runner allocation, or to push a code fix. Misclassifying wastes 5-15 minutes per cycle. Classify FIRST, then act.

**Failure-class triage table** (matched against `gh run view --log-failed`):

| Symptom | Failure class | Recovery move |
|---|---|---|
| `##[error]The operation was canceled.` during `actions/checkout` (the git fetch step, not your test code) | Workflow cancelled mid-fetch — infra flake, `limit-pr-runs` killing an older run while a new one registers, OR network blip on self-hosted runner | Empty-commit re-trigger — same SHA gone, fresh runner allocated |
| `Building lxml` / `error: subprocess-exited-with-error` / `Please make sure the libxml2 and libxslt development packages are installed` | Self-hosted runner missing native dev headers; not your code | Empty-commit re-trigger — next attempt often pulls a cached wheel |
| `ModuleNotFoundError` / `ImportError` on a package you didn't change | Either a real missing `requirements.txt` entry (fix it) OR another shard's transient pip resolver failure (re-trigger) | Check sibling shards on the SAME run: if core-mvp-1 + core-mvp-3 passed but core-mvp-2 failed on import, infra flake — re-trigger |
| `state=none` on CodeRabbit after 30s, or `Review rate limited` | CR is rate-limited globally; not your PR | Cannot fix in-PR. Post `@coderabbit-ai review please` to nudge; or wait for rate window. See "Vendor rate-limit Green Gate failures" section below. |
| Real `AssertionError` / `FAILED tests/test_X.py::test_Y` with assertion text matching a known class | Your code introduced the regression | Reproduce locally with the repo's test runner, fix the code, push |
| `AssertionError` from a test file you didn't change | First verify same-name on `origin/main` (the rule above). If it repros on main → pre-existing, dismiss. If not → transitive import or shared fixture from your diff, fix. |

**Empty-commit re-trigger recipe** (for confirmed infra flakes only — never as a substitute for code fixes):

```bash
# From the worktree for the PR branch
git commit --allow-empty -m "chore: re-trigger CI (infra flake on <job-name>)"
git push origin HEAD
gh pr checks <PR> --repo OWNER/REPO --watch
```

**Why this works:** the runner that produced the failure is allocated per-workflow-invocation, not per-PR. A new SHA → new workflow → new runner → usually a working one. Don't loop more than twice on the same failure. If it persists after two re-triggers, the failure class was wrong and it's your code, not the runner.

**Don't confuse "infra flake" with "your code is flaky":** a test that fails 1-in-3 runs on `origin/main` IS flaky, but it is NOT an infra flake — fix it (re-run with `--count=10` to characterize, then add retry/pin). Infra flake = the workflow plumbing fails (checkout, setup, dep install), not the test logic.

**Worked example (2026-08-19, jleechanorg/worldarchitect.ai PR #9096, "circular Add Avatar button"):**

CI initially failed with 2 jobs:
1. `Directory tests (core-mvp-2(self hosted))` failed with `error: subprocess-exited-with-error` on `Building lxml version 6.1.2` → `libxml2/libxslt development packages are installed` → infra flake.
2. `Detect Changed Paths` failed with `##[error]The operation was canceled.` during `actions/checkout` → cancelled mid-fetch, infra flake.

Sibling shards on the SAME run #32217085179:
- `core-mvp-1` PASS
- `core-mvp-3` PASS
- `core-mvp-2` FAIL (lxml build)

Different shards hit the same runner pool, but only one hit the lxml build path on that attempt. The 3-shard pattern proved the failure was infra-flake, not code-introduced.

**Action:** empty-commit `chore: re-trigger CI to confirm lxml infra flake on core-mvp-2` pushed to `fix/avatar-circular-add-btn` (HEAD `0ac840b95c` → `ca06432ee6`). On the re-run:
- All 3 core-mvp shards PASS
- `Detect Changed Paths` PASS (both workflows)
- `Green Gate` PASS (7-green conditions met)
- PR `mergeable`, 0 FAIL, 0 pending

Total time: 6 min from re-trigger to all checks green. Without the failure-class triage (jumping straight to "what's wrong with my CSS?"), the loop would have been hours.

**Companion rule:** the empty-commit re-trigger is only for INFRA failures (workflow plumbing). Code-introduced regressions require a real fix; re-triggering just hits the same code path again. If after one re-trigger the same test fails with the same assertion text, STOP re-triggering — that's your bug.

**Pitfall (verified 2026-08-19):** posting a CodeRabbit `@coderabbitai review please` comment when the bot is rate-limited globally does NOT unblock the Green Gate. Green Gate Gate 3 reads the latest review state, not comment activity. If CR is rate-limited, your only real options are (a) wait for the rate window, (b) ask an admin to lift the quota, or (c) have a human post an APPROVED review manually. Don't loop commenting in the PR.

## Multi-round CodeRabbit review may never reach APPROVED in this stack (added 2026-08-19, PR #9100 share-landing)

The "CodeRabbit 'findings resolved' comment is sufficient" note above says empty `reviewDecision` is acceptable when Green Gate passes. That holds for **single-round** review flows. In the `jleechanorg/worldarchitect.ai` stack, observed 2026-08-19 on PR #9100 (a 6-comment round-trip across 3 re-reviews): **CodeRabbit posts `COMMENTED` state on every re-review; it never posts `APPROVED` after the agent addresses findings.** This blocks the skeptic `VERDICT: PASS` gate, which is what `skeptic-cron.yml` waits on before auto-merging.

**Symptom signature:**

- Green Gate passes on every push (Conditions 1, 2, 6, 7).
- CodeRabbit posts 1-2 `COMMENTED` reviews per push with new actionable findings; addressing each round produces another round of new findings on the new push.
- `gh pr view N --json reviewDecision` returns `null` (or `""`) the entire time. Never `APPROVED`.
- Skeptic cron never posts `VERDICT: PASS` — its gate requires CodeRabbit's latest review state to be `APPROVED`, not just `COMMENTED` with confirmed fixes in-thread.
- `mergeStateStatus` stays at `UNSTABLE` (no merge) or `null` (waiting on checks). Skeptic never picks it up.

**Verified PR #9100 (2026-08-19):** 3 CodeRabbit review rounds over 6 commits. Each round: agent fixes findings, pushes, CR re-reviews, posts 2-4 new findings, agent fixes, push, repeat. `reviewDecision: null` throughout. Final state: `mergeable: true` + 6/7 green + `mergeStateStatus: UNSTABLE` + skeptic never ran. Round-trip cost ≈45 min of CI cycles + 3 cancelled preview deploys (per `pr-preview` workflow's `cancel-in-progress: true` on push).

**Diagnostic recipe:**

```bash
# Count CodeRabbit reviews and their states for the PR
gh api "repos/<owner>/<repo>/pulls/<N>/reviews" \
  --jq '.[] | select(.user.login == "coderabbitai[bot]") | "\(.state)\t\(.submitted_at)"'

# If you see N >= 2 reviews and ALL are "COMMENTED" with no "APPROVED" row,
# skeptic will never fire. Surface this to the user explicitly.
```

**Recipe for this stack:**

1. **Surface the structural block to the user as soon as you see 2+ `COMMENTED` rounds with no `APPROVED`.** Do NOT keep iterating CR findings hoping for `APPROVED`. The bot's pattern is to surface new findings each round; round-N may not converge to round-(N+1)=`APPROVED`.
2. **Stop-the-loop condition:** after the 2nd `COMMENTED` round where every actionable item has been addressed AND the user's stated scope is met, report "this is a 6/7 PR blocked on a structural CodeRabbit-vs-skeptic interaction, not on code quality" — and offer to either:
   - (a) have the user post a manual human `APPROVED` review on the PR (unblocks skeptic immediately),
   - (b) wait for the next bot-cycle window where CR may auto-resolve (rare),
   - (c) merge via `gh pr merge` directly (bypasses skeptic but per `worldarchitect.ai` AGENTS.md requires `MERGE APPROVED` in the live user message).
3. **Avoid the loop-trap:** if you find yourself writing commit N+1 just to address the N+1'th round of CR findings, **stop and report**. Each force-push + cancel-in-progress preview cycle costs ~10-15 min and the bot's review-state doesn't accumulate into `APPROVED`.
4. **Do NOT mark CR threads as resolved in your head and claim "reviewDecision cleared"** — the bot's `COMMENTED` review state is independent of the in-thread `isResolved` flag, and the skeptic gate ignores thread resolution. The gate reads the top-level `state` on the latest review, not the thread count.

**Anti-pattern (BANNED, verified 2026-08-19):** continuing to push commit N+2, N+3, ... addressing CR's incremental findings with no convergence bound, while reporting "almost green, just one more round" to the user. This produces a PR stranded at 6/7 with no path to 7/7 through agent action alone. The correct path is to surface the structural block on the 2nd round and ask the user to unblock via manual review.

**Companion to `## COMMIT: pr-clean-branch-from-main-no-history-bloat`:** each force-push to address CR feedback rebases the branch; if `origin/main` has moved, the new push may land `mergeable_state: dirty` again, requiring another rebase. Bundle all CR feedback into one round-trip per push; do NOT push once per finding.

**Companion to `## COMMIT: proof-before-claim`:** after the structural block is identified, the proof block in the final reply MUST show (a) the exact count of CR `COMMENTED` reviews, (b) the exact `reviewDecision` value, (c) the skeptic verdict status (or "did not run / will not run given gate state"), and (d) the GH Actions check-rollup row showing all 6/7 conditions pass. Without those four, the user cannot evaluate the structural block and the conversation will loop on the same question.

**Probe that distinguishes "waiting on CR" from "waiting on Skeptic":**

```bash
# 1. CR state
gh api "repos/<owner>/<repo>/pulls/<N>/reviews" \
  --jq '[.[] | select(.user.login == "coderabbitai[bot]")] | max_by(.submitted_at) | .state'
# -> "" (empty) or "COMMENTED" means skeptic blocked; "APPROVED" means CR cleared

# 2. Skeptic verdict presence (auto-comment from github-actions[bot])
gh api "repos/<owner>/<repo>/issues/<N>/comments" \
  --jq '[.[] | select(.user.login == "github-actions[bot]" and (.body | contains("VERDICT")))] | length'
# -> 0 means skeptic never ran; >=1 means skeptic produced a verdict
```

If the probe returns `("" or "COMMENTED")` + `0`, the structural block is real. Surface to user; don't iterate.

## `set -euo pipefail` abort disguised as cosmetic stderr (added 2026-08-18, PR #827 dropped-thread-followup fix)

A bash script under `set -euo pipefail` can abort mid-run producing only `last exit code = 1` from launchd, while stderr is filled with unrelated noise. The real abort can hide for days because the noise looks like the cause.

**Verified failure mode (2026-08-18, jleechanorg/jleechanbrain #827):**

Script `~/.smartclaw/scripts/dropped-thread-followup.sh` (1882 lines, `set -euo pipefail` at line 36) had been dying mid-run since 2026-08-11 — last successful `Done — actioned=N skipped=N` line was `2026-08-11T19:38:38`. The launchd `last exit code = 1` was attributed (incorrectly) to "cosmetic broken-pipe stderr on line 462" because stderr had 19 instances of `line 462: echo: write error: Broken pipe`. The 5th priority channel `${SLACK_CHANNEL_ID}` was never scanned on any tick.

The real abort was at line 1680: `detect_agent_fabrication` returns `1` for the ordinary "not a fabrication" case, but it was invoked as a bare command followed by `_fab_rc=$?` on the next line. Under `set -e`, that non-zero return aborts the entire script before the channel loop finishes.

**Recipe — pinpoint the abort with an ERR trap:**

```bash
# 1. Copy the script to a temp location so the trace doesn't pollute it
cp /path/to/script.sh /tmp/script-trace.sh

# 2. Inject an ERR trap right after `set -euo pipefail`
python3 - <<'PY'
p = '/tmp/script-trace.sh'
s = open(p).read()
s = s.replace("set -euo pipefail",
              "set -euo pipefail\ntrap 'echo \"ERRTRAP line=$LINENO cmd=[$BASH_COMMAND] rc=$?\" >&2' ERR", 1)
open(p, 'w').write(s)
PY

# 3. Run in dry-run mode and grep for the trap output
DRY_RUN=1 bash /tmp/script-trace.sh > /tmp/out 2> /tmp/err
grep ERRTRAP /tmp/err | tail -5
```

The trap output pinpoints the exact line and command that triggered the abort — far more reliable than reasoning about stderr noise. In the PR #827 case:

```
ERRTRAP line=1680 cmd=[return 1] rc=1
```

That single line identified the abort inside `detect_agent_fabrication`, distinguishing it from the 19 broken-pipe stderr lines (which `trap '' PIPE` at line 43 had already neutralized).

**General fix pattern:** every call to a function that returns `1` for the "no match" / "skip" / "continue" case MUST be guarded when the script uses `set -e`:

```bash
# Anti-pattern (bare call → set -e aborts on the common return-1 case):
detect_agent_fabrication "$channel" "$thread_ts" "$_penultimate_ts" "$_last_ts" "$_last_text" "$_fabrication_tmp"
_fab_rc=$?

# Correct pattern (pre-seed the rc, then guard the call):
_fab_rc=0
detect_agent_fabrication "$channel" "$thread_ts" "$_penultimate_ts" "$_last_ts" "$_last_text" "$_fabrication_tmp" || _fab_rc=$?
```

**Regression test (also shipped in PR #827):** `tests/test_dropped_thread_followup_set_e.py` — RED on origin/main (3 failures), GREEN on the patched branch. The generalized check #6 flags *any* `_rc=$?` capture following an unguarded command call, so this bug class can't return elsewhere in the script.

**Lesson for bring-to-green reports:** when a launchd / cron service has been logging `last exit code = 1` for days with no actionable stderr, the abort is rarely the most-recent stderr line. Inject an ERR trap on a copy of the script and run dry-run; the trap pinpoints the abort in one round-trip.

## GitHub REST vs GraphQL rate-limit buckets (verified 2026-08-13 PR #8881 babysit)

`gh pr view --json ...`, `gh pr checks`, `gh pr comment`, and `gh api graphql` ALL hit GitHub's GraphQL bucket. The REST endpoints (`gh api repos/.../commits/.../check-runs`, `gh api -X POST repos/.../issues/<N>/comments`) are SEPARATE quota. When babysitting or green-up-polling a PR across many iterations and the GraphQL bucket hits zero, pivot to REST:

```bash
# Per-commit CI status via REST (replacement for `gh pr checks --watch`)
SHA=$(gh pr view <N> --repo <owner>/<repo> --json headRefOid -q .headRefOid)
gh api "repos/<owner>/<repo>/commits/${SHA}/check-runs?per_page=100" \
  --jq '.check_runs[] | "\(.conclusion // .status) \(.name)"'

# PR comment via REST (replacement for `gh pr comment <N> --body ...`)
gh api -X POST "repos/<owner>/<repo>/issues/<N>/comments" -f body='...'
```

Note: PR comments are routed through `issues/<N>/comments` (PRs are issues under the hood), not `pulls/<N>/comments`. The `issues` endpoint accepts both regular comments and `@bot` mentions that bots respond to.

**CodeRabbit "findings resolved" comment is sufficient — no formal APPROVED review required.** CodeRabbit's auto-confirm reply (the 🐇 ✅ comment after a fix push) carries a `<review_comment_addressed>` marker that Green Gate treats as resolving the corresponding thread, but the bot does NOT always post a fresh `APPROVED` review afterward. `reviewDecision` can stay empty (`""`) on the PR even though CR has confirmed the fix in a comment thread. Per `drive-pr-to-green` Step 8, empty `reviewDecision` is acceptable as long as Green Gate passes; do not block on a missing `APPROVED` review when CR has confirmed in-thread.

## Vendor rate-limit Green Gate failures (added 2026-08-14, PR #819)

A common false-positive dismissal class: **Green Gate gate 3 (CR approved) or gate 5 (comments resolved) FAIL because the third-party bot vendors (CodeRabbit, Cursor Bugbot, chatgpt-codex-connector) hit rate limits and posted placeholder "couldn't run" messages that count as unresolved comments.** The PR has no real review feedback — the bot simply didn't run.

**Diagnosis recipe — pull the bodies, don't trust the count:**

```bash
gh pr view <N> --repo <owner>/<repo> --json comments \
  | jq -r '.comments[] | "[\\(.author.login)] \\(.body[0:200] // \"\")"'
```

If you see any of these, the comment is a vendor rate-limit, NOT real CR feedback:

| Vendor | Rate-limit signal in body |
|---|---|
| **CodeRabbit** | `> [!WARNING]\n## Review limit reached` OR `<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->` |
| **Cursor Bugbot** | `<h3>Bugbot couldn't run - usage limit reached</h3>` OR `A user or team admin can review and increase` |
| **chatgpt-codex-connector** | empty body with `@codex review` mention (vendor didn't run) |

**Counted-as-unresolved but actually irrelevant.** Green Gate gate 5 reads GraphQL `isResolved` on review threads. Vendor "couldn't run" comments land as unresolved threads because no bot replied to resolve them. Treating them as real unresolved feedback is a false-positive dismissal — the work isn't broken, the vendor's quota is exhausted.

**Verified PR #819 (jleechanorg/jleechanbrain, 2026-08-14):**
- 7 unresolved comments per Green Gate, but actual breakdown: 3× Bugbot "usage limit reached" + 2× CodeRabbit "Review limit reached" boilerplate + 1× real `@coderabbitai all good?` ping + 1× Green Gate FAIL echo
- Only 1 was real feedback; the other 6 were vendor-side rate-limit placeholders
- Correct action: surface the breakdown to the operator, let them decide retry vs admin-override vs wait. Do NOT silently dismiss the Green Gate FAIL ("it's vendor rate-limit, not real"); the operator owns the merge decision.

**Pair with `drive-pr-to-green` Step 7c** for the full recipe: diagnosis commands, operator-facing decision matrix, anti-patterns (don't blindly re-trigger, don't silently merge, don't silently wait).

## Two-sided render+persist bug — server-side parser-coverage masquerades as LLM-side emission failure (added 2026-08-18, jleechanorg/worldarchitect.ai #9056)

A common false-positive dismissal class for "field X in the UI is stale / wrong / not advancing" reports: **the symptom is attributed to the LLM not emitting the field correctly when the actual cause is a two-sided server-side bug where the persistence parser doesn't recognize the LLM's emitted shape AND a render-side "canonical-repair" function blindly trusts the canonical and overwrites a correct LLM-emitted value.** The LLM is doing the right thing — emitting the field in the same shape the render layer uses, in a shape the persistence layer does NOT parse.

**Verified failure mode (2026-08-18, jleechanorg/worldarchitect.ai #9056):**

User reported: "time in the session header isn't marching the narrative" on campaign `SGxsM2xdermqwOmI37SF`. The export showed every story entry's `Timestamp:` line stuck at `1192 DR, Highharvestide 117, 22:30:00` while the narrative clearly advanced (Morning 09:45 → Midday 13:00 → Evening 21:00 → Dawn 06:00 next day across scenes 261–264). Initial dismissal instinct: "the LLM isn't advancing time." Wrong.

BQ inspection of `worldarchitecture-ai.llm_forensics.llm_payloads` showed the LLM was emitting the correct advancing timestamp in BOTH the `session_header` text AND `state_updates.world_data.world_time`. But:

- **Side A — persistence:** `mvp_site/world_time.py:ensure_progressive_world_time` invoked `parse_timestamp_to_world_time` which only handles ISO via `datetime.fromisoformat`. The LLM emits `world_time` as a STRING (the same shape `session_header` text uses, e.g. `"1192 DR, Highharvestide 118, 13:00:00"`). The fantasy-string shape fails ISO parsing → returns `None` → `world_data.pop("world_time", None)` silently dropped it on every turn. Canonical `world_data.world_time` stayed stuck.
- **Side B — render:** `mvp_site/session_header_utils.py:_repair_session_header_timestamp` runs on every turn. It reads the stale canonical `world_time` and unconditionally rewrites the LLM-emitted correct `Timestamp:` line with the stale canonical value. The repair log fired on EVERY turn (not just legitimate backward steps) — the smoking gun.

Both sides required. Fixing only Side A makes canonical advance but the bug stays until Side B is also conditioned to repair only on backward steps. Fixing only Side B preserves the LLM's correct value but canonical stays stale. Fixing both unblocks the symptom.

**Diagnosis recipe — 3 evidence blocks:**

1. **BQ: what did the LLM emit in `session_header` text vs `state_updates`?**

```sql
SELECT
  FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%E*SZ', ingested_at) AS ts,
  agent,
  turn_index,
  REGEXP_EXTRACT(response_text, r'\"session_header\"\\s*:\\s*\"(\\[SESSION_HEADER\\][^\"]{0,180})') AS session_header_head,
  REGEXP_EXTRACT(response_text, r'\"\"world_time\"\"\\s*:\\s*\\{[^}]{0,400}') AS world_time_structured,
  REGEXP_EXTRACT(response_text, r'\"\"world_time\"\"\\s*:\\s*\"([^\"]{0,80})') AS world_time_string
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id = '<CID>'
  AND agent IN ('StoryModeAgent', 'GodModeAgent')
  AND ingested_at > TIMESTAMP('<BUG_START_TS>')
ORDER BY ingested_at ASC
```

If `world_time_structured` is empty AND `world_time_string` is populated, the LLM is emitting `world_time` as a string. If `session_header_head` shows the LLM's correct timestamp but the persisted story export shows a different (older) timestamp, both sides are confirmed firing.

2. **Firestore REST: what does the canonical persisted `world_data.world_time` actually look like?**

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://firestore.googleapis.com/v1/projects/worldarchitecture-ai/databases/(default)/documents/users/<UID>/campaigns/<CID>/game_states/current_state" \
  | python3 -c "import sys, json; print(json.dumps(json.load(sys.stdin)['fields']['world_data']['mapValue']['fields']['world_time']['mapValue']['fields'], indent=2))"
```

If the `year/month/day/hour/minute/second` structured fields are stuck at a turn where the LLM emitted a string form (per Query 1), Side A is confirmed.

3. **Story export: what does the persisted `session_header` actually contain?**

After `scripts/download_campaign.py`, grep the story text for `Timestamp:`. If the export's `Timestamp:` is stale but BQ `session_header_head` shows the LLM emitted a fresh value, Side B is confirmed firing.

**Smoking gun — the repair log fires on every turn.** If the `SESSION_HEADER_TIMESTAMP_REPAIR` log fires on EVERY turn (not just legitimate backward-step turns), Side A has made canonical stale and Side B is over-firing. Fix Side A first; Side B's over-firing is the downstream symptom.

**Anti-pattern (BANNED):** dismissing the report as "the LLM isn't emitting time correctly" or proposing a prompt-layer fix. The LLM here is doing the right thing — emitting the field, in the same shape the render layer uses, in a shape the persistence layer does NOT parse. The fix is server-side parser coverage (add a parser for the LLM's emitted shape) + condition the repair function on backward-step-only. Verify the LLM actually received the rule / actually emitted the field BEFORE proposing any prompt-layer fix.

**Cross-reference:** this is structurally distinct from the LLM-side missing-write / wrong-write class in `references/two-pronged-render-and-persist-bug.md` (jleechanorg/worldarchitect.ai #8283). The LLM IS writing the field. The bug is in the parser/persistence/render chain on the server side.

**Fix shape (2 halves, both required):**

1. **Half 1 — persistence: parser coverage for the LLM's emitted shape.** Add a fantasy-calendar string parser to `mvp_site/world_time.py:parse_timestamp_to_world_time` (or as a sibling helper). Recognize the `"<year> <ERA>, <month> <day>, <HH>:<MM>:<SS>"` shape and map it to a structured dict using the existing `MONTH_MAP` at `mvp_site/world_time.py:11–73`.
2. **Half 2 — render: condition the repair on a backward step only.** Change `_repair_session_header_timestamp` to only replace the LLM-emitted timestamp when the canonical is strictly NEWER than the LLM-emitted value (the legitimate rewind case). NEVER overwrite a correct advancing LLM timestamp with a stale canonical.

If only Half 1 ships, the canonical advances but Side B over-fires on any future stale canonical (migration, partial update race, god-mode rewind). If only Half 2 ships, the bug is also fixed (the LLM's correct value is preserved) but canonical stays stale. If both ship, the canonical advances AND the LLM's correct value is preserved AND a legitimate rewind still fires.

## Infra-flake dismissal via git-fetch RPC CANCEL — no same-SHA repro required (added 2026-08-19, PR #9100 share-landing)

The same-name rule above is for **test assertion failures**. A different dismissal class is **workflow plumbing failures** where the runner's git fetch itself hangs or is cancelled before any test runs. These dismissals are valid WITHOUT a same-SHA reproduction on `origin/main` because the failure is in the runner plumbing, not in test code.

**Symptom signature** (verified PR #9100, job `95981255666` / Directory tests (core-tests), runner `ez-mac-runner-e-1`):

```
##[error]error: RPC failed; curl 92 HTTP/2 stream 5 was not closed cleanly: CANCEL (err 8)
##[error]error: 4081 bytes of body are still expected
fetch-pack: unexpected disconnect while reading sideband packet
##[error]fatal: early EOF
##[error]fatal: fetch-pack: invalid index-pack output
The process '/usr/bin/git' failed with exit code 128
...
##[error]The operation was canceled.
```

This is `actions/checkout` failing during the git fetch step — exit code 128 from `git fetch`, not from any test runner. The same failure can also appear as `chmod: cannot access 'scripts/runner_health_score.py': No such file or directory` if the checkout partially succeeded (the runner-health score script is in `scripts/` but the checkout never reached the working tree).

**Why same-name repro is NOT required:** there is no test name to reproduce. The failure is `git fetch` returning 128, which happens before pytest is invoked. Running the failing test on `origin/main` HEAD would not reproduce anything because no test ran.

**Dismissal recipe:**

1. `gh run view <run-id> --job <job-id> --log | grep -E "RPC failed|exit code 128|fatal: early EOF|##\\[error\\]The operation was canceled"` to confirm the abort was in `actions/checkout`, not in test code.
2. Sibling shards on the SAME run: if `core-mvp-1` + `core-mvp-3` PASS but `core-mvp-2` fails on the fetch, infra flake confirmed (different shards hit different runner allocations; one bad fetch doesn't mean code regression).
3. The runner name in the log (e.g. `ez-mac-runner-e-1`) is a useful signal: self-hosted mac runners (`ez-mac-runner-*`) flake on git fetch more often than GitHub-hosted Linux runners.
4. Re-trigger recipe is the same empty-commit dance documented in the failure-class triage section above: `git commit --allow-empty -m "chore: re-trigger CI (infra flake on <job-name>)" && git push origin HEAD`.

**Worked example (2026-08-19, PR #9100 share-landing):** Job `95981255666` (Directory tests (core-tests)) failed with exit 128 during `actions/checkout` after the second fetch retry. Sibling shards on the SAME run `32223909090` all PASSED (`core-mvp-1` / `core-mvp-2` / `core-mvp-3`). The PR's actual code path was untouched by the failure — `share_token.py` had 161 passing share-token tests on the prior local run. Re-trigger: empty commit + push; new run queued; gate flipped to PASS within ~10 min.

**Pitfall — don't confuse this with a real test regression:** if the log shows `tests/test_X.py::test_Y FAILED` with assertion text, it IS a test regression and needs the same-SHA repro recipe. The infra-flake dismissal applies ONLY to `actions/checkout` / `setup-python` / dependency-install failures, not to test assertions.

## `scope-split-on-mid-task-redirect` companion rule (added 2026-08-18, PR #9089 follow-up)

The same-name rule proves a CI failure is pre-existing on `origin/main`. That is a **verification outcome** — it tells you the in-flight PR is not the cause. It does **NOT** authorize bundling the pre-existing failure's fix into the in-flight PR's branch.

**Verified failure mode (2026-08-18, jleechanorg/worldarchitect.ai #9089):**

PR #9089 (`feat/move-hide-dice-to-settings`) was MERGEABLE on its 7-file scope (`+122/-95`). Operator replied mid-task with: *"just fix those tests too"*. The "those tests" were two pre-existing failures confirmed via same-name reproduction on `origin/main @ edc257eeda`:

- `mvp_site/tests/frontend/test_app_js_structured_fields.js`: 40/42 (Test 6 `Interaction handler passes full data` regex too strict; Test 30 `New campaign path scrolls first narrative entry` references three patterns absent from app.js)
- `mvp_site/tests/frontend/test_frontend_structured_fields.js`: `Cannot find module 'jsdom'`

The agent started investigating the test fixes (regex tweaks, jsdom install, app.js scroll-code archaeology) instead of dispatching them as a separate PR. The in-flight PR's scope was being polluted with redirects that didn't belong to it. Operator caught it: *"oh wait if PR is polluted then /harness to see why you did that and make two PRs"*.

**Recipe — when a user redirects mid-task to fix a pre-existing CI failure:**

1. **Verify pre-existing via the same-name rule** (sections above). Same test name, same assertion, same file at the same commit, explicit same-SHA reproduction on `origin/main`. All four must pass before the redirect is even a candidate for a follow-up PR.
2. **Stop the in-flight edit on PR scope A.** Do NOT add files for the redirected fix to the in-flight branch. The branch's diffstat should remain at its intended scope; the redirect becomes a separate worktree + branch + PR.
3. **Dispatch the redirect as a separate claudem worker on a fresh worktree from `origin/main`** — full brief: symptom, same-SHA reproduction, file paths, test names, exact failing assertion text, and verification commands. Per `## COMMIT: scope-split-on-redirect` (SOUL.md, jleechanbrain origin/main `fc2d4f12b1`), the default sequence is: post in-thread that B is a separate PR, dispatch B via `bash -lic 'claudem -p "<task>"' --max-turns <N>` from a fresh `feat/<B-slug>` worktree based on `origin/main`. AO only when user typed `/af`.
4. **Report both PRs to the user** in the same in-thread reply: PR #A (in-flight) at its current scope + state, PR #B (redirect) URL once the worker opens it.
5. **If the user explicitly says "include in the same PR" or "bundle with PR <A>"**, absorb is allowed and the rule defers. Without that explicit consent, default to split.

**Anti-pattern (BANNED) — verified 2026-08-18 PR #9089:**

The agent started editing the test files IN the `feat/move-hide-dice-to-settings` branch. The intent was to satisfy the "just fix those tests too" redirect by absorbing the test-fix into PR #9089. The cost was:

- The test fixes would have inflated PR #9089's diffstat from `+122/-95` to `+200+` lines across 9 files — outside the PR's stated scope.
- The 7-file scope had been carefully rebased onto `origin/main @ edc257eeda` to avoid scope pollution (per `pr-clean-branch-from-main-no-history-bloat`). Bundling unrelated work would have re-polluted it.
- Operator caught it within minutes. If undetected, the PR would have landed with `git log --oneline origin/main..HEAD` showing 3 unrelated test-fix commits mixed in with the dice-setting move — same anti-pattern as the 2026-07-14 PR #8401 / PR #8403 incident that produced the `pr-clean-branch-from-main-no-history-bloat` SOUL.md commit in the first place.

**Companion SOUL.md rule:** `## COMMIT: scope-split-on-redirect` (jleechanbrain `origin/main` `fc2d4f12b1`, 2026-08-18). Trigger: mid-task PR scope A + user issues follow-up imperative targeting scope B (fix or feature unrelated to A's stated scope). Default action: stop A's in-flight edit, post in-thread that B is a separate PR, dispatch B via claudem on a fresh worktree from `origin/main` with full brief.

**Anti-pattern (BANNED) — "while we're cleaning up the CI, also fix X":** A redirect like *"while you're cleaning up the CI, also fix <unrelated-flaky-test>"* is a scope-pivot. The same-name rule may prove X is pre-existing on `origin/main`, but that doesn't authorize absorbing X into the in-flight PR. Dispatch X as a separate PR; do NOT touch X on the in-flight branch.

**Lesson:** the same-name rule's verification outcome (`dismissal as pre-existing`) is **separate from the PR's branch contents**. Don't let the verification skill's success (proving the failure is pre-existing) leak into a license to add unrelated commits to the in-flight branch.

## Fix-main-CI-red-PR pattern: don't rebase your PR onto the fix-PR's tip (added 2026-08-20, PR #9167)

When the same-name rule proves a CI failure is pre-existing on `origin/main`, AND another open PR (branch convention `fix/main-ci-red-<symptom>` — e.g. `fix/main-ci-red-divine-prompts-and-api-routes`) already contains the commit that fixes those exact failures, the temptation is to `git rebase origin/fix/main-ci-red-<symptom>` and ride their commit into your PR to make CI green immediately.

**This is BANNED.** It violates `pr-clean-branch-from-main-no-history-bloat` + `never-push-onto-someone-elses-pr-head` — the rebase drags the fix-PR's commit into your PR's diffstat, polluting your PR's stated scope (your feature PR now shows `main.py` + `test_divine_prompts_setting_agnostic.py` changes that have nothing to do with your feature). User-visible symptom: "why does my thinking-level PR touch `main.py`?"

**Verified failure mode (2026-08-20, jleechanorg/worldarchitect.ai PR #9167):**

- PR #9167 (`feat/gemini-thinking-low-medium`) was structurally ready: `MERGEABLE`, `isDraft:false`, `reviewDecision:""`, 3-file diff (`gemini_provider.py` +48/-0, `test_budget_path_consistency.py` +3/-5, `test_gemini_provider_thinking_config.py` +285 new).
- CI red on `Directory tests (core-mvp-2 self hosted)` due to `test_api_routes.py::test_create_campaign_logs_request_keys_and_warns_on_deprecated_prompt` (line 560: `AssertionError: Request keys must be logged`) + `test_divine_prompts_setting_agnostic.py` (24 sub-failures looking for `## Followers (F)`, `## Per-Dawn Choice Menu`, `## AT-3 Legendary Actions`, `XP: 1,255,000/1,305,000`).
- Same-name rule proved both failures are pre-existing on `origin/main @ 3a6a5c9174` (exact SHA reproduction).
- An open PR #9204 (`fix/main-ci-red-divine-prompts-and-api-routes`) contained the fix: `mvp_site/main.py` +19/-0 + `mvp_site/tests/test_divine_prompts_setting_agnostic.py` +278/-378.
- Agent ran `git rebase origin/fix/main-ci-red-divine-prompts-and-api-routes` — the rebase succeeded and the diff stat grew to 5 files (`gemini_provider.py`, `main.py`, `test_budget_path_consistency.py`, `test_divine_prompts_setting_agnostic.py`, `test_gemini_provider_thinking_config.py`).
- Agent immediately undid with `git reset --hard origin/feat/gemini-thinking-low-medium` because the polluted diff was a scope violation. Cost: 1 rebase + 1 reset cycle, ~5 min wasted. No remote force-push happened (caught in time).

**Correct sequence — wait for fix-PR to merge, then clean-rebase your PR:**

1. **Wait for `fix/main-ci-red-*` to merge to `origin/main`.** Skeptic-cron runs every ~30 min; once Directory tests unjam and Green Gate re-passes VERDICT, the fix-PR auto-merges. Or operator merges manually with `MERGE APPROVED`.
2. **From your PR's worktree: `git fetch origin main`.**
3. **Clean-rebase your PR onto the new `origin/main`** — your PR's existing commits replay cleanly because they don't conflict with the fix-PR's commit (your PR touches `gemini_provider.py`; the fix-PR touches `main.py` + `test_divine_prompts_setting_agnostic.py`).
4. **Verify the diff stat is unchanged after rebase:** `git diff --stat origin/main..HEAD` should show exactly your PR's original files, NOT the fix-PR's files. If the fix-PR's files appear, you rebase-polluted — `git reset --hard origin/<your-branch>` and rebase from a clean worktree.
5. **Watch CI on your PR go green naturally** — your PR no longer carries the pre-existing failure because `origin/main` now has the fix.

**Verified outcome (2026-08-20, jleechanorg/worldarchitect.ai #9167+#9204):** Locally re-cloned PR #9204's branch tip, ran `bash ./run_tests.sh mvp_site/tests/test_api_routes.py mvp_site/tests/test_divine_prompts_setting_agnostic.py` — both pass (100% success rate). The fix-PR's commit unblocks CI for everyone; once it's on `origin/main`, your PR's CI naturally goes green without needing to drag the fix commit into your diff.

**If you cannot wait** (user explicitly demands green-now, e.g. "fix CI tests and bring to /ready"): **ASK one direct blocking question** — *"PR #X has the fix; do you want me to (a) merge X first then I clean-rebase, or (b) authorize me to skip X's queued CI and merge X directly?"* — do NOT auto-pick and rebase-pollute.

**Anti-pattern (BANNED) — verified 2026-08-20, PR #9167:**

The agent briefly ran `git rebase origin/fix/main-ci-red-divine-prompts-and-api-routes` to make CI green immediately. The rebase dragged `mvp_site/main.py` and `mvp_site/tests/test_divine_prompts_setting_agnostic.py` into the feature PR's diffstat. Even though the agent caught it and reset within minutes, the cost was a cycle that any agent running unattended would have force-pushed.

This is the inverse direction of the same anti-pattern that bit PR #8401 / PR #8403 (pushing onto someone else's PR head — polluting *that* PR with your work). Same rule, different direction: **don't merge someone else's CI-fix work into your feature PR's diffstat**.

**Companion rules:**

- SOUL.md `## COMMIT: pr-clean-branch-from-main-no-history-bloat` — branch from `origin/main`, never from someone else's PR head or fix branch.
- SOUL.md `## COMMIT: never-push-onto-someone-elses-pr-head` — three gates: `gh pr view` for owner + headRefName; `diff --shortstat` for size; `log --grep='^Merge remote-tracking branch'` for merge-commit signature. Same logic applies to rebase targets: don't rebase onto someone else's fix branch tip.
- SOUL.md `## COMMIT: scope-split-on-redirect` — companion rule covers the redirect absorption case; this section covers the fix-PR rebase absorption case. Both violations look like "feature PR has files it shouldn't have."

**Diagnostic recipe — when the temptation to rebase-pollute arises:**

```bash
# Before running the rebase, predict the resulting diffstat
git fetch origin fix/main-ci-red-<symptom>
git merge-base HEAD origin/fix/main-ci-red-<symptom>   # usually = origin/main SHA
git log --oneline origin/main..origin/fix/main-ci-red-<symptom>   # the commits you'd absorb
git diff --stat origin/main..origin/fix/main-ci-red-<symptom>      # the files they'd add

# If `git diff --stat` shows files your PR does NOT touch, the rebase WILL
# pollute your PR. STOP — use the wait-for-merge-then-clean-rebase path
# instead.
```

If your PR does touch some of those files, conflict resolution becomes load-bearing — cherry-pick the fix-PR's commit with `git cherry-pick -x <sha>` only if (a) your PR's branch was originally based on `origin/main` not the fix-PR's branch, AND (b) the cherry-picked commit's changes don't depend on the fix-PR's other commits. Default to wait-then-clean-rebase; cherry-pick is the exception, not the rule.

## MERGEABLE ≠ READY reply-shape lie pattern (2026-08-20, see references/2026-08-20-ready-lie-pattern-and-workflow-run-side-effect.md)

The companion reference file captures the operator pushback pattern (`"you keep making PRs with red CI..."`) and the load-bearing fixes: `gh pr view --json mergeable == MERGEABLE` proves only "no merge conflict", NOT CI-green. The single-call runner `~/.smartclaw/scripts/pr_ready_checklist.sh <PR>` enforces the 8-gate version (isDraft, mergeable, all CI COMPLETED, Green Gate, CodeRabbit, Cursor Bugbot, unresolved threads, Evidence Gate). Use it before any "ready" claim — see the reference for the recipe, banned reply phrases, and the `gh workflow run` cancel-side-effect pitfall.
