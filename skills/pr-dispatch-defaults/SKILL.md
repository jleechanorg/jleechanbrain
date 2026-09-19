---
name: pr-dispatch-defaults
version: 1.10.0
description: Decide INLINE vs dispatch for coding work. Default is INLINE for ordinary coding (incl. drive-to-green on PRs this session just opened). AO is opt-in only via /af, /auto-factory, /claw, or explicit user dispatch.
triggers:
  - "should I dispatch this"
  - "inline vs dispatch"
  - "ao spawn or inline"
  - "claudem or inline"
  - "just code directly yourself"
  - "code directly yourself"
  - "code it inline"
  - "dispatch or do it myself"
  - "spawn a worker for"
  - "drive to green"
  - "drive to PR green"
  - "drive to mergeable"
  - "drive PR to green"
  - "drive the PR green"
  - "babysit my PR"
  - "babysit PR"
  - "delegate_task"
  - "delegate task"
  - "fix this and make a PR"
  - "ok how to fix? let's make a PR"
  - "directly code"
  - "test it real end2end"
  - "keep going don't stop"
  - "do we need a test case"
allowed-tools:
  - Read
  - Bash
  - Grep
context: inline
changelog:
  - "1.10.0 (2026-09-17): New pitfall \"Auto-mirroring a parallel test for every prod-line addition without asking\" (jleechanorg/worldarchitect.ai PR #9911). User correction: \"I think we don't need a test case?\" — agent had shipped a 20-line diff (1 prod + 19 parallel test) for a 1-line whitelist addition mirroring an existing tested pattern, had to force-push to drop the test. Default rule: prod-only diff unless (a) NEW branch of logic, (b) user explicitly asked for tests, or (c) the test would catch a regression the canonical pattern doesn't already cover. Related: `pr-conventions` skill (prod vs non-prod delta convention)."
  - "1.9.0 (2026-08-23): Added `references/wa-spa-catchall-hosting-hygiene-2026-08-23.md` and a new pitfall section \"WA hosting-hygiene fix MUST preserve SPA routes — Accept-header discrimination pattern\". Verified-broken case: PR #9270 v1 made `serve_frontend()` return 404 for every non-`game/` path; Cursor Bugbot flagged medium risk; agent dismissed it and pushed; CI then failed on /new-campaign and /settings (Light/Fantasy Compliance Gate FAIL, Wizard Mobile Scroll FAIL). Recovery pattern: 404 markdown ONLY when Accept header lacks `text/html`; whitelist SPA-route prefixes (`game/`, `campaign/`, `shared/`, `auth/`, `play/`, `new-campaign`, `settings`, `dashboard`). Adds corollary: never dismiss a Bugbot medium-risk warning on a hosting-shape change without first running the audit-spec curl + a Playwright smoke through one SPA route. Also: add `qa-test-failure-dismissal-anti-pattern` discipline — when worker or gateway says \"must be pre-existing,\" do the same-SHA repro before dismissing, even mid-flow."
  - "1.8.0 (2026-08-23): Verified-broken update to the Design Doc Gate 0 pitfall (PR #9270, jleechanorg/worldarchitect.ai agentic-hosting-hygiene dispatch). The gateway sent a 21KB brief listing the four hosting-shape items but did NOT include the literal Tenets template. Worker shipped code, opened PR, first CI run failed Gate 0 — UNSTABLE mergeStateStatus, recovery took ~90s + a wasted CI cycle. Added: (a) literal Tenets design-doc template text inline in the SKILL.md pitfall, (b) new reference file `references/wa-design-doc-gate-0-brief-template-2026-08-23.md` with the verified-broken trace + post-PR-open recovery recipe + pre-flight check command, (c) inline gate-0 instruction in the `templates/bead-to-pr-dispatch-brief.md` GATES section so the next brief built from the template carries the gate instruction into the worker."
  - "1.7.0 (2026-08-20): Add `templates/bead-to-pr-dispatch-brief.md` — boilerplate brief for the canonical 'diagnosis already locked in a rev-XXX bead, dispatch the fix' pattern (verified on jleechanorg/worldarchitect.ai campaign ArYA47Fvx8HTYC8jpleO mobile-latency dispatch, 3-layer fix recipe + 3 regression tests). Bakes in: pre-set worktree (no fresh worktree creation by worker), bead-as-source-of-truth (worker reads from source repo, not worktree), hard 'do NOT merge' / 'do NOT poll for CI green' gates, explicit RETURN FORMAT for gateway verification. Pointer at top of section so future agents know the template exists."
  - "1.6.0 (2026-08-20): Add anti-pattern for treating /af as healthy when the dark-factory daemon is in backoff (verified on jleechanorg/worldarchitect.ai #9148 cluster: consecutive_failures=16 backoff=300s, last successful PR dispatch 90+ hr ago, 45 QUEUED beads with target_repo=NULL). When the daemon is broken AND the user signals inline drive (\"directly code this\", \"test it real end-to-end\", \"keep going don't stop\"), bypass the factory: drop a factory-labeled bead for later pickup, then drive inline as a one-shot via claudem on a clean worktree. Bumped trigger surface with the new user-phrase triggers."
  - '1.5.0 (2026-08-19): Add references/wa-ci-gate-quirks-2026-08-19.md covering 3 WA-specific CI gate quirks observed on PR #9098: (1) Prompt / Tool Contract Hash Validation silent version drift — one-line fix via `python3 scripts/validate_prompt_tool_contracts.py --update`; (2) multi-helper same-contract pattern (god-mode narrative contract was re-implemented in 3 different files, all needing the same fix); (3) MagicMock auto-truthy leaks when a helper starts branching on field types. Pointer in related_skills.'
  - '1.4.0 (2026-08-19): Add bucket-2 budget refinement (1242-LOC thin-slice PR + CI fix + visual proof exceeds 80 turns — split into 2 worker passes OR reserve ≥120 turns; see references/claudem-takeover-budget-2026-08-19.md). Add WA-specific Gate 0 Design Doc Grep Gates pitfall (mvp_site/*.py non-test delta >50 lines requires ## Tenets + linked .md artifact). Add "Design Doc Gate 0 must be in the worker brief, not discovered post-push" corollary.'
  - '1.2.0 (2026-08-18): Add anti-pattern for `delegate_task`/`sessions_spawn` for code-writing work — SOUL.md bans these dispatch surfaces even though they spawn Claude Code underneath. Canonical bucket-2 invocation is `bash -lic "claudem -p <task>" --max-turns N` from a clean worktree. Verified incident: thread C0BDEAJH8PK/p1787049944, planning_block old-format + mobile expand UX, multi-file CSS+JS+tests dispatch. Bumped trigger surface with delegate_task/delegate task phrases.'
  - '1.1.0 (2026-08-06): Add pre-push self-audit pitfall so workers catch polluted-worktree failures themselves (16-file / 5657-line PR from a stale-base worktree, jleechanorg/worldarchitect.ai#8794). Cross-reference tracked-append-only-git-defense for recovery recipe.'
  - '1.0.0 (2026-08-05): Initial version extracted from user-correction incident on PR jleechanorg/worldarchitect.ai#8781.'
