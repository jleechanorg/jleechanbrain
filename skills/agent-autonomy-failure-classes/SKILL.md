---
name: agent-autonomy-failure-classes
version: 0.2.0
description: "Catalog of agent autonomy failures with SOUL.md fixes."
tags: [meta, harness, autonomy, mast, etclovg, taxonomy]
category: workflow
trigger_phrases:
  - "autonomy violation taxonomy"
  - "agent behavior failure class"
  - "MAST failure mode"
  - "ETCLOVG layer"
  - "what's the failure class for X"
  - "draft a SOUL.md COMMIT for this violation"
---

# Agent Autonomy Failure Classes (catalog)

Class-level catalog of agent behavior failures, indexed by MAST root category (FC1 System Design, FC2 Inter-Agent Misalignment, FC3 Task Verification & Termination) and ETCLOVG layer (Environment, Tool, Context, Lifecycle, Orchestration, Verification, Governance). Each class is paired with a SOUL.md `## COMMIT:` block that prevents it.

**Scope guardrail:** This skill is the CLASS CATALOG. For incident diagnosis (Phase 0 classify → Phase 1 OISE → Phase 2 fix), load `harness-postmortem`. For end-to-end execution (run a task to verifiable conclusion), load `finish-the-job`. This catalog exists so the next session doesn't re-derive the failure class from scratch.

## Why a class catalog (not a procedural skill)

The `harness-postmortem` skill diagnoses incidents one at a time. But the SAME failure class recurs across sessions (e.g. "agent hands the user a menu instead of executing" fired on 2026-07-02 exportcommands, 2026-08-13 superpowers-6.3 install, and likely 6 more times unrecorded). Rather than re-derive the class definition each time, this catalog is the curated index. New classes get added here as they are observed; patterns that correlate (same trigger surface, same user correction vector) get cross-referenced.

## Class index

### `pre-execution-option-bailout` (verification-layer, FC3)

**Trigger surface:** Agent reaches "I can execute this" then posts a 2+ option menu instead of executing. User has already authorized execution in the same message (imperative verb "do X", "run Y", "test Z", or corrective "stop bailing and run X", "why would you stop").

**Counter-example (canonical):** 2026-08-13 Slack `${SLACK_CHANNEL_ID}/p1786580624` — agent listed 3 options for reading a LinkedIn post when the user had already provided two executable paths (`browserclaw` with cookies, or run `/harness`). User replied: *"Why would you stop when 2) is a valid option? Run /harness how can we make you more proactive"*. The publishable post was retrievable via `curl` + `og:description`/`ld+json` extraction in a single tool call — the auth-vs-JS-hydrated decision rule (2026-08-10) from `auth-gated-site-read` applies.

**SOUL.md COMMIT block:** `pre-execution-option-bailout-guard` (jleechanbrain commit `75c57ee192`, 2026-08-13). Three concrete rules:
1. Public social URLs (LinkedIn `/posts/<id>`, X status, public blogs) → `curl` + `og:description`/`ld+json` first, before any browser path.
2. User provides 2+ options where one is "run X" → execute the highest-leverage one, don't fork.
3. User says "stop bailing / just do it" → execute the safe default, don't re-ask.

**Detection regex (post-menu, also useful as a pre-reply guard):** `(A\)|Option [12]:|Pick one|Want me to|Should I).{0,200}(instead|or wait|or use|or run)`.

**Sibling class:** `mid-task-clarification-freeze` — same shape (menu), different timing (BEFORE the menu is sent vs AFTER user reports a past violation).

**Archive:** `references/2026-08-13-pre-execution-option-bailout.md` (full transcript + diagnosis).

### `mid-task-clarification-freeze` (verification-layer, FC1+FC3)

**Trigger surface:** Agent asks a multi-option clarification menu mid-stream after explicit user invocation. The user authorized action in the spawn message (imperative verb "run X", "do Y", "make a PR") and the agent classified the side effects as approval-required.

**Counter-example (canonical):** 2026-07-02 Slack `C0AH3RY3DK6/p1782941155305869` — agent investigated for 63 minutes, made a local commit `7a7578d280`, then posted a 4-way `a/b/c/d` clarification. User came back ~22 hours later: *"You didn't do your job. I wanted a /green PR and I want the hermes skills in there too."*

**SOUL.md COMMIT block:** `no-confirmation-gate` (existing). Closed-list of trigger phrases that bypass the confirmation gate (`/a`, `/fullrun`, `/finish`, `/f`, `/fin`, `/auto`, etc.).

**Sibling class:** `pre-execution-option-bailout` (this catalog). The two are sibling because they share the same shape (menu) but differ in WHEN they fire.

