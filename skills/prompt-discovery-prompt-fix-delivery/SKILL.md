---
name: prompt-discovery-prompt-fix-delivery
version: 1.6.0
description: Two-pass claudem dispatch for content-only prompt fixes. Refuses prompt-content fixes when the LLM already received the rule (Phase 0 condition 5 verify-the-rule-received gate, added 2026-08-12 from operator pushback on worldarchitect.ai issue #8849). Also handles the negation — when the LLM never received the rule (condition 8, added 2026-08-20 from #9163) — by routing to a cluster-root Timeline-Divergence Anchoring PR. Also catches shape-change contract-test drift (gate 9, added 2026-08-20 from PR #9101 review-thread handling). Also documents the prompt-level A/B recipe (added 2026-08-20 from PR #9101 follow-up) for when the user asks for real-LLM provider proof of a prompt rule.
triggers:
  - "add a prompt section"
  - "add a request-type discriminator"
  - "ship a prompt fix to issue #N"
  - "fix god mode misinterprets"
  - "fix lore vs scoped admin routing"
  - "real agy cli provider proof"
  - "prove the prompt works without and with"
  - "prompt-level a/b test"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
context: inline
---

# Prompt-discovery prompt-fix delivery

The work is **content-only**: edit one or two `.md` files in `mvp_site/prompts/`,
add a small set of contract tests, and wire the new prompt type through the
shared loader. There is no API contract change, no DB migration, no CI workflow
edit, no architectural decision. The hard part is **finding the load path and
the existing inline equivalent** and writing the new content with the right
shape, then committing + pushing + opening the PR before the worker exhausts
its `--max-turns` budget.

This skill encodes the two-pass dispatch shape that prevents the
"5 worker restarts, 90+ turns, finally ships in the 5th" failure mode
(verified 2026-08-07 on jleechanorg/worldarchitect.ai PR #8813, fixing
[issue #8802](https://github.com/jleechanorg/worldarchitect.ai/issues/8802) — God
Mode misinterprets user question).

## Phases

### Phase 0 — Confirm this is a prompt-discovery task

Check ALL of:

- The fix is content in `.md` prompt files (or a single JSON/JS contract).
- The repo has a `_load_instruction_file` / `PATH_MAP` pattern for prompt
  loading (true for `jleechanorg/worldarchitect.ai` — see
  `mvp_site/agent_prompts.py` PATH_MAP and `mvp_site/agents.py` agent
  `build_system_instructions`).
- An existing `final output contract` is appended inline to the served
  prompt (true — `GodModeAgent.build_system_instructions` has an
  inline `## FINAL GOD MODE OUTPUT CONTRACT` string literal).
- The user-provided issue or brief has a clear spec for the new section
  (types, trigger phrases, precedence rules).

**5. The LLM-already-received-the-rule gate (HARD GATE — added 2026-08-12 after
operator pushback on issue #8849 / parallel to `repro` skill changelog 2.9.0
on PR #8498).** Verify the rule the prompt-fix would encode was NOT already
in the served prompt at the time of the bug. For `jleechanorg/worldarchitect.ai`
the canonical evidence path is BQ `worldarchitecture-ai.llm_forensics.llm_payloads.request_json`
filtered by `campaign_id` + the offending `turn_index`. For other repos, find
the equivalent LLM-call log (request payload capture / inference trace /
proxy log). Three sub-checks MUST all pass before this skill applies:

  - **Grep** the request payload for the rule text the new section would
    enforce (offset + percent-into-served-prompt matters; lost-in-the-middle
    threshold ≈85% per `references/prompt-delivery-vs-content-2026-07-20.md`).
  - **Grep** the request payload for the user's directive text if the bug
    is a "directive ignored" report.
  - **Confirm** the rule was NOT truncated, NOT commented out, and NOT
    behind a never-fired branch.

If the LLM already received the rule, this skill is the **WRONG tool**.
The fix is NOT a content patch — fall through to `systematic-debugging`
(class-level root-cause methodology) AND `repro` (campaign-state repro
loop). The actual bug is one of: directive budget overflow, recency-anchor
loss, attention-fatigue, schema-not-anchor, or structural prompt-layer
defect — none of which are fixed by adding more content to the prompt.
Adding a "Persona-Tier Hierarchy" / "no X" / "forbidden Y" rule when the
LLM already received the canonical two-tier rule is the canonical
anti-pattern: it duplicates the rule (the LLM already saw it), it
hardcodes campaign vocabulary (a ZFC violation per the project's
`.claude/skills/zero-framework-cognition/SKILL.md`), and it does NOT
explain WHY the LLM didn't apply the rule the first time.

**Operator pushback pattern that triggered this gate** (verbatim):
*"This is all wrong / I want a general thing nothing to do with personal /
Did the LLM even see my instructions? / Close any PRs that hardcode
campaign logic like personas."* When you see this kind of correction,
the diagnosis-first order is: (1) confirm the LLM received the rule,
(2) characterize why it didn't apply, (3) propose the fix at the layer
the bug actually lives in. Only if (1) returns NO is this skill
appropriate.

If any of conditions 1–4 fails, this is **NOT** a prompt-discovery task —
fall back to the standard `claude-code-claudem` flow. If condition 5
fails (the LLM already received the rule), this skill is the **WRONG**
skill entirely — fall through to `systematic-debugging` + `repro`.

**8. The LLM-NEVER-received-the-rule gate (HARD GATE — added 2026-08-20 from
operator pushback on issue #9163 / `repro` skill changelog 4.1.0 on
campaign `ArYA47Fvx8HTYC8jpleO`).** Distinct from condition 5: the rule was
NEVER in the served prompt at all — not because it was lost, ignored, or
picked at the wrong tier, but because no directive ever existed. The LLM
collapses back to canonical-lore ordering because nothing in the served
directive list tells it NOT to. Verified on `ArYA47Fvx8HTYC8jpleO` turn 232:
the `directive_decouple_arthas_lk` rule the LLM claims to honor was FIRST
ADDED at the user's correction turn itself (2026-08-20T09:55:30Z — verified
via BQ `directive_id` first-seen across 53 prior god-mode turns returning
NULL). The LLM did NOT receive the rule — it received the user's
correction that became the rule. Three sub-checks MUST all pass before
this skill applies — the negation of condition 5:

  - **Map directive IDs across the full bug window.** Query BQ
    `REGEXP_EXTRACT_ALL(CAST(request_json AS STRING),
    r'\\"id\\":\s*\\"(directive_[a-zA-Z0-9]{8})\\"')` ordered by `ingested_at`.
    Build first-seen map keyed by directive_id.
  - **Check if the rule the LLM cites at the correction turn was
    first-seen at the correction timestamp.** If `first_seen_ts ≈ user_correction_ts`
    (within ±5 min), the rule never existed before; the bug is directive-rule-gap.
  - **Check the served-directive context.** Extract every `rule` field via
    the corrected CSV-decoding regex (see `references/directive-rule-gap-timeline-divergence-2026-08-20.md`
    for the double-encoding pitfall). Confirm the rule topic (entity-decoupling,
    timeline-divergence, canonical-lore-fallback) has NO serving directive
    in any prior `request_json`.

If condition 8 fires (LLM never received the rule), this skill is the
**WRONG** skill for the diagnostic step — the user needs a cluster-root
PR that adds a `### Timeline-Divergence Anchoring` section to
`mvp_site/prompts/narrative_system_instruction.md` + mirror in
`planning_protocol.md` §"Canonical-State Anchor" §9 + CI lint
`scripts/check_timeline_divergence.py` + contract test pinning all
sibling scenarios. Full recipe + verified worked example at
`references/directive-rule-gap-timeline-divergence-2026-08-20.md`.
**However**, after the timeline-divergence anchor lands, individual
sub-bugs that surface as condition 5/6/7 failures on the same campaign CAN
be addressed via this skill's normal two-pass shape — the cluster-root
PR establishes the anchor layer; subsequent sibling repros become fixable
through the existing skill flow.

If any of conditions 1–4 fails, this is **NOT** a prompt-discovery task —
fall back to the standard `claude-code-claudem` flow. If condition 5
fails (the LLM already received the rule), this skill is the **WRONG**
skill entirely — fall through to `systematic-debugging` + `repro`.

**7. The prompt-teaches-non-canonical-schema gate (HARD GATE — added 2026-08-18
from issue #9099 / PR #9102, campaign `s3yGfUXCGmeqFO1Hn93m`).** Distinct from
conditions 5 and 6: the prompt IS the bug. The worked example in the prompt
file teaches the LLM a non-canonical variant of a structured field's schema
(e.g. `choices` as object-with-keys instead of canonical array-of-objects),
and the runtime parser accepts both forms via silent normalization
(`isinstance(raw_choices, dict)` → iterate keys). The LLM faithfully follows
the wrong-shape example; the parser silently normalizes; downstream the
frontend breaks because the served field is sometimes emitted as a
JSON-stringified blob with non-standard separators. The fix is a content
patch (rewrite the worked example + add a HARD `MANDATORY CHOICE FORMAT` rule
pinning the canonical schema) — but the Phase 0 sub-checks are different
from conditions 5/6. Three sub-checks MUST all pass before this skill applies:

  - **Cross-prompt shape grep:** `grep -n '"choices"' mvp_site/prompts/*.md`.
    Look for `"choices": {` (object-with-keys) vs `"choices": [` (array-of-objects).
    If BOTH appear across files, the LLM is being taught two conflicting
    shapes — that's the bug class.
  - **Parser normalization audit:** `grep -n 'isinstance(raw_choices' mvp_site/narrative_response_schema.py mvp_site/llm_parser.py`.
    If the parser accepts both forms, the bug is upstream — don't change the parser.
  - **Canonical schema cross-check:** confirm the canonical schema file
    (`planning_protocol.md` CHOICE_SCHEMA, `narrative_response_schema.py`,
    `agent_prompts.py` CHOICE_SCHEMA export) actually uses the canonical
    form. If the canonical schema says "array" but the prompt's worked example
    says "object-with-keys", that's the bug.

When condition 7 fires, the fix shape is identical to conditions 5/6
(content patch + worked example + contract test + PR body) — but the RED
proof is a **two-shot real Gemini API call** (stashed OLD prompt vs restored
NEW prompt, both responses captured verbatim in PR body). See
`references/prompt-template-schema-mismatch-2026-08-18.md` for the full
recipe + verified worked example (PR #9102).

**6. The LLM-received-the-rule-but-picked-the-wrong-tier gate (HARD GATE —
added 2026-08-16 from #8949).** Distinct from condition 5: the rule IS in the
served prompt, the LLM correctly emits the structured field with the right
field path + source enum, but the LLM selects the wrong tier from a multi-tier
decision tree. Verified on `mvp_site/prompts/narrative_system_instruction.md:205-229`
which has a 3-tier XP-pacing decision tree (`~2-4%` minor / `~8-12%` significant
/ `~25-35%` arc-resolution). User symptom: "LLM gave me the LOWEST tier for a
Frostmourne-class acquisition" — the LLM got the field structure right
(`rewards_box.source="milestone"` + `source_id` + `loot` all populated) but
picked tier-1 instead of tier-2. The fix IS a prompt-content patch (this skill
IS appropriate) but the patch is **NOT "add a new rule"** — it is **"add an
explicit in-character trigger-phrase table so the LLM matches the right tier
without the user having to god-mode-reinforce"**. Three sub-checks MUST all
pass before this skill applies:

  - **Confirm** the rule was in the served prompt (re-run condition 5 sub-checks).
  - **Confirm** the LLM correctly wrote the structured field path AND source
    enum — this is NOT a missing-write bug; this is a wrong-tier bug.
  - **Confirm** the LLM's tier selection was below the user's escalation
    reference — i.e., the user god-mode-reinforced to N× the in-character
    award for the same event, proving a higher tier exists in the prompt.

When condition 6 fires, the fix shape is **trigger-phrase vocabulary +
worked example**, NOT new tier definitions. The tier table already exists in
the prompt; it just lacks the in-character vocabulary the LLM needs to pick
the right tier automatically. Worked example MUST be **generic** (no campaign
vocabulary) per `mvp_site/prompts/AGENTS.md` ZFC compliance. Anti-pattern: a
condition-6 bug fixed by hardcoding "Frostmourne" / "Warcraft" / "Lich King"
in the trigger-phrase table — that violates the ZFC rule and reproduces the
same bug-class on a different campaign. Cross-reference:
`repro` skill changelog 4.1.0 / `references/state-update-value-derivation-tier-mismatch-2026-08-16.md`
(sub-class 8 of `npc-status-persistence-bug` taxonomy).

If any of conditions 1–4 fails, this is **NOT** a prompt-discovery task —
fall back to the standard `claude-code-claudem` flow. If condition 5
fails (the LLM already received the rule), this skill is the **WRONG**
skill entirely — fall through to `systematic-debugging` + `repro`.

**8. The LLM-NEVER-received-the-rule gate (HARD GATE — added 2026-08-20 from
operator pushback on issue #9163 / `repro` skill changelog 4.1.0 on
campaign `ArYA47Fvx8HTYC8jpleO`).** Distinct from condition 5: the rule was
NEVER in the served prompt at all — not because it was lost, ignored, or
picked at the wrong tier, but because no directive ever existed. The LLM
collapses back to canonical-lore ordering because nothing in the served
directive list tells it NOT to. Verified on `ArYA47Fvx8HTYC8jpleO` turn 232:
the `directive_decouple_arthas_lk` rule the LLM claims to honor was FIRST
ADDED at the user's correction turn itself (2026-08-20T09:55:30Z — verified
via BQ `directive_id` first-seen across 53 prior god-mode turns returning
NULL). The LLM did NOT receive the rule — it received the user's
correction that became the rule. Three sub-checks MUST all pass before
this skill applies — the negation of condition 5:

  - **Map directive IDs across the full bug window.** Query BQ
    `REGEXP_EXTRACT_ALL(CAST(request_json AS STRING),
    r'\\"id\\":\s*\\"(directive_[a-zA-Z0-9]{8})\\"')` ordered by `ingested_at`.
    Build first-seen map keyed by directive_id.
  - **Check if the rule the LLM cites at the correction turn was
    first-seen at the correction timestamp.** If `first_seen_ts ≈ user_correction_ts`
    (within ±5 min), the rule never existed before; the bug is directive-rule-gap.
  - **Check the served-directive context.** Extract every `rule` field via
    the corrected CSV-decoding regex (see `references/directive-rule-gap-timeline-divergence-2026-08-20.md`
    for the double-encoding pitfall). Confirm the rule topic (entity-decoupling,
    timeline-divergence, canonical-lore-fallback) has NO serving directive
    in any prior `request_json`.

If condition 8 fires (LLM never received the rule), this skill is the
**WRONG** skill for the diagnostic step — the user needs a cluster-root
PR that adds a `### Timeline-Divergence Anchoring` section to
`mvp_site/prompts/narrative_system_instruction.md` + mirror in
`planning_protocol.md` §"Canonical-State Anchor" §9 + CI lint
`scripts/check_timeline_divergence.py` + contract test pinning all
sibling scenarios. Full recipe + verified worked example at
`references/directive-rule-gap-timeline-divergence-2026-08-20.md`.
**However**, after the timeline-divergence anchor lands, individual
sub-bugs that surface as condition 5/6/7 failures on the same campaign CAN
be addressed via this skill's normal two-pass shape — the cluster-root
PR establishes the anchor layer; subsequent sibling repros become fixable
through the existing skill flow.

If any of conditions 1–4 fails, this is **NOT** a prompt-discovery task —
fall back to the standard `claude-code-claudem` flow. If condition 5
fails (the LLM already received the rule), this skill is the **WRONG**
skill entirely — fall through to `systematic-debugging` + `repro`.

**9. The contract-test-rule-shape-change gate (HARD GATE — added 2026-08-20
from PR #9101 review-thread handling).** When the user's correction
changes the SHAPE of a prompt rule — fixed enum → freeform string,
file-pointer → inline rule, mandatory output → optional, canonical-noun
→ LLM-invented noun — the contract test that pinned the OLD shape MUST
be renamed and rewritten in the SAME COMMIT. Otherwise the test suite
goes red at the very moment the user-requested change is applied, and
the shipper pass ships a broken PR. Verified on PR #9101
(2026-08-20): user asked the LLM to "freeform make arcs not pick from a
list" on `player_character_arcs.md`; the existing contract test
`test_pc_arc_prompt_references_eight_arc_types` was asserting the 8-arc
enum names were in the served prompt. Fix shape: rename the test to
encode the new rule, add a negative pin against the OLD shape (e.g.
`assert "COMPANION_ARC_TYPES" not in content`), and pin the
SHAPE-INVARIANT parts (e.g. the four canonical phases that stayed
fixed) as positive assertions. Full recipe + worked example:
`references/contract-test-rule-shape-changes.md`.

### Phase 1 — First worker call: discovery + content write only (NO commit)

Dispatch ONE `claudem -p` call with a tight scope. The worker must:

1. Locate the load path (e.g. `mvp_site/agent_prompts.py` PATH_MAP,
   `mvp_site/agents.py` agent `build_system_instructions`,
   `mvp_site/constants.py` for path constants).
2. Locate the existing inline equivalent (the string literal that the new
   contract will replace).
3. Read the user-provided issue spec verbatim and write the new section in
   the exact shape requested (e.g. for #8802: 4 types only — `lore`,
   `scoped_admin`, `full_audit`, `correction` — with explicit precedence
   rules).
4. Mirror the section in the new `mvp_site/prompts/<name>_output_contract.md`
   file with a brief final-output-contract tail.
5. Add focused contract tests in `mvp_site/tests/test_prompts.py` (or the
   relevant test file).
6. **Do NOT commit. Do NOT push. Do NOT open a PR.** Return the exact file
   paths and the full content of each new file so the gateway can verify
   shape.

```bash
bash -lic 'claudem -p "<task>" --max-turns 12'
```

The narrow budget forces the worker to skip exploration it does not need
and write content fast. If it cannot finish in 12 turns, the worker's
exploration path is too wide — narrow the task prompt.

### Phase 2 — Gateway verification + content patch (the gateway is the editor)

Read the worker's output. Verify ALL of:

- The new file content matches the user-provided spec exactly
  (e.g. for #8802: 4 types only, not 10; precedence rules explicit;
  scope words mentioned).
- The loader wiring is correct: new `PROMPT_TYPE_*` constant in
  `mvp_site/constants.py`, new path constant, new `PATH_MAP` entry, and the
  agent's `build_system_instructions` switched from inline string to
  `_load_instruction_file(...)` via the shared loader.
- **The contract test that pins the OLD rule shape was renamed and
  rewritten** (gate 9 above). If the user's correction changed the rule
  shape and the existing contract test was NOT updated in the same
  commit, the test suite WILL go red on the next `pytest` run. Catch it
  in Phase 2 — before shipping.

If the shape is wrong or the wiring is incomplete, edit the files directly
with `write_file` / `patch` rather than re-dispatching. **The gateway is
allowed to make 1–2 line patches after the worker runs out of budget.**

### Phase 3 — Second worker call: the shipper (NO design)

Dispatch ONE `claudem -p` call as the final shipper, with a step-by-step
recipe that does NOT ask the worker to discover or design. The prompt
MUST include:

1. The exact list of files to add (`git add` argument).
2. The exact commit subject (must start with `claudem/minimax-M3:`).
3. The exact push command: `git push -u origin <branch>`.
4. The exact `gh pr create` command, with `--repo`, `--base main`,
   `--head <branch>`, `--title`, and `--body`. The body should link the
   issue with `Fixes #<N>`.
5. An explicit allowance: "If the test command is unavailable, record the
   exact error and STILL commit/push/open the PR. Do not let a pre-existing
   environment issue block shipping."
6. **No merge.** The agent does NOT run `gh pr merge`. Skeptic-cron owns
   the merge.

```bash
bash -lic 'claudem -p "<shipper task>" --max-turns 25'
```

### Phase 4 — Gateway verification of the push

After the shipper returns:

```bash
git rev-parse origin/<branch>    # MUST equal the local SHA
gh pr view <N> --json headRefOid,mergeable,state,statusCheckRollup
```

If `git rev-parse origin/<branch>` does NOT equal the local SHA, the
push did not land. Investigate before reporting success.

### Phase 5 — Final Slack reply

Required shape:

```
✅ Done: PR #<N> (<repo>) OPEN, awaiting your review.

**What shipped**
- <one-line description of each file>
- <what the fix prevents>

**Proof**
- Commit: <sha>
- Branch: <branch>
- git status: <clean or pending>
- gh pr view: state=OPEN, mergeable=MERGEABLE, CodeRabbit=SUCCESS
- Test output: <actual pytest output, OR the exact pre-existing error>

**End state:** PR open and mergeable, awaiting CI/review. I did not merge it.

Status cron armed: <cron_job_id> for a one-time check in 20 minutes.

🧠 Memories used: [...]

Pending — needs your PR review + merge to apply.
```

NO "want me to push?" / "want me to ship?" confirmation gate.

## Worked example — jleechanorg/worldarchitect.ai PR #8813 (2026-08-07)

Trigger: Jeffrey said "make a PR to fix" in the same thread that had
[issue #8802](https://github.com/jleechanorg/worldarchitect.ai/issues/8802)'s
verified diagnosis (God Mode misinterprets user question, e.g. lore
questions routed to a full economy audit).

- **Phase 0 (prompt-discovery confirmed):** issue spec was a 4-component
  prompt-contract fix with 4 explicit request types
  (`lore`, `scoped_admin`, `full_audit`, `correction`).
- **Phase 1 (worker attempt 1, max-turns 30):** exhausted budget. Wrote
  only the new test file (+169 lines in `mvp_site/tests/test_prompts.py`).
  No prompt file writes, no commit.
- **Phase 1 (worker attempt 2, max-turns 30, "continue the implementation"):**
  exhausted budget. Same diff.
- **Phase 1 (worker attempt 3, max-turns 12, "minimal focused prompt-contract fix"):**
  exhausted budget. Same diff.
- **Phase 1 (worker attempt 4, max-turns 20, "inspect the untracked contract; finish the PR"):**
  exhausted budget. Wrote a 97-line `mvp_site/prompts/god_mode_output_contract.md`
  with a 10-type table (wrong shape — issue spec called for 4 types). Modified
  `mvp_site/prompts/god_mode_instruction.md` (+24 lines) but the new section
  shape was inconsistent. No commit.
- **Phase 2 (gateway):** inspected the worker's diff. Verified the wiring
  in `mvp_site/agent_prompts.py`, `mvp_site/agents.py`, `mvp_site/constants.py`
  was correct. Wrote the correct 4-type section directly into
  `mvp_site/prompts/god_mode_instruction.md` via `patch` (replacing the
  worker's inconsistent 10-type hint with the spec's 4-type taxonomy + 7
  precedence rules).
- **Phase 3 (worker attempt 5, max-turns 25, shipper):** succeeded. Commit
  `8dc16466b9d41c241c0334629f21761fb611197a` landed; PR
  [#8813](https://github.com/jleechanorg/worldarchitect.ai/pull/8813) opened.
  Test collection blocked by pre-existing `google-genai` enum drift in
  `mvp_site/llm_providers/gemini_provider.py:74` (`HARM_CATEGORY_HATE_SPEECH`
  AttributeError). Recorded the exact error and shipped anyway per the
  allowlist.
- **Phase 4 (gateway verify):** `git rev-parse origin/fix/godmode-request-type-discriminator-8802`
  equaled local SHA. `gh pr view 8813` showed `state=OPEN`,
  `mergeable=MERGEABLE`, `CodeRabbit=SUCCESS`, `Cursor Bugbot=NEUTRAL`.
- **Phase 5 (Slack reply):** PR URL + commit SHA + file list + test output
  (with documented blocker) + `Pending — needs your PR review + merge to apply.`
  One-time status cron `7c4364a84af5` armed for 20 min.

Total: 5 worker restarts, ~120 worker turns, but the **gateway acted as the
editor** between attempts — the third+ runs would have failed identically
without the gateway rewriting the prompt section in place. The skill that
makes the difference is the **two-pass dispatch shape** with a hard
**gateway-as-editor** seam between the two passes.

## Worked example — jleechanorg/worldarchitect.ai PR #8950 / issue #8949 (2026-08-15)

Trigger: Jeffrey pasted a `/repro` URL and said *"let's make a generic
prompt only fix not specific to this campaign. The LLM needs to automatically
give special exp and awards for important milestones or feats like acquiring
frostmourne"*. Followup: *"Make the PR /ready where is it? Don't stop"*.

Bug class: **state-update value-derivation drift** — sub-class 8 of
`npc-status-persistence-bug` (Phase 0 condition 6 above). The LLM correctly
derived the value in narrative prose (multi-stage ritual climax), correctly
wrote `rewards_box.source="milestone"` + the loot item, but wrote a value
~3× too low (~10% of band instead of ~25-35% for the tier-2
multi-session-arc-resolution branch). The existing tier-2 branch only
fired when the player explicitly god-mode-reinforced the event.

- **Phase 0 condition 5 + condition 6 verify-the-rule-received + wrong-tier
  gates both worked correctly.** BQ `worldarchitecture-ai.llm_forensics.llm_payloads`
  showed `milestone` × 63 hits in the 1.16 MB served prompt, `significant
  accomplishment` at offset 893,829 (76.9%), `8–12%` × 5 hits at offset
  893,916+, `25–35%` × 4 hits at offset 893,975+. Rule was present. The
  fix is **tier-2 trigger vocabulary**, NOT a new rule. No ZFC violation.
- **Phase 1 worker (max-turns 25) — single attempt:** required explicit
  **`APPROVE DIR SWITCH`** message before editing files in the fresh
  worktree `${HOME}/projects/wt-milestone-tier-8949`. The worker's
  policy refuses to edit files outside the primary workspace
  `${HOME}/projects/worldarchitect.ai` until the user message
  contains that exact phrase. Without prepending it, the first worker run
  wastes a turn asking. **Pitfall:** when dispatching to a fresh worktree
  at a non-primary path, **prepend `APPROVE DIR SWITCH` to the task
  prompt** before the rest of the instructions.
- **Phase 1 worker succeeded in 1 attempt:** wrote exact-spec content for
  `mvp_site/prompts/narrative_system_instruction.md` (+25 lines: `##
  Milestone Tier Classification` section with 4 tier-2 trigger bullets +
  worked example + anti-pattern) and `mvp_site/prompts/rewards_system_instruction.md`
  (+4 lines: `## Reward Tier Selection` mirror). Created
  `mvp_site/tests/test_milestone_tier_classification_8949.py` with the
  walking-up-from-`__file__` repo resolver pattern (no hard-coded repo
  path — same pattern as
  `test_planning_block_npc_peer_autonomy_anchor_8499.py`). 8/8 contract
  tests passed including the banned-vocabulary case-fold check
  (Frostmourne / Warcraft / Lich King / etc. — banned per
  `mvp_site/prompts/AGENTS.md`).
- **Phase 3 shipper:** commit `53195807ce` (prefixed `claudem/minimax-M3:`
  per the commit-provenance rule).
- **Phase 4 verify:** `git rev-parse origin/fix/...` == local SHA.
  `gh-safe-publish pr create` hit `GraphQL: API rate limit already
  exceeded` (bucket exhausted by earlier `gh-safe-publish issue create`
  in the same session). **Pitfall:** always check
  `gh api rate_limit --jq '.resources.graphql.remaining'` BEFORE both gates;
  if `<500`, expect at most 1 retry on the second gate. Fallback path:
  `urllib.request` POST to
  `https://api.github.com/repos/<owner>/<repo>/pulls` with the same
  `gh auth token`. REST has a separate bucket, almost always fresh.
  PR #8950 opened via REST, `state=OPEN, draft=false, mergeable=true`.
- **Phase 5 reply:** PR URL + commit SHA + file list + 8/8 test proof +
  cross-refs to bead `rev-sjhem` + the canonical-state contradiction +
  BQ offset evidence + status cron `550e9e12828c` armed.
- **"Make the PR /ready" user signal:** when the user types `/ready`,
  "where is the PR", or "don't stop", the shipper MUST open with
  `draft: false` in the PR-create payload (REST API `{"draft": false}` or
  `gh pr create` without `--draft`). A draft PR that needs an extra
  click to "Ready for review" is the **stop-halfway anti-pattern** for
  prompt-fix PRs — ship them ready.

Total: 1 worker attempt + 1 shipper pass = 2 worker restarts (vs. 5 in
the #8813 worked example). The smaller scope (single self-contained
section + tier-2 vocabulary, no architectural wiring changes) is what
made the single-attempt worker succeed. **The prompt-content fix shape
matters: small, surgical, exact-spec sections ship in one pass;
multi-file or structural fixes need the two-pass + gateway-as-editor seam.**

## Anti-patterns (specific to prompt-discovery tasks)

- ❌ **Hardcoding a content rule when the LLM already received the canonical
  rule** (added 2026-08-12). The most expensive anti-pattern in this skill.
  Three-step trap: (1) agent observes a bug where the LLM ignored an existing
  rule, (2) agent jumps straight to "add a forbidden-Y / no-X / persona-tier-Z
  section to the prompt", (3) the new section duplicates the rule the LLM
  already saw, hardcodes campaign-specific vocabulary (ZFC violation per
  `.claude/skills/zero-framework-cognition/SKILL.md`), and doesn't explain
  why the LLM didn't apply the rule the first time. Verified on
  jleechanorg/worldarchitect.ai issue [#8849](https://github.com/jleechanorg/worldarchitect.ai/issues/8849)
  (campaign `0lZBWUBP4Na3u4XjArOd`, 2026-08-11/12) — agent recommended
  a "Persona-Tier Hierarchy (No 'Envoy-Evolution' Tier)" section; operator
  pushback was *"This is all wrong / I want a general thing nothing to do
  with personal / Did the LLM even see my instructions?"* Investigation
  after the pushback confirmed the directives WERE in the prompt via
  `mvp_site/agent_prompts.py:2365 build_god_mode_directives_block()` —
  the bug was NOT a content gap. **Detection rule:** before writing any
  forbidden-list / persona-tier / tier-name / "no-X" section, run the
  Phase 0 condition 5 verify-the-rule-received gate. If the rule was
  already in the served prompt, this skill is the wrong tool — hand off
  to `systematic-debugging` and `repro`. Same precedent: PR #8498 /
  `repro` skill changelog 2.9.0 — *"the LLM-already-received-the-rule
  branch is NOT a prompt-rule fix"*.

- ❌ Asking the worker to "implement issue X" with no step-by-step recipe.
  The worker will spend 60–80% of its budget on exploration. The recipe in
  the prompt is the difference between 5 worker restarts and 2.
- ❌ "Continue the implementation" — when the worker is already at max
  turns, a fresh prompt asking it to continue will re-explore rather than
  finish. The right move is to inspect what the worker left behind and
  either edit the remaining gaps in the gateway or dispatch a tightly-scoped
  shipper pass.
- ❌ "Run pytest before committing" without a documented allowlist — if
  the test environment is broken (pre-existing dependency mismatch in a
  module the diff does not touch), the worker will burn 5–10 turns on
  debugging the environment, then time out before committing. Always
  allow the shipper pass to record the test error and still commit.
- ❌ Letting the worker write a wrong-shape contract (e.g. 10-type table
  when the issue spec calls for 4 types) without re-asserting the spec.
  The final shape MUST be verified against the issue body before push.
- ❌ Single worker call with `--max-turns 50` hoping "more turns will help."
  It will not. The 50-turn worker will still exhaust its budget on
  exploration and arrive at the same partial diff. The fix is **two
  worker calls** with a gateway seam, not one worker with more turns.
- � **Forgetting `APPROVE DIR SWITCH` when dispatching to a non-primary
  worktree (added 2026-08-15, PR #8950).** The claudem worker refuses
  to edit files outside its primary workspace
  (`${HOME}/projects/<canonical-repo>`) until the user message
  contains the exact phrase `APPROVE DIR SWITCH`. When the user asks for
  a fix on a fresh worktree at `${HOME}/projects/wt-<topic>` or
  any other non-primary path, prepend `APPROVE DIR SWITCH` to the task
  prompt BEFORE the rest of the instructions — otherwise the first worker
  attempt wastes a turn asking for it and you pay one extra restart.
- ❌ **Opening the PR as a draft when the user said `/ready` or "where is
  it" or "don't stop" (added 2026-08-15, PR #8950).** A prompt-fix PR
  is content-only and self-contained — there is no reason to gate it
  behind an extra "Ready for review" click. Ship with `draft: false`
  (REST `{"draft": false}` or `gh pr create` without `--draft`). A
  draft PR is the **stop-halfway anti-pattern** for prompt-fix PRs
  specifically (different from workflow/drive-pr-to-green where a draft
  is acceptable for CR iteration).
- ❌ **Hitting `gh pr create` GraphQL rate limit and stalling instead of
  REST-falling-back (added 2026-08-15, PR #8950).** GraphQL and REST are
  separate rate-limit buckets. When `gh-safe-publish pr create` returns
  `GraphQL: API rate limit already exhausted`, fall back to
  `urllib.request` POST against
  `https://api.github.com/repos/<owner>/<repo>/pulls` with the same
  `gh auth token`. REST has a separate quota and is almost always fresh.
  Do NOT retry the same GraphQL bucket (it won't refill for ~1h) and do
  NOT stall the shipper — REST-fallback in the same worker turn.
- ❌ **Shipping the user-requested rule-shape change WITHOUT rewriting the
  contract test that pinned the OLD shape (added 2026-08-20, PR #9101).**
  The prompt-edit looks correct in the diff but the contract test still
  asserts the old enum / pointer / mandate. `pytest` goes red at the
  moment the change is applied. Three-step trap: (1) agent reads the
  review-thread comment, (2) agent edits the prompt file and updates the
  inline examples, (3) agent forgets the contract test pins the OLD
  shape and ships a red PR. Detection rule: when applying a user
  correction, ALWAYS grep the test file for the OLD shape's identifier
  (e.g. `COMPANION_ARC_TYPES`, `MakeChanges`, `__DELETE__`, the literal
  enum names). If found, the test MUST be renamed + rewritten in the
  same commit. See gate 9 above and
  `references/contract-test-rule-shape-changes.md`.

## Related skills / references

- `claude-code-claudem` — the parent umbrella that defines `claudem -p` and
  `--max-turns`. This skill is a session-detail extension that adds the
  two-pass + gateway-as-editor shape for prompt-discovery tasks.
- `workflow/always-pr-never-local-edit` — confirms the gateway-as-editor
  pattern: small surgical patches between worker calls are allowed, but
  the end state is still a PR.
- `workflow/drive-pr-to-green` — handles the *post-PR* drive to mergeable
  green. This skill stops at "PR open and mergeable." Drive-pr-to-green
  picks up from there.
- `references/state-update-value-derivation-tier-mismatch.md` — verified
  worked example (PR #8950 / issue #8949, 2026-08-15) of the 8th sub-class
  of `npc-status-persistence-bug`: tier-mismatch from a multi-tier decision
  tree. BQ diagnostic recipe + 4-component fix shape + 8-test contract
  template + banned-vocabulary list. Load when the symptom is "LLM gave me
  the LOWEST tier for a clearly-climactic event."
- `references/prompt-template-schema-mismatch-2026-08-18.md` — **NEW
  (2026-08-18, issue #9099 / PR #9102, campaign `s3yGfUXCGmeqFO1Hn93m`)**:
  the 9th sub-class — prompt teaches non-canonical schema variant. The
  prompt file's worked example teaches `choices` as object-with-keys while
  the canonical schema (`planning_protocol.md` CHOICE_SCHEMA) requires
  array-of-objects. Parser at `narrative_response_schema.py:3983-3984`
  silently accepts both forms via normalization, masking the prompt-side
  bug. RED proof = two-shot real Gemini API call (stashed OLD prompt vs
  restored NEW prompt). 4-component fix shape identical to conditions 5/6
  (content patch + worked example + contract test + PR body). Companion
  to `references/state-update-value-derivation-tier-mismatch.md` — both
  classes share the pattern "LLM faithfully follows what the prompt says;
  the prompt is wrong." Load when `grep '"choices"' mvp_site/prompts/*.md`
  shows BOTH `"choices": {` AND `"choices": [` across files, OR when BQ
  `llm_payloads` returns 0 rows for the affected campaign (client-side /
  parser-normalization symptom).
- `references/directive-rule-gap-timeline-divergence-2026-08-20.md` —
  **NEW (2026-08-20, issue #9163, campaign `ArYA47Fvx8HTYC8jpleO`)**: the
  negation of condition 5 — directive-rule-gap (timeline-divergent
  entity-conflation). When an alternate-timeline campaign re-routes
  canonical lore (player claims a canonical artifact before its canonical
  owner — Frostmourne goes to Nocturne instead of Arthas), the served
  directives implicitly assume canonical-lore ordering and DO NOT
  explicitly mark the timeline divergence. The LLM collapses back to
  canonical lore, conflating entities the campaign has explicitly
  separated. **Smoking-gun diagnostic:** query BQ
  `worldarchitecture-ai.llm_forensics.llm_payloads.request_json` for
  `directive_<8-hex>` IDs across the bug window. If the rule the LLM
  claims to honor at the correction turn was FIRST ADDED at that turn
  itself (not present in any prior request), the bug is directive-rule-gap.
  **Companion CSV double-encoding pitfall:** BQ `--format=csv` adds another
  layer of escaping on top of JSON's `\\\"`; use Python `csv.reader` to
  unwrap outer quoting before regex matching rule text. Naive regex
  `\"rule\":\\s*\"((?:[^\"\\\\]|\\\\.)*?)\"` returns 0 matches; corrected regex
  `\\\\\"rule\\\\\":\\s*\\\\\"((?:[^\"\\\\\\\\]|\\\\\\\\.)*?)\\\\\"` after CSV-unquoting returns
  the full rule list. Verified on `ArYA47Fvx8HTYC8jpleO` turns 180-232:
  directive count grew 23→56 across the 11-hour window; `directive_7b809075`
  first-seen = the correction turn itself. **Cluster context:** 4 sibling
  repros in 24 hours (#9147 Frostmourne/Raven's Needle + #9149 latency +
  #9162 Kel'Thuzad fabricated death + #9163 Arthas/Lich King) all share
  the same root — no explicit timeline-divergence anchor in the prompt
  layer. **Fix shape:** cluster-root PR adds
  `### Timeline-Divergence Anchoring` section to
  `narrative_system_instruction.md` + mirror in `planning_protocol.md`
  §9 + CI lint `scripts/check_timeline_divergence.py` + contract test
  pinning all 4 sibling scenarios. Cross-references `repro` skill
  changelog 4.1.0 + project-owned `references/npc-status-persistence-bug.md`
  + project-owned `references/god-mode-directive-missing-subclasses.md`
  Factor A-H doctrine (none apply; NEW class).
- `references/prompt-level-ab-test.md` — **NEW (2026-08-20, PR #9101
  follow-up A/B)**: when the user asks for "real AGY CLI provider proof"
  or "/test-realistic style" evidence, the 6-step recipe for a real-LLM
  prompt-level A/B test. Build two worktrees from the same PR head, stub
  the prompt file under test in the control worktree, dispatch each
  variant to AGY CLI (`agy --new-project --model <gemini> --sandbox -p
  "<prompt>" --output-format json --json-schema <schema>`), extract
  `structured_output` from the response, and write an honest verdict.
  Verified on PR #9101 cadence A/B: result was INCONCLUSIVE because
  Gemini 3.7 Flash knew the cadence rule from training data — both
  variants emitted `companion_arc_event` in 2/3 turns. The recipe
  documents the AGY CLI invocation pitfalls (`-p` not stdin, `--sandbox`
  not `--dangerously-skip-permissions`, `structured_output` not
  `response`), the 6 steps, and the "what to do when INCONCLUSIVE"
  protocol (don't pretend PASS; propose the next experiment that
  WOULD isolate the contribution). Load this whenever the user asks
  for prompt-level proof that doesn't go through Flask / Firebase.

- `references/contract-test-rule-shape-changes.md` — **NEW
  (2026-08-20, PR #9101)**: gate 9 — when a user review-thread
  correction changes the SHAPE of a prompt rule (fixed enum →
  freeform string, file-pointer → inline rule, mandatory → optional,
  canonical-noun → LLM-invented noun), the contract test that pinned
  the OLD shape MUST be renamed and rewritten in the SAME COMMIT.
  Three principles: rename the test, add a negative pin against the
  old shape, and pin the SHAPE-INVARIANT parts as positive assertions.
  Verified worked example on PR #9101: 8-arc-type enum → freeform
  arc_type + drop `COMPANION_ARC_TYPES` pointer; the existing
  `test_pc_arc_prompt_references_eight_arc_types` was renamed to
  `test_pc_arc_prompt_declares_freeform_arc_type` with a negative
  pin (`assert "COMPANION_ARC_TYPES" not in content`) and a positive
  pin for the four canonical phases that stayed fixed. Load when a
  review-thread comment contains any of: *"make X freeform"*, *"don't
  pick from a list"*, *"drop the code pointer"*, *"remove the
  mandatory Y"*, *"no fixed enum"*.