related_skills:
  - finish-the-job
  - always-pr-never-local-edit
  - drive-pr-to-green
  - dispatch-task
  - tracked-append-only-git-defense
  - pr-conventions  # prod vs non-prod PR delta convention — required on every PR mention (2026-09-17)
  - wa-ci-gate-quirks-2026-08-19  # implicit: see references/wa-ci-gate-quirks-2026-08-19.md
  - wa-design-doc-gate-0-brief-template-2026-08-23  # verified-broken case + literal Tenets template (PR #9270)
  - wa-spa-catchall-hosting-hygiene-2026-08-23  # verified-broken Accept-header discrimination pattern (PR #9270 v1→v2)
---

# pr-dispatch-defaults

The dispatch default is INLINE for mechanical coding work. Read this before reaching for `ao spawn`, `claudem`, or any worker primitive.

## Why this skill exists

2026-08-05 incident on `jleechanorg/worldarchitect.ai#8781` ("remove AI Personalities and Options rows from campaign preview"):

1. User posted screenshot, terse one-line ask: "Lets remove AI personalities and Options".
2. Agent classified as "PR fix / new code" and reached for `ao spawn` first thing, claiming the work needed "long-task / CI review cycles".
3. Agent's reply: "Spawning agent ... will reply here when done." (no tool call done, no diff written).
4. User reply: **"just code directly yourself using claude minimax"**.
5. Agent killed the AO spawn and did the full work inline: read campaign-wizard.js, set up worktree, 8 surgical patches, 3 testing_ui updates, `node --test` passed, committed with `claude/minimax-M3:` prefix, pushed, opened PR #8781, published /es gist, started local `run_test_server.sh`, captured BEFORE/AFTER PNGs via headless Playwright, vision-verified both PNGs, posted Slack reply. All in one session, ~50 tool calls.

The lesson: when the work fits inline, dispatching is theater. The user prefers the agent finish the work over handing it off.

## The decision matrix

Before any dispatch primitive, classify the work:

| Bucket | Work shape | Action |
|---|---|---|
| **1. INLINE (default)** | Mechanical coding task: ≤30 tool calls in one session, single PR scope. Examples: remove dead code, swap text, add validation, drop unused selectors, fix imports, rename a symbol across N files, add a header to a function. | **Read → edit → `node --test` or `./run_tests.sh <subset>` → commit (with `claude/minimax-M3:` prefix) → push → `gh pr create` → respond. All in this session.** |
| **2. WORKTREE + CLAUDEM** | Multi-component feature with ≥3 files of new code, OR work that must survive session boundaries (CI babysit over multi-day, multi-coder coordination, sequential commits over hours). | The gateway session sets up the clean worktree from `origin/main` itself, then dispatches via `bash -lic 'claudem -p "<task>"' --max-turns <N>` from that worktree. **`claudem` is the bashrc shell function that wraps `claude` with `ANTHROPIC_*` env-var routing** (typically `MiniMax-M3`); `bash -lic` sources `~/.bashrc` inside the subprocess so the function is visible. The claudem call gets its own tool budget. **See "Prompt shape for bucket 2" below — user-named end-state must be at the TOP of the brief, not buried in a Deliverables block, or the worker will burn its budget on implementation polish and never reach the end-state.** Full bashrc-vs-binary mechanics in `claude-code-claudem/SKILL.md`. |
| **3. AO WORKER** | User literally typed `/af`, `/auto-factory`, `/a`, `/fullrun`, or `/f` in the current turn. | `ao spawn --claim-pr N` or `ao spawn -p <project>` per `agento` skill. Do NOT use AO outside these explicit triggers. |
| **4. INLINE (everything else)** | Ops, investigation, single-file fix, 1-2 file patch, PR-fix on existing branch, evidence capture, skill authoring. | Inline, no dispatch. |

## Anti-patterns

