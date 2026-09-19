---
name: wa-prompt-only-sanctuary-dialog-opportunities
version: 1.0.0
description: Add a BG3-style companion dialog rule on a WA state flag.
author: hermes-agent
license: MIT
last_verified: 2026-08-16
related_skills:
  - campaign-design-rpg-bible
  - mvp_site/prompts/AGENTS.md
metadata:
  hermes:
    tags:
      - prompt-edit
      - worldarchitect
      - dialogue
      - sanctuary
    related_skills:
      - campaign-design-rpg-bible
---

# Add a prompt-only "BG3-style companion dialog" rule to a WA campaign

## When to use

User asks for a dialog-only, rest-anchored, no-plot-advancement scene surface (BG3-style campfire/lunch/dinner banter with companions) inside an existing campaign. The right fix is almost always a **prompt-only edit** that anchors on an existing mechanical state flag (e.g. `custom_campaign_state.sanctuary_mode.active`) — not a new schema field, not a new agent, not a backend state change.

Concrete trigger phrases: "BG3-style companion dialog", "dialog opportunities during long rest / short rest / lunch / dinner / breakfast", "companion banter at campfire", "sanctuary-mode quiet scene", "no plot advancement", "rest-anchored beat".

## Why this is a prompt-only change

The user's locked preference (campaign-design-rpg-bible rule #2) is to never pre-decide outcomes, always offer a 3-option carousel + Freeform slot. The existing `Sanctuary Mode` section in `mvp_site/prompts/living_world_instruction.md` already says:

> **ALLOWED during sanctuary:** Companion conversations, planning, shopping, training, peaceful exploration, minor (non-lethal) complications.

…but that's a passive allowance. The LLM needs a concrete, repeatable rule. Add a self-contained section that lifts the passive allowance into an active trigger + a worked example + a hard-prohibitions list.

## The 4-shaped rule (always emit all four)

1. **When to offer** — gate on the existing state flag + a list of rest-anchored trigger verbs (long rest, short rest, lunch, dinner, breakfast, campfire, evening/morning watch, "we make camp", "we eat", "we sit by the fire").
2. **What the opportunity looks like** — cast (1 companion by default, 2 if recent turns featured both), setting (anchor physically to where the player actually is), dialogue (reference concrete `companion_arcs.<name>.history[last]` or `core_memories`), 3-option tonal carousel + Freeform.
3. **What the opportunity MUST NOT do** — no plot advancement, no companion arc progression, no scene events, no XP, no `rest_taken`, no new god-mode directives, world time advances < 1 hour.
4. **Output shape** — ride on the existing character-mode narrative response; no new top-level field; dialog in `narrative`, choices in `planning_block.choices`.

## Where to anchor the section

Append the new section **inside the existing Sanctuary Mode / sanctuary section** of `mvp_site/prompts/living_world_instruction.md`, immediately after the existing `Sanctuary Rules` block (right before `## Output Requirements`). Do NOT create a new file. Do NOT add to `PATH_MAP` — the file is already registered.

## The contract test (mandatory per `mvp_site/prompts/AGENTS.md` Hard rule #5)

Add a single test to `mvp_site/tests/test_prompts.py` that pins:

