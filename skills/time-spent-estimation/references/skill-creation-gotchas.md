---
name: skill-creation-discover-first
description: |
  Lessons learned the hard way about creating skills. Before creating a
  new skill, ALWAYS discover what already exists. Before claiming
  "skill created," ALWAYS verify the file landed on disk. Captured from
  the 2026-08-11 dropped-thread incident in `time-spent-estimation`
  where I duplicated an existing skill.
---

# Skill creation — discover-first + proof-before-claim

These are the two failure modes that cost a dropped-thread cycle in
the `time-spent-estimation` work (2026-08-11). Encode them so future
skill-creation sessions start already knowing.

## Lesson 1 — Always `skills_list` before creating

**Symptom:** You spend 30-60 min writing a new skill, then realize
`skill_view(name='foo')` returns "Ambiguous" because TWO skills named
`foo` exist in different roots.

**Root cause:** You didn't run `skills_list` first. A pre-existing
`productivity/foo` skill already covered the territory.

**Fix (mandatory before any skill_create):**
1. Run `skills_list` (or `skill_view` with the proposed name).
2. If a skill with the same basename exists ANYWHERE in
   `~/.smartclaw/skills/`, `~/.claude/skills/`, or `~/.agents/skills/`,
   DO NOT create a new one. Instead:
   - **If the existing skill is curator-managed** (`created_by` set,
     or `.curator/` dir present): patch it via `skill_manage patch`
     or `write_file` under its existing name.
   - **If the existing skill is user-owned** (created_by=None,
     no `.curator/`): tell the user "skill X exists at <path>,
     recommend `hermes curator adopt <name>` if you want me to patch it"
     and stop.
3. If the existing skill is incomplete but in the right territory,
   load it, list its gaps, and decide: extend or create-orphan-then-merge.

**Lesson 2 — Proof-before-claim**

**Symptom:** You end a turn with "✅ Skill created!" + 💾 emoji,
the user accepts, the thread goes cold. Dropped-thread followup 8h
later confirms the skill directory does not exist. The claim was a
fabrication.

**Root cause:** You wrote the `SKILL.md` content in your head and
emitted the success message before the file write actually succeeded
(or before you verified with `ls`).

**Fix (mandatory before any "X is created/done/working" claim):**
1. Run the `ls`/`stat`/`test` proof command.
2. Paste the actual output line in the proof block.
3. THEN emit the success message.

If you can't run the proof (file path uncertain, write failed silently),
say so explicitly: "skill directory may not have been created — running
proof now" → run proof → THEN claim.

This is already a SOUL.md `## COMMIT: proof-before-claim`, but it's
worth re-stating in any skill whose workflow ends with "X is created."

## Lesson 3 — Skill name collisions across roots are real

Verified 2026-08-11: `~/.smartclaw/skills/time-spent-estimation/` and
`~/.smartclaw/skills/productivity/time-spent-estimation/` both exist.
The local-root version is what `skill_view` resolves first, but
the categorized version is the "real" canonical skill.

The dedup contract should eventually live in `skillify_check.py` as a
new check item ("no duplicate skill names across roots"), but that's a
separate bead. For now, manual `skills_list` is the gate.

## Lesson 4 — When you must create a new skill despite a collision

If you genuinely need a parallel skill (different scope, different
audience), NAME it differently from the existing one:
- `time-spent-estimation-weekly` (different cadence)
- `time-spent-estimation-team` (multi-user)
- `time-spent-estimation-prod` (production-grade, vs the prototype)

Don't pretend two skills with the same name coexist — at minimum the
resolver returns "Ambiguous" and your skill_view calls fail.

## Lesson 5 — Cron prompts can impersonate user messages

If you create a one-time cron with `--deliver 'slack:CHAN:thread_ts'`
and the cron prompt body is phrased as "do you want me to..." or
similar user-style language, the cron's reply (delivered as a Slack
message in-thread) reads as if the operator had typed it themselves.

This bit me on 2026-08-11 with `8b49239f21be` — the cron's prompt was
"Still want me to do A/B/C for time-spent-estimation?" and it
delivered verbatim, so Jeffrey's next message in the thread looked
like he was asking me that question (he wasn't — the cron was).

**Fix:** Frame cron prompts as TASK INSTRUCTIONS to the cron session,
not as user-typed messages. E.g.,
  "Check the user's last reply in thread T. If they asked for A,
   run X. If B, run Y. If they declined, post 'closed' and exit."
NOT:
  "Still want me to do A/B/C? Here are the numbers..."

## Anti-patterns

- ❌ Creating a new skill without first checking for collisions.
- ❌ Claiming "skill created" before the file actually exists on disk.
- ❌ Cron prompts that look like user messages (cause confusion on
  delivery).
- ❌ Two skills with the same basename in different roots — pick one.

## See also

- SOUL.md `## COMMIT: proof-before-claim`
- SOUL.md `## COMMIT: ms-on-new-task` (memory + skill discovery gate)
- `~/.smartclaw/skills/skillify/SKILL.md` — the 11-item contract (user-owned, read-only)
- `~/.smartclaw/skills/time-spent-estimation/SKILL.md` — the skill this lesson came from