- ❌ **Auto-mirroring a parallel test for every prod-line addition without asking (added 2026-09-17, jleechanorg/worldarchitect.ai PR #9911, "exempt rukkagamer").** When the change is a 1-line whitelist/bypass entry that mirrors an existing canonical pattern (e.g. `exempt_emails.add("<new>")` next to `exempt_emails.add("<existing>")`), the test that already covers the existing entry proves the dispatch logic for the new entry too — a parallel `test_<new>_is_default_exempt_email` is ceremony, not evidence. Default to **prod-only diff** unless one of these is true: (a) the change introduces a NEW branch of logic not covered by the existing test, (b) the user explicitly asked for test coverage, or (c) the new test would catch a future regression the canonical pattern doesn't already cover. **Verified user correction 2026-09-17, Slack C0AH3RY3DK6/p1789662554.752099:** user asked "I think we don't need a test case?" — agent had shipped a 20-line diff (1 prod + 19 parallel test) and had to force-push to drop it, ending at prod +1/-0. The lesson: ship the minimal diff that proves the change against the existing test surface; don't double-cover what the canonical test already proves. For a 1-line addition that mirrors an existing tested pattern, the diff is `prod +N/-0, non-prod +0/-0` — post that delta explicitly in the PR body and final reply (see also `pr-conventions` skill: prod vs non-prod delta convention).

- ❌ **Spawning AO for a 7-file / +5/-255 mechanical diff** that the agent could write in 15 tool calls. (2026-08-05 incident.)
- ❌ **Defaulting to dispatch because the task "sounds complex"** — most PR fixes are multi-step but inline-able. Multi-component ≠ dispatch-bound.
- ❌ **Treating "< 25 tool call budget" as a reason to dispatch.** The budget is per-tool; the agent can have hundreds of tool calls in one session. The 25-call budget for *this* session is unrelated to the size of the diff.
- ❌ **Pre-emptive dispatch when the user said something terse** like "ship X" or "fix this" without asking about /af — that's bucket 1, INLINE.
- ❌ **Spawning AO "to be safe"** for a PR fix on an existing branch the user named explicitly — bucket 4, INLINE.
- ❌ **Dispatching a 2-file CSS+JS UI tweak to claudem when bucket 1 INLINE was correct (added 2026-08-18, Slack C0AH3RY3DK6/p1787114069, "Make the add your avatar button look nicer and circular, looks ugly now").** A new `<button>` class swap on one `app.js` empty-state branch + ~80 lines of CSS on one `avatar.css` is exactly the bucket 1 mechanical-coding shape the decision matrix lists: ≤30 tool calls, single PR scope, both files already known by heart from a single `rg -n "Add Avatar"` lookup. Reaching for `claudem -p` here was a reflex; the worker burned 4 minutes planning skill intros, never fired a single edit, and had to be killed. Total cost of dispatch ≫ total cost of inline. **Rule of thumb: if you can read the affected files and write the patches in the same session without external lookups (no LLM-for-LLM dispatch needed for the diagnosis itself), it is INLINE — `claudem` adds latency + a fresh context for no benefit.** The "Multi-component ≠ dispatch-bound" lesson from #8781 says the same thing from the other direction. When in doubt, count: how many files is the user-visible diff? **≥3 → dispatch candidate; ≤3 with the diagnosis already done inline → ship INLINE.**

  **Kill criterion for a stuck claudem worker — DO NOT wait it out.** If the tmux pane shows an empty prompt input (`❯` with no text) AND no fresh tool-call text in the last ~90 seconds AND `Worked for Ns` / `Thought for Ns` has not advanced, the worker is in a skill-introspection loop and will not fire edits. Kill it with `tmux send-keys C-c` + `/exit` Enter, then `tmux kill-session -t <name>`, and either retry inline or write a tighter brief with the user-named end-state at the TOP (see "Prompt shape for bucket 2" below). Verified on the avatar-button dispatch: same pane content observed for 4+ minutes before kill. Companion rule (skill_view sanity check before invoking worker-bundled skills like `ponytail`): if the worker lists loaded skills that are NOT in the gateway session's loaded-skill set, it is in a different skill namespace and may behave unexpectedly — abort and re-brief.
- ❌ **Drafting a bucket-2 worker brief without first reading the current `origin/main` code (added 2026-08-19, jleechanorg/worldarchitect.ai PR #9143 dispatch).** Two real failure modes from this session: (a) PR1 brief assumed the cooldown-strip exemption for `source: "world_tick"` was outstanding — but it had already shipped on `origin/main` in commit `3a6a4374b3` ("Canonicalize cooldown living-world strip fields (#6839)") with the test at `mvp_site/tests/test_world_tick_event_cooldown_exemption.py`. The brief was a no-op; the dispatch budget was wasted. (b) PR2 brief assumed `_annotate_entry` was missing `turn_generated` backfill — actually it already does the backfill at `mvp_site/world_logic.py:582-588` AND the retire function at `firestore_service.py:2827-2878` handles both `turn_generated` (v1) and `created_at` (v2). The worker produced the right files (scoper/operations/tests) but the dispatch budget was wasted on a redundant backfill script in the brief.

  **Mandatory pre-dispatch brief validation (run all four before invoking claudem):**
  1. `git -C <repo> fetch origin` + `git -C <repo> log --oneline origin/main -20` — see what's already on main.
  2. `rg "<key-claim>" -n` against the live code at `origin/main` HEAD — every "the bug is X" / "we need to add Y" / "the function Z is missing" claim must be ground-truthed. If the rg shows the code is already there, the brief is wrong.
  3. `gh api repos/<owner>/<repo>/issues/<N>` (or search "fixes #N" / "closes #N") — confirm the issue is actually open and the claimed scope matches.
  4. If the brief claims "add exemption for X" and `rg "exemption for X"` returns a hit on `origin/main`, **STOP**, drop the brief, and pivot to inline (the work is already shipped). Verified: a 5-minute inline audit would have saved the 25-turn claudem dispatch and the worktree cleanup.

- ❌ **Burying the user-named end-state in a flat numbered "Deliverables" list at the bottom of the worker brief (added 2026-08-05, jleechanorg/worldarchitect.ai#8794, campaign-sharing redo).** When the user explicitly names an end-state artifact — *"iterate until /browser test shows user 1 makes campaign, creates a shared version, edits it, user2 plays it"*, *"until CI green + Skeptic PASS"*, *"until the captioned video lands"* — and you dispatch a worker, do NOT list that end-state as item #N inside a 5-item Deliverables block. Workers treat flat numbered lists as equal-weight items. If the end-state is buried at #3 of 5, the worker will over-invest in #1-#2 (implementation polish) and SIGTERM before reaching #3. Verified: claudem worker SIGTERM at 154 turns / $6.16 / 34 min on PR #8794 shipped 1427 lines + 13/13 unit tests but never opened the PR, never ran the `/browser` test, never produced `/es` evidence. Use the prompt shape in the next section instead. Companion reference: `references/worker-end-state-prompt-shape-2026-08-05.md`.
- ❌ **Post-PR-open dispatch drift — `ao spawn --claim-pr N` on a PR this session just opened inline (added 2026-08-05, jleechanorg/worldarchitect.ai#8781).** If the inline gateway session did the coding AND opened the PR via `gh pr create`, then on its own turn-38 message "PR #N is open. Let me confirm the state and dispatch AO to drive to green," the agent MUST stay INLINE. "Drive to green" / "drive to mergeable" / "babysit my PR" are NOT dispatch triggers when the originating inline session owns the PR. Apply this rule BEFORE the dispatch-table lookup: any agent message that names a PR number AND says "dispatch" AND the inline session's recent history includes `gh pr create <N>` is a self-violation — kill the dispatch idea, post the drive-to-green handoff inline (poll CI via REST, fix Evidence Gate metadata.json gap inline, push no-op retrigger commit, set up self-cancelling one-time babysit cron for runner-saturated cases). Verified user correction 2026-08-05, Slack C0AH3RY3DK6/p1785953173.319919: "I thought we stopped AO dispatch being the default from hermes?" — user stopped the AO spawn mid-flight and asked for inline coding, exactly because the agent had just been doing inline. Full recipe + worked example: `references/post-pr-open-drive-to-green-anti-pattern-2026-08-05.md`.

- ❌ **Treating "I'll wait for CI to come back green, then auto-merge" as a permission to skip the literal `MERGE APPROVED` gate in `worldarchitect.ai/AGENTS.md` non-negotiables (confirmed 2026-08-06, jleechanorg/worldarchitect.ai#8781 same thread).** The user saying things like "merge approd" or "/green and merge" in a previous turn is a PLAN STATEMENT, not a literal gate trigger. Per `worldarchitect.ai/AGENTS.md` line 11 ("Do not merge without explicit human authorization. For WorldArchitect.AI, the current live message must contain `MERGE APPROVED`"), the only legitimate auto-merge authority is the literal string `MERGE APPROVED` in the same live message as the merge action. Same thread, same minute, or it doesn't count. Don't run `gh pr merge --squash` because the user said "/green" earlier or because CI looks fine or because the org flow has been "skeptical auto-merge" in another repo — this repo has no `skeptic-cron.yml` workflow and the literal gate is the gate. Poll the post-PR-open state inline, fix what you can fix inline, set up a self-cancelling babysit cron for CI queue, and wait for the live `MERGE APPROVED`.

- ❌ **Worker pushes the branch but skips `gh pr create` — gateway must verify the PR exists before declaring dispatch a success (added 2026-08-19, jleechanorg/worldarchitect.ai PR #9151 / worker session `proc_3069660ace52`).** Same shape as the local-push-without-PR pitfall above, but at the worker-dispatch boundary. Verified: the worker did `git push origin feat/divine-truth-26` for two separate commits (round 1 + round 2 force-push) but never ran `gh pr create`. The gateway only noticed when reporting back to the user. The end-state-shape rule above ("end-state at the TOP of the brief") is necessary but not sufficient — the gateway must ALSO **verify the PR exists** with `gh api repos/<owner>/<repo>/pulls?head=<user>:<branch>` (REST, not GraphQL — GraphQL is rate-limited during heavy dispatch windows) before posting any "PR open" claim. If the PR is missing, gateway opens it inline from the JSON body: `gh api -X POST repos/<owner>/<repo>/pulls --input -` with a body that includes `head`, `base`, `title`, `body` fields. Verified recovery on PR #9151. **Add this line to the worker brief:** "After `git push`, you MUST run `gh pr create --base main --head <branch> --title <title> --body-file <body.md>`. If `gh pr create` fails with a GraphQL rate limit, retry with `gh api -X POST repos/<owner>/<repo>/pulls --input -` against `_tmp_body.json` containing the same fields. Report the PR URL in your final reply."

- ❌ **Writing the brief to `/tmp/<name>.md` and dispatching without copying to the worktree (added 2026-08-19, jleechanorg/worldarchitect.ai PR #9151 / worker session `proc_3069660ace52`).** claudem `--print` reads the prompt via `cat <path>` inside the bash subprocess; if `/tmp/` is cleaned before the worker process actually reads the file (race conditions, period cleanup, or `tmpreaper`), the worker fails with `cat: /tmp/<name>.md: No such file or directory` followed by `Error: Input must be provided either through stdin or as a prompt argument when using --print`. The recovery is to re-dispatch with the brief at a **stable path** — the worktree itself is the canonical choice. Verified pattern: `cp /tmp/branch-brief.md <worktree>/branch-brief.md && bash -lic 'claudem -p "$(cat <worktree>/branch-brief.md)" --max-turns <N> --output-format text'`. The worktree path stays valid for the entire worker wall-clock (typically ≤60 min). **Rule of thumb:** for any brief passed via `cat <path>` to a claudem worker, the path must either be inside the worktree (preferred) or `~`-anchored (acceptable but slower). `/tmp/<name>.md` is **not** acceptable.

- ❌ **Assuming the skeptic-cron auto-merge exists for every jleechanorg repo (added 2026-08-06, jleechanorg/worldarchitect.ai#8781).** SOUL.md and `drive-pr-to-green` SKILL.md describe a skeptic-cron auto-merge path, but **jleechanorg/worldarchitect.ai has NO `.github/workflows/skeptic-cron.yml` and NO "skeptic" workflow of any name** (verified via `gh workflow list` + `gh api repos/.../contents/.github/workflows`). The 2-gate Green Gate definition per `.github/workflows/green-gate.yml` comments is: (1) CI green + (2) no merge conflicts. After both pass, the only merge path is literal `MERGE APPROVED` from the user → `gh pr merge`. Other jleechanorg repos (e.g. jleechanorg/jleechanbrain) DO have skeptic-cron. Always verify the merge path with `gh workflow list --repo <owner>/<repo> --json name,state` BEFORE drafting a drive-to-green plan that depends on auto-merge.

- ❌ **Treating the dark factory as healthy when it actually isn't — bypass drive inline (added 2026-08-20, jleechanorg/worldarchitect.ai #9148 cluster).** Verified recipe: when the dark-factory daemon is in backoff (status string contains `consecutive_failures=N, backoff=Ns`), or `bead_overlay` shows ≥10 QUEUED beads with `target_repo IS NULL`, or no PR dispatch has landed in ≥24 hours, treat `/af` as broken and drive inline as a one-shot. The recipe is: (1) push the canonical `factory` label onto the issue-side artifact so the daemon can pick up later when it recovers; (2) drop a factory-labeled bead into `dark-factory/.beads/` with the canonical brief (`target_repo:`, `existing_branch:`, `head_sha:`, body ≤ 4096 chars); (3) drive inline — set up the clean worktree from `origin/main` yourself, write the code, run the e2e smoke, commit, push, open the PR, post status. **The user signal that triggers this branch:** *"directly code this"*, *"test it real end-to-end"*, *"keep going don't stop"*, *"stop handing off to the factory"*. Verified: agent wasted ~30 min monitoring the daemon in backoff (last successful dispatch was 2026-08-18T00:32:02Z, 90+ hours ago) when the inline drive took ~15 min and produced the PR. Per dark-factory AGENTS.md: *"This Mac is an operator client: do not load or start a Dark Factory LaunchAgent, a local daemon, or local AO workers from factory intake on macOS. Always use SSH to Linux for telemetry… and operational control."* — so the inline drive uses `claudem -p` on a clean worktree from the Mac, not from jeff-ubuntu. The factory gap (`target_repo=NULL` parse bug, daemon's `consecutive_failures` climbing, etc.) is a separate bead for the factory to self-fix.

- ❌ **Dispatching coding work via `delegate_task` / `sessions_spawn` (added 2026-08-18, slack thread C0BDEAJH8PK/p1787049944).** SOUL.md `## COMMIT: claude-code-claudem-over-direct-api` and `## COMMIT: scope-pivot-to-claudem` explicitly ban `delegate_task` (and the older `sessions_spawn` name) for code-writing work: *"MUST NOT be used for any task that involves: writing or editing code/files, creating or fixing a PR, running tests, any multi-step implementation work."* The correct bucket-2 invocation is **`bash -lic 'claudem -p "<task>"' --max-turns <N>` from a clean worktree** — the `bash -lic` sources `~/.bashrc` so the `claudem` shell function (with the `ANTHROPIC_*` env-var routing) is visible inside the subprocess. Verified on PR #8979, PR #8839, and the `claude-code-claudem` skill's contract tests. The fact that `delegate_task` happens to spawn a Claude Code process underneath is irrelevant — the SOUL.md rule is about the dispatch surface, not the underlying model. Apply the rule BEFORE `git worktree add`: if the work is bucket 2, `delegate_task` is always wrong even when it would technically work.

  Worker prompt shape for bucket 2 is in the next section ("Prompt shape for bucket 2"). The same shape works for both `claudem -p` and tmux interactive mode. If you catch yourself reaching for `delegate_task` for code work, the move is: stop, set up the clean worktree from `origin/main` yourself (`git worktree add … origin/main -b fix/...`), then dispatch via `bash -lic 'claudem -p …'`. The gateway session stays responsible for the dispatch decision + worktree setup; the worker is responsible only for the implementation + verification + push + `gh pr create`.

  Why this rule exists even though `delegate_task` "worked" in some prior sessions: each `delegate_task` call spawns a NEW hermes session with its own memory context, its own skill loader, and its own auto-policy for `max-turns`/model fallback. It does NOT inherit the gateway session's `claudem` wrapper, SOUL.md `## COMMIT:` blocks, or the user's `~/.smartclaw/skills/` curator-managed skills by default. A `delegate_task` worker is more likely to invent its own conventions than a `claudem` worker running in the same hermes shell that knows the dispatch rules.

- ❌ **Dispatching a worker without telling it to audit its own diff before pushing (added 2026-08-06, jleechanorg/worldarchitect.ai#8794).** Workers that fall into stale-base worktrees (worktree branched from `origin/main` SHA from the moment of dispatch, not from current `origin/main`) routinely commit `.beads/issues.jsonl` plus scope-drifted unrelated files into the same PR. The gateway session then opens the polluted PR at full cost. Add this verification step to the worker brief, AFTER the implementation is done but BEFORE `git push`:

  ```text
  ## Pre-push self-audit (MUST run; abort if any check fails)

  - `git diff --shortstat origin/main..HEAD` returns < 1500 lines for a thin-slice feature PR. If > 1500, you have scope drift; STOP and re-derive the scope from the PR title.
  - `git diff origin/main..HEAD --name-only | grep -E '\.(jsonl|log|po)$'` is empty. If you see `.beads/issues.jsonl`, you have JSONL pollution (likely from auto `git add -A`); unstage it with `git restore --staged <file>` and amend the commit. AGENTS.md "Do not commit `.beads/issues.jsonl` from feature branches" — the canonicalizer on `origin/main` owns it.
  - `git log --oneline origin/main..HEAD --grep='^Merge remote-tracking branch'` is empty. If non-empty, your worktree forked from a stale base; cherry-pick or path-limit-checkout onto a clean branch from current `origin/main`.
  ```

  Verified pollution recovery: see `tracked-append-only-git-defense/references/polluted-worktree-recovery-2026-08-06.md`.

## Bucket-2 budget: 1242 LOC thin-slice exceeds 80 turns (added 2026-08-19, jleechanorg/worldarchitect.ai#9112)

**Verified incident**: Slack `C0AH3RY3DK6/p1787119923.214439` (avatar Grok generation). Gateway dispatched an 80-turn claudem worker for a 7-file / +1242 LOC thin-slice PR (new `mvp_site/avatar_image_gen.py` 348 LOC + `mvp_site/tests/test_avatar_grok_gen.py` 339 LOC + 4 modified files). Worker burned all 80 turns on implementation polish and never reached `git push` / `gh pr create`. A 30-turn resume pass then committed + pushed + opened the PR but still couldn't run tests, capture visual proof, or fix CI. Gateway session finished all of those inline (~15 min more).

**Rule of thumb for sizing `--max-turns` on bucket-2 dispatches**:

| Diff scope | Reserve budget |
|---|---|
| ≤400 LOC OR ≤3 files | 60 turns |
| 400–1000 LOC OR 4–6 files, single domain | 100 turns |
| 1000–2000 LOC OR 7+ files, multi-domain (backend + frontend + tests) | **150 turns**, OR split into two passes |
| ≥2000 LOC OR cross-cutting refactor | Split into 2 worker passes by default |

**When the diff is multi-domain**, prefer splitting into two worker passes from the start instead of one big pass:

1. **Pass A (impl, ~80–100 turns)**: implementation + unit tests. End-state: commits exist on the worktree branch, working tree clean, `--max-turns` budget for commit but NOT for push.
2. **Pass B (resume, ~30–50 turns)**: rebase onto current `origin/main`, run pre-push self-audit, push, open PR, run tests, capture visual proof, fix any CI failures, update PR body.

The gateway session sits between the two passes: it audits the worker's diff (cheap; ≤3 turns), then dispatches Pass B. **Never let a single worker own impl + push + CI-fix + visual-proof** — those are independently budgetable and any one can blow the budget.

**When NOT to split** (use the budget table above instead): single-domain diffs (all frontend OR all backend OR all tests) where the impl worker can complete `git push` AND `gh pr create` in the same budget.

The reference `references/claudem-takeover-budget-2026-08-19.md` has the full timeline + per-turn cost breakdown for the avatar-grok PR.

## WA-specific pitfall: Design Doc Grep Gates Gate 0 (added 2026-08-19, jleechanorg/worldarchitect.ai#9112; verified broken 2026-08-23, PR #9270)

`jleechanorg/worldarchitect.ai` has a workflow (`Design Doc Gate`, file `.github/workflows/design-doc-grep-gates.yml`) that FAILs any PR whose non-test `mvp_site/*.py` delta exceeds **50 lines** unless the PR description contains:

1. A `## Tenets` OR `## Design Decision` section, AND
2. Inside that section, a linked `rev-xxxx` bead ID OR a `.md` file path (regex: `(rev-[a-z0-9]+|(~?/)?([[:alnum:]_.-]+/)*[[:alnum:]_.-]+\.md)`).

**Verified broken 2026-08-23, PR #9270** (`feat/agentic-hosting-hygiene`): the brief I sent the worker listed the four hosting-shape items but did NOT include the literal `## Tenets` template text. The worker shipped the code, opened the PR, and the first CI run failed Gate 0 because the body had no Tenets section. Recovery: I had to (a) write a `docs/agentic-hosting-design-decision.md` file on the branch, (b) commit it as a follow-up, (c) `gh pr edit --body` to inject the `## Tenets` section, (d) `gh run rerun` the failed job, (e) wait ~30s. **Total cost of forgetting the Tenets template in the brief: one wasted code push + one wasted CI cycle + one wasted worker turn ≈ 8-12 min wall clock.** The fix in this version: include the literal Tenets template below in EVERY bucket-2 brief that touches `mvp_site/**` non-test files.

Verified failure mode on PR #9112: 480 non-test `mvp_site/*.py` delta lines + PR body without the section → `Gate 0: Design Decision Check` failed at step 5, exit 1, blocking the entire `Design Doc Grep Gates` job. Green Gate was PASS but this gate FAILed everything downstream.

**Worker brief MUST include this gate from the start when the diff is bucket-2 sized**. Add a literal instruction in the "Pre-push self-audit" block of the worker brief. The literal template (verified working on PR #9270 after I retrofitted it):

```text
## WA Design Doc Gate 0 — REQUIRED if mvp_site/*.py non-test delta > 50 lines

Compute your own non-test mvp_site/*.py delta BEFORE pushing:

  DELTA_LINES=$(gh api repos/jleechanorg/worldarchitect.ai/pulls/<N>/files --paginate \
    | jq -s '[.[] | .[]? | select(.filename | test("^(?!.*(test|_test|tests/|spec/)).*mvp_site/.*\\.py$")) | .additions + .deletions] | add // 0')

If DELTA_LINES > 50, you MUST do all three of these BEFORE `gh pr create`:

1. **Write the design doc as a file on the branch** at `docs/design/<feature-slug>.md` (or `docs/<feature-slug>.md`). Commit it on the same branch as the code change. Use the template below as the body — substitute your own tenets, linked artifacts, and verification.

2. **Inject a `## Tenets` section into the PR body** that links the design doc. The section MUST appear as a top-level `## Tenets` heading (or `## Design Decision`). Inside that section, include a line of the form:

   ```markdown
   Linked artifact: [`docs/<your-doc>.md`](https://github.com/jleechanorg/worldarchitect.ai/blob/<branch>/docs/<your-doc>.md)
   ```

   The regex the gate matches is `(rev-[a-z0-9]+|(~?/)?([[:alnum:]_.-]+/)*[[:alnum:]_.-]+\.md)` — relative path to the `.md` file works fine because the regex matches the literal text.

3. **Use the design doc template body below** (copy verbatim, fill in the bracketed fields, commit, then reference):

   ```markdown
   # Design Decision — <feature name>

   ## Context
   <2-3 sentences on the problem>

   ## Tenets (decision rules)
   1. <numbered tenet>
   2. <numbered tenet>
   3. ...

   ## Linked artifacts
   - Issue / motivation thread: <Slack link or GitHub issue>
   - Scorecard / external source: <URL if applicable>
   - Repo AGENTS.md: `AGENTS.md`
   - Repo CLAUDE.md: `CLAUDE.md`

   ## Out of scope (deferred)
   - <bullet>
   - <bullet>

   ## Verification
   - `<test path>`: <what it asserts>
   - Live curl / e2e evidence: <captured in final reply>

   ## Risk
   <risk assessment + mitigation>
   ```

**If the worker does NOT include this in the brief and the gate fails post-push**, the gateway session can recover inline using `pr-body-grep-gate-fix` skill (REST PATCH on `issues/<N>` body + `actions/runs/<run_id>/rerun-failed-jobs`). That recovery is fast (~30s) but the worker turn + the wasted CI cycle + the user-visible "ready?" flag flip → "blocked on Gate 0" flag flip is the cost. Including the template upfront is cheaper.

Other jleechanorg repos (`jleechanorg/jleechanbrain`, `jleechanorg/agent-orchestrator`, etc.) may have analogous gates or none at all — `gh workflow list --repo <owner>/<repo> --json name,path | jq -r '.[] | select(.name | test("[Dd]esign|[Dd]oc|[Tt]enet"))'` first.

## WA hosting-hygiene fix MUST preserve SPA routes — Accept-header discrimination pattern (added 2026-08-23, jleechanorg/worldarchitect.ai PR #9270 v1→v2)

**Verified-broken case**: the first version of `feat/agentic-hosting-hygiene` (PR #9270 v1) made `serve_frontend()` return **HTTP 404 with text/markdown body for every non-`game/` path**. The brief correctly named the audit's verification ("`curl /some-path-that-does-not-exist` must print 404"), so the agent thought the change was safe. **Cursor Bugbot flagged it as Medium Risk**: *"the SPA catch-all now 404s unknown paths, breaking any client-only routes that are not `/` or `/game/<id>`."* The agent dismissed the warning ("verifiable via test client") and pushed. CI then failed:
- `Light/Fantasy Compliance Gate` — `passed: false`, detail `"none matched: ['#new-campaign-view.active-view', '#new-campaign-form', '#new-campaign-view.active-view #campaign-wizard']"` (Playwright could not find the wizard selectors because the SPA never loaded).
- `Wizard Mobile Scroll/CSS Regression` — infra flake (low_disk_space_before_playwright_bootstrap on the self-hosted runner), but only surfaced because the test queue was already running long.

**Two failure-mode lessons stacked** (both belong in the brief BEFORE the worker dispatches):

1. **The hosting-shape fix must preserve SPA routes**, not just satisfy the audit curl. The audit's verification curl is `curl /some-path-that-does-not-exist` (default `Accept: */*`, no `text/html`); that is NOT how a browser navigates (`Accept: text/html,application/xhtml+xml,...`). Use **Accept-header discrimination**: 404 markdown ONLY when the request's Accept header lacks `text/html`. Browsers always send `text/html`, so SPA navigation is preserved; agents/curl/crawlers send `Accept: */*` or `Accept: text/markdown`, so they get a real 404.

2. **Whitelist known SPA-route prefixes** as a belt-and-suspenders measure. Even with Accept discrimination, an explicit allowlist (`game/`, `campaign/`, `shared/`, `auth/`, `play/`, `new-campaign`, `settings`, `dashboard`) means these always serve index.html regardless of Accept — so a future Accept-header change cannot break them. The audit's "unknown path 404" semantics are preserved for everything OUTSIDE the whitelist.

**Correct fix shape (the second commit on PR #9270, `3903625d3c`)**:

```python
# mvp_site/main.py — serve_frontend catch-all branch
_SPA_ROUTE_PREFIXES = (
    "game/", "campaign/", "shared/", "auth/", "play/",
    "new-campaign", "settings", "dashboard",
)
is_spa_route = any(path == p.rstrip("/") or path.startswith(p) for p in _SPA_ROUTE_PREFIXES)
accept_header = (request.headers.get("Accept") or "").lower()
wants_html = "text/html" in accept_header
if not is_spa_route and not wants_html:
    # Agent probe — return 404 with markdown body.
    return Response(_NOT_FOUND_MARKDOWN_BODY.format(origin=...), status=404, mimetype="text/markdown")
if is_spa_route:
    # Browser or known SPA route — always serve index.html.
    return send_from_directory(frontend_folder, "index.html")
```

**Verification matrix the brief MUST mandate** (the worker should run these locally AND the brief should require evidence in the final reply):

```
GET /                       (browser Accept)       → 200 text/html
GET /                       (curl Accept: */*)     → 200 text/html
GET /robots.txt             (any)                  → 200 text/plain
GET /sitemap.xml            (any)                  → 200 application/xml
GET /llms.txt               (any)                  → 200 text/plain
GET /about, /contact, /privacy (any)               → 200 text/html
GET /nonexistent-zzz        (no Accept header)     → 404 text/markdown  ← audit spec
GET /nonexistent-zzz        (curl: */*)            → 404 text/markdown  ← audit spec
GET /nonexistent-zzz        (curl: text/markdown)  → 404 text/markdown
GET /nonexistent-zzz        (browser: text/html,..)→ 200 text/html      ← browser fallback acceptable
GET /new-campaign           (browser)              → 200 text/html      ← SPA preserved
GET /settings               (browser)              → 200 text/html      ← SPA preserved
GET /game/<id>              (browser)              → 200 text/html      ← SPA preserved
```

**Worker-brief instruction template for any hosting-hygiene PR** (add this in the GATES section of every bucket-2 brief that touches `mvp_site/main.py` `serve_frontend` or any catch-all route handler):

```text
## Hosting-hygiene gate — preserve SPA routes

Your fix must:
1. Return HTTP 404 with a markdown body for agent probes (Accept: */* or Accept: text/markdown).
2. Preserve SPA fallback for browser navigation (Accept: text/html,...).
3. Whitelist known SPA-route prefixes (game/, campaign/, shared/, auth/, play/, new-campaign, settings, dashboard).

Verification before commit:
- Run the curl matrix above against your local test client.
- For each row, paste the actual output (status + content-type) in your final reply.
- If any browser row returns non-200, the fix is wrong — re-derive the Accept logic before pushing.
```

**Corollary**: when a Bugbot reviewer (or your own judgment) flags a hosting-shape change as **medium risk for breaking client-side routes**, do NOT dismiss the warning until you have done at least one Playwright smoke through a known client-side route (`/new-campaign`, `/settings`, `/game/<id>`) with a real `Accept: text/html` header. The audit-spec curl is necessary but not sufficient — the spec is *one curl shape*, not "every browser navigation". The same rule applies to any `Accept`-based content negotiation fix on the app origin.

**Companion**: `qa-test-failure-dismissal-anti-pattern` SKILL.md — when a CI gate fails and you think "must be pre-existing on origin/main," do the same-SHA repro before saying so. On PR #9270, the Light/Fantasy Gate failed with selectors not matching because the SPA was unreachable — that is a real regression, NOT a pre-existing flake. The skill's same-name + same-assertion + same-file + same-SHA checks would have caught it before the dismiss.

## Prompt shape for bucket 2 (worker-end-state at the TOP, not the bottom)

When the user's named end-state is inside the worker's iteration budget AND fits bucket 2, structure the worker brief with the end-state at the **top** as a numbered stop-gate list:

```
## End-state (deliver in this order; if you run out of turns, STOP after the last completed step and report — do NOT keep polishing earlier steps)

1. Push the branch (`git push -u origin feat/...`).
2. Open the PR (`gh pr create --draft ...`).
3. Capture the user-named artifact (/browser test, video, screenshot, /es gist).
4. (Optional polish) Tests, docstrings, refactor — SKIP if running short on turns.

If step 1 is not done when you exit, the entire dispatch has failed.
```

When the end-state is **outside** the worker's budget (claudem verified ceiling: ~150 turns / ~$6 / ~35 min before SIGTERM is plausible), split into two commits and reserve dispatcher capacity for the end-state proof:

1. Worker's commit: implementation + unit tests (already in `mvp_site/<feature>.py` + `mvp_site/tests/test_<feature>.py`).
2. Dispatcher's commit in the same worktree: `/browser` test capture, `/es` gist upload, PR body, `gh pr create`. The dispatcher (gateway session) is in scope to finish the end-state inline — Bash + git + gh + Slack + browser_navigate is enough for almost every code-completion task.

**Do NOT** list the end-state inside a flat numbered "Deliverables" block at the bottom of the brief. That was the failure mode on PR #8794.

## Bead-to-PR dispatch brief template (added 2026-08-20)

When the diagnosis is already locked in a `rev-XXX` bead and the work is bucket-2, copy `templates/bead-to-pr-dispatch-brief.md` to `<worktree>/branch-brief.md`, fill in the bead ID + root cause + evidence + fix layers, then dispatch via:

```bash
bash -lic 'claudem -p "$(cat <worktree>/branch-brief.md)" --max-turns <N> --output-format text'
```

The template bakes in:

- **Pre-set worktree** — gateway creates the worktree from `origin/main`, hands the path to the worker. Worker must NOT create a new worktree (avoids stale-base pollution).
- **Bead-as-source-of-truth** — the bead body is the recipe. Worker reads with `br show <rev-XXX>` from the SOURCE repo; the worktree's `.beads/` is gitignored. The brief restates the key facts inline so the worker doesn't need a second hop.
- **Hard "do NOT merge" / "do NOT poll for CI green" gates** — matches the worldarchitect.ai `MERGE APPROVED` rule and the dispatcher trap `claudem + "wait for CI green" = 20+ min idle`.
- **Explicit RETURN FORMAT** — PR URL + HEAD + bundle SHA + diff (+X/-Y) so the gateway can verify the dispatch without re-reading the worktree.
- **Layered fix recipe** — Layer 1 is mandatory, Layers 2+3 are hardening. Worker ships all of them in one PR.

**When this template fits:**
- The bead body already contains the root cause, evidence, and fix layers.
- The dispatch is bucket-2 (multi-component, requires worktree, requires PR).
- The user has approved "ok how to fix? let's make a PR" type wording.
- You do NOT have live read/write access to the bead store from the worktree.

**When NOT to use this template:**
- The diagnosis is still in flight (use a research brief, not a fix brief).
- The work is bucket-1 (≤30 tool calls, single PR scope). Do it inline per the decision matrix above.
- `/af`, `/auto-factory`, `/claw`, or any explicit AO trigger — use `ao spawn` per `agento` skill.

**Verified session:** jleechanorg/worldarchitect.ai campaign `ArYA47Fvx8HTYC8jpleO` mobile-latency dispatch (2026-08-20). Dispatch used this template, worktree at `${HOME}/wt-lag-fix-inventory-dedupe`, branch `feat/lag-fix-inventory-dedupe`, brief at `/tmp/lag-fix-brief.md` (CLI boundary: the `/tmp/` race pitfall above applies — future dispatches should copy to the worktree before invoking).

## Inline execution checklist (bucket 1)

Listen for these triggers in the user's message:

- Literal `/af`, `/auto-factory`, `/a`, `/fullrun`, `/f`, `/finish` (some of these map to specific skills; see the resolver)
- "I don't want to wait", "do it in the background"
- "kick off a worker"
- "make it autonomous"
- "run this in AO"
- "do it via claude-code-claudem"

If NONE of these are present, default to INLINE.

## Inline execution checklist (bucket 1)

When the matrix says INLINE, do all of these in this session, no dispatch:

1. **Read the affected files.** `search_files` for the IDs/selectors/symbols you'll touch.
2. **Surgical edits.** Use `patch` with unique anchor strings. Re-read the file to confirm before/after when the patch could overlap.
3. **Local test gate.** `node --test <file>`, `python -c "import ast; ast.parse(open('file.py').read())"`, or run the relevant `./run_tests.sh <subset>`. Mechanical edits to JS need `node --check <file>` at minimum.
4. **Commit prefix.** `<cli>/<model-id>:` per env-preferences.mdc. For this session: `claude/minimax-M3:`. On retag sessions, include `Originally <SHORT-SHA>: …` in the body.
5. **Push to a clean branch from origin/main.** `git worktree add -B <branch> <path> origin/main`. Never start from a non-main branch (pollution risk; see SOUL.md `pr-clean-branch-from-main-no-history-bloat`).
6. **Open PR.** `gh pr create --base main --head <branch> --title "..." --body "..."`. Embed `/es` gist URL in the body if the change touches `mvp_site/**` non-test files.
7. **Capture visual proof** if the change is user-visible (`mvp_site/frontend_v1/**`, CSS, layout, text copy). Load `wa-visual-proof-playwright` skill. BEFORE/AFTER PNGs are mandatory for `/es` evidence.
8. **One-time status cron.** `hermes cron create "20m" --deliver "slack:<channel>:<thread>" --repeat 1` — fires once to follow up on PR merge. (Don't use `--every`; that's recurring.)
9. **Slack reply** on the originating thread with: PR URL, end-state declaration, proof artifact (BEFORE/AFTER if applicable), judgment calls made mid-stream.

## Worked example

User: *"Lets remove AI Personalities and Options from https://mvp-site-app-s1-i6xf2p72ka-uc.a.run.app/new-campaign"* + screenshot.

What the agent did (bucket 1, INLINE):

- Read campaign-wizard.js, identified 2 dead HTML rows (lines 882–911), 4 dead helper methods (2319–2421), 5 dead `if (field === 'personalities' || 'options')` branches, and 3 test files that used `#preview-options` selectors.
- `git worktree add -B fix/campaign-preview-remove-personalities-options wt-campaign-cleanup origin/main`.
- 8 surgical `patch` calls on campaign-wizard.js (HTML rows, fieldsToLock, updatePreview, updatePreviewFromForm, populateEditCheckboxes, syncCheckboxesToForm, storeCheckboxSnapshot, restoreCheckboxSnapshot, populateFromOriginalForm).
- 3 surgical patches on the test files to drop `options_preview` / `options_text` reads.
- `node --check campaign-wizard.js` (no syntax errors); `node --test campaign_wizard_dragon_knight_canonical.test.js` (1 pass).
- `git -c user.name=${GITHUB_USER} commit -m "claude/minimax-M3: fix(frontend): remove AI Personalities and Options rows..."`.
- `git push -u origin fix/campaign-preview-remove-personalities-options`.
- `gh pr create --base main --head ...` → [#8781](https://github.com/jleechanorg/worldarchitect.ai/pull/8781).
- `gh gist create -d "PR #8781 evidence..." -p /tmp/es-bundle/EVIDENCE.md /tmp/es-bundle/before.png` → https://gist.github.com/${GITHUB_USER}/1fa308b8016e786ce665a7882f4b62a4.
- Started `./run_test_server.sh start` on port 8081, swapped `git show origin/main:` for BEFORE, captured BEFORE PNG via Playwright + DOM count backup, restored from saved bytes for AFTER, captured AFTER PNG, vision-verified both.
- `hermes cron create "20m" --deliver "slack:C0AH3RY3DK6:1785953173.319919" --repeat 1` for follow-up status.
- Posted Slack reply on the originating thread.

Total: ~50 tool calls. No AO, no claudem. End-state: PR open with green CI awaiting user merge.