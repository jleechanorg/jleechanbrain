# Companion diagnostic to Factor I — "LLM correctly enforces contract, user reports a bug that isn't one" (2026-08-16)

## When to load this reference

Load this AFTER Step 0.77 confirmed the directive IS in the served prompt AND the
LLM is enforcing the contract — and yet the user is reporting a "bug." This is
the mirror class of Factor I: instead of the LLM leaking forbidden content
across frames (Factor I), the LLM fully enforces the canonical contract
(`narrative=""` empty, `god_mode_response` carries admin output) but the user's
perception of the output is "wrong" — typically because one of three non-bug
interpretations applies.

## Verified worked example (canonical case)

- Campaign: `7HHDMPe0wNLBDTfymzfT` ("noctune Warcraft 3")
- User /repro directive (verbatim, 2026-08-16):
  > *"whenever the god mode text is the same as the narrative let's just replace the narrative text and say something generic like 'god mode turn — no narrative'"*
- BQ row at the time (`worldarchitecture-ai.llm_forensics.llm_payloads`, agent=`GodModeAgent`, turn_index=30, `2026-08-16T01:46:21Z`):
  ```json
  {
    "narrative": "",
    "session_header": "[SESSION_HEADER]...",
    "god_mode_response": "Administrative Update: Companion level scaling protocol established...",
    "state_updates": { "npc_data": { "Lyra Moon-Whisper": { "level": 6 } } },
    "directives": { "add": ["Companions must always scale to maintain a minimum level of 2 levels below the player character..."] }
  }
  ```
- `narrative=""` IS enforced. LLM-side gate is correct.
- Bead: `rev-noctune-narrative-dup-3rd-sibling-pj83v` (3rd sibling on this campaign, fire-and-hold pattern).

## The 4-interpretation disambiguation menu

When this class fires, post ONE menu of the 4 interpretations (do NOT pick a fix direction first):

1. **Frontend UI render leak** — `god_mode_response` text shown in a region labelled "narrative" on the browser. Visible only via Playwright DOM capture, not in `llm_payloads`. Verify by headless screenshot + DOM-region text grab BEFORE patching `frontend_v1/`.
2. **Old-session recall** — pre-PR #8594 (2026-08-14) sessions on this campaign could have leaked narrative text. The user may be generalizing from a session that no longer reflects current behavior. Cross-reference prior session exports in `/tmp/worldarchitect.ai/repro-exports/`.
3. **Design preference** — user wants literal `narrative=""` swapped for string `"[God Mode turn — no narrative]"`. That is a frontend render change, NOT a prompt/LLM change. Confirm with the user before patching `frontend_v1/`.
4. **Real, unproven regression** — PR #8594 was reported **UNPROVEN** by `rev-9ffb6` HANDOFF (2026-07-25): *"the defect does not reproduce on a fresh campaign, so the trigger is session accumulation rather than input, and the fix may do nothing."* Long-campaign RED replay per `mvp_site/tests/test_god_mode_translate_never_refuse.py` (n≥4 sequential god-mode turns on a long-running campaign) confirms the defect.

Do NOT propose a prompt-layer fix without user confirmation of interpretation 4. The same anti-pattern as Factor G (changelog 2.9.0, #8498) — adding noise, not fixing anything, deferring the real bug.

## Mandatory pre-fix check (1 BQ query)

```sql
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
       turn_index,
       response_text
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id = '<CID>'
  AND agent = 'GodModeAgent'
  AND LENGTH(response_text) > 100
ORDER BY ingested_at DESC
LIMIT 1
```

Grep `response_text` for `"narrative": ""`. If present, the LLM-side gate is enforced. STOP. Post the 4-interpretation menu. Wait for user clarification.

## Diff vs Factor I

Factor I = "rule delivered, LLM honors in one frame, leaks in others" — scope defect inside the LLM response. Verdict: bug class is scope, prompt-layer fix shape.
This reference = "rule delivered, LLM fully enforces the contract, user thinks it doesn't" — perception/UI defect outside the LLM response. Verdict: NOT a prompt-layer bug.

Both are diagnostic-row additions to the Factor-A-through-I matrix. The new row:

| Diagnostic observation | Verdict |
|---|---|
| Contract-holding shape present in `response_text` (e.g. `narrative=""`, `directives.add` populated, `state_updates.npc_data.*.level` written) AND user reports the same content as a "bug" | **NON-BUG — disambiguate via 4-interpretation menu** (this reference) |
| Contract-holding shape absent | **LLM not enforcing — run Step 0.77 + Factor-A-through-H matrix first** |

## Cross-references

- `references/god-mode-directive-missing-subclasses.md` — Factor A through H matrix that this reference complements.
- `references/state-update-value-derivation-drift.md` and `references/state-update-value-derivation-tier-mismatch-2026-08-16.md` — companion value-derivation classes.
- `references/non-repro-verification-recipe.md` — covers a related pattern (LLM-forgot-NPC-was-dead → user-misread), same disambiguation shape.
- PR #8594 commit `2401bd7309d15546fc932757d82a5b0398088cd6` (2026-08-14) — added `## Translate, Never Refuse (Mandatory Protocol)` to `mvp_site/prompts/god_mode_instruction.md:23-32`. In `origin/main` HEAD `a9e552a1507f1ccaec50249284f5c34f9be89635`.
- Memory entry from 2026-08-16 on the production `narrative=""` contract.
