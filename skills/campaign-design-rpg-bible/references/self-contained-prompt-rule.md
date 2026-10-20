---
# Self-Contained Prompt Rule (added 2026-08-22)

The `/campaign-creation` skill (sibling to this one — see `~/.smartclaw/skills/campaign-creation/SKILL.md`) produces a different artifact: an LLM-paste-ready prompt. When generating that artifact, the Self-Contained rule below applies INSTEAD of the slim/3-place sync / Drive doc sync rules in v1.0–v1.7 of this skill.

## The hard rule

The output of campaign-creation is **an LLM-facing prompt**, not a designer-facing reference document. Therefore it MUST be:

1. **Self-contained.** The AI DM that reads this prompt must NOT need to fetch any external resource. No wiki links, no Google Doc IDs, no GitHub URLs, no "see §X" cross-doc jumps, no "consult the Assiah wiki for full lore" pointers.
2. **No code references.** No Python class names, no module paths, no Flask route strings, no references to the WorldArchitect.AI backend. The prompt names mechanics by player-facing vocabulary (Hidden Apex, Mirror Magic Cascade, Aura suppression, Arcanus-Form).
3. **No external ID references.** No `[CHAR:ID]` lookup calls, no cross-document graph IDs, no campaign-table keys. The character is described by name + role + capabilities, not by database identifier.
4. **Sized for the user.** Default 2,500–4,000 words. Smaller (1,500–2,500) for IP-anchored bibles with simpler mechanics. Larger (4,000–6,000) if the user says "bigger is fine" or "we can make it bigger."

## Why this rule exists

The WorldArchitect.AI AI DM, after parsing the pasted prompt, does **not** execute follow-up fetch calls against external links. An external reference becomes a black box the AI fills with invention. Self-contained prompts are the only ones that produce canon-faithful gameplay on Acts II–V.

Verified 2026-08-22 with the Quiet War bible: live test in WA `pGfqzk2mjPcn8Zsnag9U` (under user `jleechantest@gmail.com`) showed the AI DM correctly honoring **purple wool coat suppresses aura**, **Council 3-2 vote**, **Hook 1 Kelda lineage**, **Hook 4 Hollow Stone crown shard** — all things stated IN the pasted prompt, none fetched.

## When NOT to apply this rule

This rule applies to the `campaign-creation` artifact (paste-ready LLM prompt). The rich drafting document (`campaign-design-rpg-bible` proper) is allowed cross-references because it is the designer's own reference — agents loading it can navigate.

If the user is asking for a slim version of an existing IP bible, follow the existing slim-pass playbook in `campaign-design-rpg-bible`. The Self-Contained rule applies ONLY to "design a campaign" tasks that start with no prior bible.

## Working example

The Quiet War — The Sword Instructor's Hollow Crown (Alexiel Arcanus) is the v1.0 reference implementation:
- **3,093 plain words** in `~/llm_wiki/wiki/sources/quiet-war-slim.md`
- **2,837 plain words** in the Drive doc `11oBduyCd6HsydnWi6YwxDHrwDm4L1VQFCGe0hD8mp04` (Drive strips ~250 words of YAML/HTML comments)
- **Zero** external URLs, **zero** cross-doc refs, **zero** code references.
- §0 canon-assumptions block inlines lineage + family status + source hierarchy.
- §10 still has 8 Continuity Hooks, no Canonical Ending.
- §9 still ends with Freeform as the 4th option.
- Setup Notes block ends with the "Self-contained: this bible has zero external references" declaration.

The phase-3 audit checklist from `~/.smartclaw/skills/campaign-creation/SKILL.md` (5 tests: External URL / External ID / Cross-doc backref / Code reference / Inlining) MUST all pass before the prompt is delivered.