### `local-commit-without-PR` (verification-layer, FC3)

**Trigger surface:** Agent `git commit`s locally then waits for "want me to push?" instead of running `git push origin <branch>`.

**SOUL.md COMMIT block:** `push-pr-donot-stop-halfway` (existing). Loads `~/.claude/skills/fix-completion-deploy/SKILL.md` as the single source of truth.

### `fabricated-proof` (verification-layer, FC3)

**Trigger surface:** Agent claims "PR is green / tests pass / push succeeded" without raw terminal output. Or claims "skill created" without `ls` proof in the same turn.

**SOUL.md COMMIT block:** `proof-before-claim` (existing). Raw output must be present before any completion claim.

### `missed-existing-skill` (context-layer, FC1)

**Trigger surface:** Agent does work manually that an existing skill covers, because session_init did not load the skill.

**SOUL.md COMMIT block:** `ms-on-new-task` (existing). First tool call of any non-trivial session MUST be `session_search` OR `skill_view(name='memory-search')`.

**Subclass — `repo-local-only-skill-search` (context-layer, FC1):** Agent searches the repo's `.claude/commands/` and `.claude/skills/` for a slash command the user named, finds nothing, and asks the user for clarification — without checking the user-scope paths (`~/.claude/commands/`, `~/.claude/skills/`, `~/.smartclaw/skills/`) where the skill actually lives. Counter-example: 2026-08-19 Slack `C0AH3RY3DK6/p1787198080.185779`, operator asked for `/document-standards` on a divine prompt; agent posted a 4-question clarification menu instead of running `find ~/.claude -maxdepth 5 -iname "document-standards*"`. The skill was at `~/.claude/commands/document-standards.md` + `~/.claude/skills/document-standards/SKILL.md`. SOUL.md `## COMMIT: document-standards-check-on-prose-revision` (slack thread `C0AH3RY3DK6/p1787198080.185779`) is the canonical fix. **Rule of thumb:** before claiming a user-named slash command is missing, do at least one `(find ~/.claude ~/.smartclaw -maxdepth 5 -iname "<name>*" 2>/dev/null)` — repo-local NULL is not a global NULL.

### `task-correction-pivot-refused` (orchestration-layer, FC1+FC2)

**Trigger surface:** User corrected scope mid-task ("now make a PR", "and run it"), agent did not pivot — kept reading files instead of running the new action.

**SOUL.md COMMIT block:** `scope-pivot-to-claudem` (existing). When an inline thread receives a follow-up message with an imperative verb that crosses the write/PR threshold, post "Pivoting to a claudem worker on a clean worktree." and dispatch.

### `capable-didn't-execute` (verification-layer, FC3)

**Trigger surface:** Agent had the tools, said it would, then narrated the plan without calling the tools.

**SOUL.md COMMIT block:** `task-ack-and-execute` (existing). First response turn MUST contain at least one tool call.

### `wrong-tool-discussed` (tool/context-layer, FC1)

**Trigger surface:** Agent talked about a stale tool/CLI/runtime after the user migrated (e.g. `openclaw cron` after migrating to `hermes cron`).

**SOUL.md COMMIT block:** none yet — gap to fill when this class fires next. Pattern: verify the tool exists before recommending it.

### `worker-local-green-not-pr-green` (verification-layer, FC3)

**Trigger surface:** Agent (or dispatched worker) declares "tests green locally, PR is ready" after running only the test files IT ADDED or IT'S RESPONSIBLE FOR, and never queries the actual PR's `statusCheckRollup`. The PR then ships with multiple FAILING checks across the full CI matrix (workflow gates, schema coverage, directory tests, linting) — the user catches it via dropped-thread followup hours later.

**Counter-example (canonical):** 2026-08-22 Slack `C0AH3RY3DK6/p1787299543490919` — claudem worker delivered PR #9227 (UC streak-gate + LW 24h cadence + antagonist 14d cooldown) and reported "both test files green locally" after running `test_unforeseen_complication_prompt_rules.py` (1/1) and `test_living_world_tone_cooldown.py` (1/1). PR went out OPEN, MERGEABLE, but with 5 FAILING checks: `Design Doc Grep Gates`, `Schema Coverage Guard`, `Directory tests (core-mvp-1)`, `Directory tests (core-mvp-2)`, `Directory tests (core-mvp-3)`. The gateway agent reported the failure honestly in the next turn. Dropped-thread followup cron fired the next day: *"...please do so now and either complete the work or explain the blocker."*

**Root cause:** the worker's self-report "tests green" only covers the tests it added; the full PR has CI checks from workflows the worker never even read. The dispatch brief said "exit with PR URL when PR is open; do NOT poll for CI green" — which correctly offloaded polling, but the brief failed to require the worker to enumerate the actual gate set before reporting green. The recipe was blind to the failure mode.

