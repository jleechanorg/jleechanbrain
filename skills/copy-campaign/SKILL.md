---
name: copy-campaign
description: Thin pointer — canonical /copy-campaign workflow lives in the WorldArchitect repo at .claude/skills/copy-campaign/SKILL.md. Twin-copy a production campaign to jleechantest@gmail.com: one read-only baseline + one actionable test subject, parity-verified before handoff.
tags: [copy, campaign, worldarchitect, firestore, twin, baseline, test-subject, hermes-pointer]
changelog:
  - 1.0.0 (2026-08-05) Initial Hermes-side pointer. Mirrors the pattern from `repro` and `repro-twin-clone-evidence` — canonical workflow in the WorldArchitect repo (`${HOME}/repos/jleechanorg/worldarchitect.ai/.claude/skills/copy-campaign/SKILL.md`), Hermes-side pointer here for skill_view() resolution. The canonical skill has the env vars, twin-copy steps, parity-verification recipe, suffix discipline, and the 6 pitfalls (--find-by-id-as-lookup footgun, test-user UID mismatch, suffix drift, parallel-copy race, __pycache__ false-positives, worktree-venv trap).
---

# /copy-campaign (Hermes pointer)

This skill is a **thin pointer**. The canonical source of truth is:

**`${HOME}/repos/jleechanorg/worldarchitect.ai/.claude/skills/copy-campaign/SKILL.md`**

Always read and execute the canonical skill. Do not duplicate logic here.

## When this skill is used

- A Hermes session (Slack, cron, gateway) receives a `/copy-campaign` request
- The user wants a non-destructive copy of a production WA campaign for safe local testing
- A `/repro`, `/repro_copy`, AO worker, or manual turn-by-turn replay needs a clean test subject + read-only baseline

## Firestore credential requirements

Same as `/repro`:

```bash
export WORLDAI_DEV_MODE=true
export GOOGLE_APPLICATION_CREDENTIALS="$HOME/serviceAccountKey.json"
export WORLDAI_GOOGLE_APPLICATION_CREDENTIALS="$HOME/serviceAccountKey.json"
```

`WORLDAI_DEV_MODE=true` is mandatory — `scripts/copy_campaign.py` raises `ValueError` without it.

## Hard rules (do not bypass)

1. **Always twin-copy.** Two independent copies of the same source state. Never a single copy.
2. **Baseline is sacred.** Read-only. Never send an action, edit, or replay to it. If a follow-up workflow needs a control, export the baseline state and diff against the test subject's pre-action state.
3. **Always pair `--find-by-id` with explicit `--dest-email jleechantest@gmail.com --suffix "<text>"`.** `--find-by-id` alone is NOT a safe lookup — it performs a real copy into the source account when `--dest-email` is omitted. (3 footgun incidents in production; see `references/copy-campaign-safety.md` in the canonical repro skill.)
4. **Parity-verify before handoff.** `diff` the `game_state.json` from both copies. Empty diff = twin is valid. Non-empty = redo.
5. **Default destination is `jleechantest@gmail.com`** (UID `0wf6sCREyLcgynidU5LjyZEfm7D2`). Do not write to the source user. Do not write to a non-test user.

## Sibling commands

| Command | When |
|---|---|
| `/copy-campaign` | User wants a safe twin-copy to drive later (this skill) |
| `/repro` | User has a bug report; copy + replay + verdict in one workflow |
| `/repro_copy` | User wants canonical+variant with optional destructive mutation (`scripts/repro_copy_campaign.py`) |
| `~/.smartclaw/skills/download-campaign` | User wants to download to disk only — no copy, no test subject |

## Reference

The canonical twin-copy recipe this pointer wraps is `repro-twin-clone-evidence` §5 ("Twin baseline + test subject") in the WorldArchitect repo. The standalone `copy-campaign` skill is a thinner wrapper with explicit parity-verification — it does NOT run a bug-replay or fill a verdict table; that's `/repro`'s job.