- the section anchor (`## Sanctuary Dialog Opportunities`)
- the eight trigger verbs (assert each one in the loop)
- the Freeform slot literal ("Say something else (freeform)")
- the `companion_arcs` anchor
- the six hard prohibitions ("No plot advancement", "No companion arc progression", "No scene events", "No XP", "rest_taken", "companion_arc_event`)
- the output shape (`narrative` + `planning_block.choices`)

Use the existing `_load_instruction_file` / `_read_prompt` helper that resolves `{{PROMPT_INCLUDE:}}` placeholders — never read the raw file in tests.

## Hard rules (from `mvp_site/prompts/AGENTS.md`)

1. No version history in the prompt body.
2. No meta-commentary / "this is the most important section" / "remember to do X".
3. No editorializing.
4. Each rule self-contained in the served prompt (don't share via silent copy).
5. No banned entities (no D&D Ao/Mystra/Shar unless the prompt is explicitly the D&D appendix).
6. Generic placeholders, then setting-specific appendix.
7. No code, no commands, no shell in prompt text.
8. Quantitative anchors with formulas, not inspirational cites.
9. Write for the LLM that executes, not for a human reviewer.

## Workflow (track all of these)

1. **Worktree from `origin/main`** — `git worktree add -b feat/<slug> ~/.worktrees/wa-<slug> origin/main`. Never push onto a feature branch.
2. **Symlink the venv** — `ln -s ${HOME}/projects/worldarchitect.ai/venv venv` so `./vpython` works in the worktree.
3. **Edit the prompt** — single self-contained section (see "The 4-shaped rule").
4. **Add the contract test** — see "The contract test".
5. **Run the test** — `./vpython -m unittest mvp_site.tests.test_prompts.TestPromptLoading.test_<name> -v` and the surrounding sanctuary/prompt-registration tests. PASS required.
6. **Verify the served prompt** — `python -c "from mvp_site.agent_prompts import _load_instruction_file; p = _load_instruction_file('living_world'); assert 'Sanctuary Dialog Opportunities' in p; print('OK')"` to confirm the rule reaches the LLM.
7. **File the bead** — `br create "<user-ask title>" --type chore --priority 2 --description-file <path>` for the work item.
8. **Commit + push** — commit with `<cli>/<model>:` prefix per SLT rule; push the branch.
9. **Open the PR** — `gh pr create` with the worked example inside the body (per AGENTS.md requirement).
10. **Slack the user at channel root** (not thread — mobile doesn't render threads) with prompt + PR + contract test + bead.
11. **Arm the one-time status cron** — `cronjob create "20m"` with `--delete-after-run`, deliver to the same channel.

## WORKFLOW CORRECTION (skillify lesson from 2026-08-17, PR #8979)

`/ready` is a CI gate (Green Gate + no conflicts). It does NOT fetch inline review comments. After creating a PR, treat the FIRST 60 minutes as a `recent-commit-recheck` window — on every Slack-side re-entry to the PR, run:

```bash
gh api graphql -f query='{ repository(owner: "jleechanorg", name: "worldarchitect.ai") {
  pullRequest(number: N) {
    reviewThreads(first: 50) { nodes { id isResolved comments(first: 5) { nodes { author { login } body } } } }
  }
}}'
```

If any `isResolved: false` thread is from the user, address it before posting any "ready for review" / "all green" reply. Reply to thread via `addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId, body})`; resolve via `resolveReviewThread(input: {threadId})`. Don't trust the visible PR state (`isDraft:false`, `mergeable:MERGEABLE`) — review threads are orthogonal.

## Pitfalls

- **Don't create a new top-level field.** Sanctuary dialog opportunities ride on the existing `narrative` + `planning_block.choices` pair. Adding a new field forks the schema and the rendering pipeline.
- **Don't make it a `companion_arc_event`.** That system is for **multi-turn arc progression** (20-30 turns from discovery to resolution). A BG3-style campfire is a **beat**, not a step. The hard-prohibition list explicitly forbids `companion_arcs.<name>.progress` / `phase` / `history` writes.
- **Don't emit `rest_taken` from a dialog opportunity.** Mechanical rest is the player's separate choice; emitting `rest_taken` here would reset resource registries and front-load the rest side-effects into the dialog turn.
- **Don't advance `world_data.world_time` by days.** The opportunity is a beat that lasts a few minutes; the player can take a real mechanical rest on the next turn.
- **Don't pick the same companion two offers in a row** unless the player asked. Read `companion_arcs.<name>.history` and pick the one with the least-resolved recent topic.
- **Don't forget the Freeform slot.** The user's locked preference (campaign-design-rpg-bible rule #2) is a 3-option carousel + Freeform in every choice surface. Forgetting Freeform is the single most common LLM regression on this campaign class.
- **Don't claim it's "done" without the contract test passing.** Per `mvp_site/prompts/AGENTS.md` Hard rule #5, the test is the canonical evidence the rule is in the served prompt.

## Verification

- [ ] New section appears in `_load_instruction_file('living_world')` output (`assert 'Sanctuary Dialog Opportunities' in p`)
- [ ] Contract test passes (4/4 incl. surrounding sanctuary + prompt-registration tests)
- [ ] No new top-level field in any schema
- [ ] No `PATH_MAP` change (the file is already registered for `StoryModeAgent`)
- [ ] PR is clean off `origin/main` (`git log origin/main..HEAD` shows only this commit)
- [ ] Diff budget < 1000 lines (typical: +54 prompt, +40 test)
- [ ] Bead filed at P2
- [ ] Slack reply at channel root
- [ ] One-time status cron armed (`--delete-after-run`, `--at 20m`)

## Cross-references

- `~/.smartclaw/skills/campaign-design-rpg-bible/SKILL.md` rule #2 (3-option carousel + Freeform)
- `~/projects/worldarchitect.ai/mvp_site/prompts/AGENTS.md` Hard rules 1-9 (prompt content contract)
- `~/projects/worldarchitect.ai/mvp_site/prompts/living_world_instruction.md` § Sanctuary Mode (existing mechanical sanctuary)
- `~/projects/worldarchitect.ai/mvp_site/prompts/living_world_instruction.md` § Companion Quest Arcs (existing multi-turn arc system — explicitly NOT triggered)
- `~/projects/worldarchitect.ai/mvp_site/tests/test_prompts.py:test_rewards_prompt_carries_sanctuary_activation_contract` (precedent for the contract test pattern)
- SOUL.md `## COMMIT: always-skillify-after-non-trivial-work` (this skill is the durable artifact)
- SOUL.md `## COMMIT: one-time-status-cron-after-every-task` (the 20m follow-up cron)
- SOUL.md `## COMMIT: pr-clean-branch-from-main-no-history-bloat` (clean-from-origin/main worktree pattern)