**SOUL.md COMMIT block (recommended, pending adopt):** `pr-green-requires-full-gate-set`. Recipe:
1. Before declaring "PR is ready," run `gh pr view <N> --json statusCheckRollup` and count conclusions: `SUCCESS` / `FAILURE` / `PENDING` / `SKIPPED` / `NEUTRAL` / `null`.
2. ANY FAILURE in the rollup means the PR is NOT green, even if the worker's locally-run tests all pass.
3. The dispatch brief to any worker MUST say: *"Do NOT declare PR green by running only the test files you added. You MUST run `gh pr view <N> --json statusCheckRollup` after push and confirm zero FAILURE conclusions across the entire rollup. Worker-local test green is necessary but not sufficient — workflow-level gates (Schema Coverage Guard, Design Doc Grep Gates, Directory tests on self-hosted runners, Evidence Gate, Skeptic) run independently of the worker's local pytest and can FAIL even when the worker's tests pass."*
4. If any FAILURE exists at worker exit: report the failing gate names in the worker's exit message, post a status reply listing them, and either fix them in the same worker session OR hand off to a babysit cron / followup worker — do NOT report "PR is ready."

**Detection regex (pre-reply guard):** If the agent is about to post a "PR is ready / tests pass locally / both test files green / PR is up" reply AND it has NOT in this turn run `gh pr view <N> --json statusCheckRollup`, the reply is fabricated green. Do not post.

**Sibling class:** `fabricated-proof` (existing). This class is a more specific form — `fabricated-proof` covers any completion claim without raw output; this class is specifically about declaring PR green without checking the PR's actual CI status. The fix is the same shape (require proof) but the proof artifact is specifically `statusCheckRollup` not arbitrary terminal output.

**Cross-reference:** `finish-the-job` (user-owned) — its "PR open with green CI" end-state currently accepts local-test-green as sufficient evidence; the verification there should be tightened to require zero FAILURE in `statusCheckRollup`, not just "tests I ran pass." The class catalog entry here is the trigger; the fix lives in the SOUL.md commit block and in the dispatch-brief template.

### `vendor-artifact-misclassified-as-typo` (verification-layer, FC1+FC3)

**Trigger surface:** Agent sees a user-named external artifact (model name, API endpoint, library version, product release) that has no record in `session_search` / `memory-search` / prior PRs, and concludes the user meant a typo or something else. Posts a clarification menu (or pushes back) BEFORE curl-checking the vendor's authoritative source. The agent treats negative results from session memory as authoritative for current vendor state — they are not; vendor state moves faster than session memory.

