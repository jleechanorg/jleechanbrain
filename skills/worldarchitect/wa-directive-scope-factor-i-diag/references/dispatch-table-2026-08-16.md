# Trigger-phrase dispatch table — when to load `god-mode-contract-already-enforced-2026-08-16.md`

## Purpose

When an agent is processing a `/repro` request OR a user-message that
matches the NON-BUG companion class, this table is the fast-path
dispatcher. Grep the user's literal text against the trigger phrases
below; if any match, load the companion reference IMMEDIATELY rather
than re-deriving the diagnosis from scratch.

## When to load this dispatch table

Load when ANY of:

1. User invokes `/repro <URL>` and the live symptom matches any trigger phrase below.
2. Agent is about to start Step 0.75 (bug phenotype capture) on a god-mode-related
   symptom — instead, run the 4-interpretation menu first.
3. User message contains a directive phrasing that sounds like a fix request but
   maps to the already-enforced contract — STOP and post the menu.

## Trigger phrases (verbatim, from observed user messages)

| User said (verbatim or close paraphrase) | Class | Action |
|---|---|---|
| *"god mode text same as narrative"* / *"god-mode text == narrative"* / *"duplicate god mode narrative"* | NON-BUG | Load companion reference, post 4-interpretation menu |
| *"replace narrative text with generic"* / *"say something generic like god mode turn — no narrative"* | NON-BUG (design preference) | Load companion reference; option 3 in 4-interpretation menu is the user's stated design |
| *"no narrative turn"* / *"no narrative"* / *"empty narrative"* | NON-BUG (UI render or old-session recall) | Load companion reference; check `_combine_god_mode_and_narrative` first |
| *"god mode answered with generic 'Administrative Update' filler"* | NON-BUG (covered by PR #8594 already) | Load companion reference; cite PR #8594 `2401bd7309` |
| *"the LLM ignores my directive in god mode"* (verbatim phrasing) | LIKELY Factor F/H/G | Load `references/god-mode-directive-missing-subclasses.md` first, then come back to this if contract is held |
| *"narrative contains the same text as god_mode_response"* | NON-BUG (mirror phrasing) | Same row as "duplicate god mode narrative" |

## The 4-interpretation menu (canonical disambiguation)

When ANY trigger fires, post the menu verbatim (do NOT pick a fix direction first):

1. **Frontend UI render leak** — `god_mode_response` text shown in a region
   labelled "narrative" on the browser. Visible only via Playwright DOM
   capture, not in `llm_payloads`. Verify by headless screenshot + DOM-region
   text grab BEFORE patching `frontend_v1/`.

2. **Old-session recall** — pre-PR #8594 (2026-08-14) sessions on this
   campaign could have leaked narrative text. The user may be
   generalizing from a session that no longer reflects current behavior.
   Cross-reference prior session exports in `/tmp/worldarchitect.ai/repro-exports/`.

3. **Design preference** — user wants literal `narrative=""` swapped for
   string `"[God Mode turn — no narrative]"`. That is a frontend render
   change, NOT a prompt/LLM change. Confirm with the user before patching
   `frontend_v1/`.

4. **Real, unproven regression** — PR #8594 was reported **UNPROVEN** by
   `rev-9ffb6` HANDOFF (2026-07-25). Long-campaign RED replay per
   `mvp_site/tests/test_god_mode_translate_never_refuse.py` (n≥4 sequential
   god-mode turns on a long-running campaign) confirms the defect.

**Do NOT propose a prompt-layer fix without user confirmation of interpretation 4.**

## Mandatory pre-fix check (1 BQ query)

```sql
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
       turn_index, response_text
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id = '<CID>'
  AND agent = 'GodModeAgent'
  AND LENGTH(response_text) > 100
ORDER BY ingested_at DESC LIMIT 1
```

Grep `response_text` for `"narrative": ""`. If present, the LLM-side gate is enforced. STOP. Post the 4-interpretation menu. Wait for user clarification.

## Why this dispatch table exists (2026-08-16)

Without this table, agents re-derive the diagnosis from scratch each time
they encounter this symptom class. Verified on campaign
`7HHDMPe0wNLBDTfymzfT` (noctune Warcraft 3) — the user's verbatim
trigger phrase ("god mode text same as narrative / replace narrative
text with generic") appeared in Slack thread `C0BDEAJH8PK / 1786844858.028199`
and the agent ran a full /repro pipeline (memory fan-out + bead
creation + BQ query) before discovering this reference existed.
Adding this dispatch table saves the next agent 8-12 tool calls and
the user a 10-15 minute wait.

## Cross-references

- `references/god-mode-contract-already-enforced-2026-08-16.md` —
  the 4-interpretation menu lives there.
- PR #8594 commit `2401bd7309` (2026-08-14) — added the
  `## Translate, Never Refuse (Mandatory Protocol)` section to
  `mvp_site/prompts/god_mode_instruction.md:23-32`.
- Bead `rev-noctune-narrative-dup-3rd-sibling-pj83v` (P2, open,
  2026-08-16) — 3rd sibling cluster trigger on
  `7HHDMPe0wNLBDTfymzfT`; this dispatch table was created as
  part of that triage.