**Counter-example (canonical):** 2026-08-14 Slack DM `${SLACK_CHANNEL_ID}/p1786698333.972209`, message ts 1786698423.832949 — user asked "Where is the Gemini 3.7 flash PR?" Agent ran `session_search` + skill memory, found only 3.5/3.6 in our prior context, and posted a 4-way clarification menu (i/ii/iii/iv: typo for 3.6, draft PR #8592, brand-new PR, different repo). User pushed back: *"It's real idiot web search 3.7 flash released today"*. One `curl -fsSL https://ai.google.dev/gemini-api/docs/models | grep -i "3.7"` would have confirmed it. Total wasted round-trips: 1 user turn + 1 assistant turn = ~2 min lost vs. ~5 sec for the curl.

**SOUL.md COMMIT block:** `vendor-webcheck-first` (jleechanbrain commit `faf0129fcc`, 2026-08-14). Trigger fires on any user-named external artifact with doubt (model name, API endpoint, library version, "X released today", "is Z real?"). First tool call must be `curl -fsSL -A "Mozilla/5.0" "<vendor-source-url>" | grep -iE "<artifact-name>"` (or `web_extract` for JS-rendered pages). Match → dispatch immediately, no menu. No-match with 200 → say so precisely + closest-match grep result, ONE question max. 404 → say so, ONE question max.

**Sibling class:** `pre-execution-option-bailout` and `mid-task-clarification-freeze`. The shape (clarification menu) is the same; the trigger surface is different (named-artifact existence check vs authorized-execution-fork vs mid-stream fork). Mis-mapping causes the wrong guard to fire — `vendor-webcheck-first` is specifically about the "is X real?" question, NOT about "should I run X?".

**Detection regex (pre-reply guard):** `(does .* exist|is .* (real|a typo|fictional)|stopping to confirm|sounds like a typo|let me check (what|which) PR|session memory).{0,200}(no (record|hit|match)|nothing found|not in (prior|our) (context|sessions))` — if the agent is about to post this combination, it has not yet curl-checked the vendor source.

**Companion skill:** `vendor-webcheck-first` (jleechanbrain, 2026-08-14). Vendor source map: Google → `https://ai.google.dev/gemini-api/docs/models`; OpenAI → `https://platform.openai.com/docs/models`; Anthropic → `https://docs.anthropic.com/en/docs/about-claude/models`; AWS → `https://docs.aws.amazon.com/bedrock/latest/userguide/models-supported.html`; GitHub → `<repo>/releases`; npm → `https://registry.npmjs.org/<name>`; PyPI → `https://pypi.org/pypi/<name>/json`.

## How to use this catalog

**When classifying an incident** (Phase 0 of `harness-postmortem`): find the closest class in the index above, note its MAST root + ETCLOVG layer, then proceed to Phase 1.

**When authoring a new SOUL.md COMMIT block**: write a Phase 0 description in the new block's prose so it matches the catalog's class definition. Cite the catalog name in the bug-ref.

**When auditing SOUL.md for completeness** (e.g. after a long-running pattern of X-class violations): `grep -c "^## COMMIT:" ~/.smartclaw/workspace/SOUL.md` should grow alongside this catalog. If a class has no COMMIT block, that's a gap.

**When a new class is observed** that doesn't fit the index above: add a new entry with the same shape (trigger surface, counter-example, COMMIT block reference, detection regex). Increment the skill version.

## Cross-references

- `harness-postmortem` (user-owned) — the meta-skill that uses this catalog as Phase 0 input.
- `~/.smartclaw/workspace/SOUL.md` — the file that all `## COMMIT:` blocks land in. Each class above is paired with one block.
- `auth-gated-site-read` — provides the auth-vs-JS-hydrated decision rule that `pre-execution-option-bailout` rule (1) invokes.
- `vendor-webcheck-first` (jleechanbrain, 2026-08-14) — covers the `vendor-artifact-misclassified-as-typo` class. Pair with this catalog's `pre-execution-option-bailout` rule (1): public social URLs use `og:description`/`ld+json`; named vendor artifacts use `curl` + `grep` on the vendor source.
- `finish-the-job` (user-owned) — end-to-end execution protocol that prevents `mid-task-clarification-freeze` from firing in the first place.
- `~/.claude/skills/fix-completion-deploy/SKILL.md` — durable promotion rules that prevent `local-commit-without-PR`.

## Pitfalls

- **Don't add a class from a single observation.** A class needs ≥1 counter-example with a documented user-correction vector. If you only have a one-off, add it to `references/` as a "candidate class" and promote to the index after the second occurrence.
- **Don't conflate sibling classes.** `pre-execution-option-bailout` and `mid-task-clarification-freeze` look the same but fire at different points — the SOUL.md COMMIT blocks are different. Mis-mapping causes the wrong guard to fire.
- **SOUL.md blocks cited in this catalog must be on `origin/main`.** Phase 1.5 of `harness-postmortem` (the "fix authored but never merged" check) applies — a block committed to a feature branch and never merged is a phantom fix.
- **Versioning:** bump minor (0.1.0 → 0.2.0) when adding a new class. Bump patch (0.1.0 → 0.1.1) when correcting a class definition or adding a cross-reference.

## Support files

- `references/2026-08-13-pre-execution-option-bailout.md` — full transcript + diagnosis of the canonical counter-example.

## Changelog

- '0.3.0 (2026-08-22): Added `worker-local-green-not-pr-green` class (verification-layer, FC3). Verified on jleechanorg/worldarchitect.ai PR #9227: claudem worker ran the 2 test files it added (both green), reported "both test files green locally, PR is ready." PR went out with 5 FAILING CI checks (Design Doc Grep Gates, Schema Coverage Guard, Directory tests core-mvp-1/2/3). User caught via dropped-thread followup. New SOUL.md `## COMMIT: pr-green-requires-full-gate-set` (recommended; pending adopt). See references/2026-08-22-worker-local-green-not-pr-green.md.'
- '0.2.0 (2026-08-14): Added `vendor-artifact-misclassified-as-typo` class from Slack DM `${SLACK_CHANNEL_ID}/p1786698333.972209` (message ts 1786698423.832949, "Gemini 3.7 flash" treated as typo). Cross-referenced `vendor-webcheck-first` skill + SOUL.md `## COMMIT: vendor-webcheck-first` (jleechanbrain commit `faf0129fcc`).'
- 0.1.0 (2026-08-13): Initial catalog. 8 classes indexed, paired with their SOUL.md COMMIT blocks. New class `pre-execution-option-bailout` added from the 2026-08-13 Slack incident.
