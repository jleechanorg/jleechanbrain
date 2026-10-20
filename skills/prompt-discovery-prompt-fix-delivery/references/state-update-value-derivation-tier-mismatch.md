# State-update value-derivation drift — tier-mismatch sub-class

**Bug sub-class:** 8th sub-class of `npc-status-persistence-bug` taxonomy
(verified 2026-08-15 on jleechanorg/worldarchitect.ai issue #8949 / PR #8950,
campaign `7HHDMPe0wNLBDTfymzfT` "noctune Warcraft 3", turn 29, 2026-08-16T01:15:45Z).

**Signature distinction (vs. the 7th sub-class pure value-drift):**

| Sub-class 7 (pure value drift) | Sub-class 8 (tier mismatch) |
|---|---|
| Field name + type correct, but numeric value drifts between narrative-computation and structured-transcription | Field path + source enum correct, but tier-selection wrong from a multi-tier decision tree |
| Same single-tier rule applies; LLM miscomputes the number | Multiple tiers exist in the rule; LLM picks the wrong tier |
| Fix: add value-derivation block in prompt | Fix: add tier-trigger vocabulary + worked example |

**Verified worked example:**

Campaign `7HHDMPe0wNLBDTfymzfT` (noctune Warcraft 3), player acquired Frostmourne.
LLM response at turn 29 (2026-08-16T01:15:45Z, HeavyDialogAgent, `mode: character`):

```json
"rewards_box": {
  "source": "milestone",
  "source_id": "frostmourne_delink_complete",
  "xp_gained": 900,           // ~10% of L6 band — tier-1
  "current_xp": 21400,
  "next_level_xp": 23000,
  "gold": 0,
  "loot": ["Frostmourne (De-Linked & Sovereign Bound)"]
}
```

Player god-mode-escalated at turn 30 (01:18:51Z, `mode: god`): "Give me proper new powers and abilities and massive exp for getting frostmourne". LLM correctly emitted `xp_gained: 15000.0` + L6→L8 level-up. Same event, different tier — proving tier-2 exists in the rule but the in-character turn picked tier-1.

**BQ diagnostic recipe (3 sub-checks, all must pass):**

```sql
-- 1. Confirm the rule WAS in the served prompt at the offending turn
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
       agent,
       turn_index,
       LENGTH(request_json) AS req_bytes,
       SUBSTR(CAST(request_json AS STRING), 1, 400) AS req_head
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id = '<CID>'
  AND ingested_at BETWEEN TIMESTAMP('<BEFORE_TS>') AND TIMESTAMP('<AFTER_TS>')
  AND agent IN ('GodModeAgent','HeavyDialogAgent','StoryModeAgent')
ORDER BY ingested_at ASC
```

Then for the offending turn (req_bytes > 100KB):
```python
import json, re
data = json.loads(open('/tmp/<turn>.json').read())
req = data[0]['request_json']
resp = data[0]['response_text']
for needle in ['milestone', 'significant accomplishment', '8–12%', '25–35%', 'Quest milestone']:
    offsets = [m.start() for m in re.finditer(re.escape(needle), req, re.IGNORECASE)]
    pct = [round(o / len(req) * 100, 1) for o in offsets]
    print(f'  "{needle}": {len(offsets)} hits at offsets {offsets[:5]} ({pct[:5]}%)')
# Verify response did emit the right field path + source enum:
for needle in ['rewards_box', 'xp_gained', 'source', 'milestone']:
    print(f'  RESP "{needle}": {len(re.findall(re.escape(needle), resp, re.IGNORECASE))} hits')
```

**Three-pass gate to confirm tier-mismatch (NOT value-drift):**

1. Rule was in the served prompt at the offending turn (condition 5 sub-checks pass — `milestone`, `8–12%`, `25–35%` all present at non-trivial offsets).
2. LLM correctly wrote the structured field path AND source enum (`rewards_box.source = "milestone"` + `source_id` + `loot` all populated).
3. LLM's tier selection was below the user's escalation reference — i.e., the user god-mode-reinforced to N× the in-character award for the same event, proving a higher tier exists in the prompt.

If all three pass, the fix IS a prompt-content patch (`prompt-discovery-prompt-fix-delivery` Phase 0 condition 6). The patch shape is **trigger-phrase vocabulary + worked example**, NOT new tier definitions.

**Fix shape (4-component deliverable, mirrored from PR #8950):**

1. New `## Milestone Tier Classification` section in `mvp_site/prompts/narrative_system_instruction.md` with explicit tier-2 trigger-phrase table:
   - multi-stage ritual / ceremony / procedure the player prepared across multiple turns
   - severed / broken / transformed binding relationship from earlier scenes
   - closed multi-session expedition arc spanning several travel / hazard scenes
   - acquired major artifact / title / rank / domain the player worked toward across multiple scenes
2. Generic worked example using ONLY generic placeholders — no campaign vocabulary.
3. Anti-pattern note explicitly contrasting tier-1 ceiling (one turn ≠ full level) vs tier-2 ceiling (player earned arc resolution across multiple sessions).
4. Mirror `## Reward Tier Selection` section in `mvp_site/prompts/rewards_system_instruction.md` (≤12 lines, pointer to canonical table).

**Contract test pattern (from PR #8950):**

```python
import unittest
from pathlib import Path

# Walking-up resolver — no hard-coded repo path
PROMPTS_DIR = Path(__file__).resolve().parents[1] / "prompts"
NARRATIVE_PATH = PROMPTS_DIR / "narrative_system_instruction.md"
REWARDS_PATH = PROMPTS_DIR / "rewards_system_instruction.md"

BANNED_CAMPAIGN_TERMS = [
    "frostmourne", "warcraft", "lich king", "arthas", "stormwind",
    "malganis", "mal'ganis", "nocture", "nocture ravencrest",
    "house ravencrest", "northrend", "lordaeron", "dalaran",
    "kirin tor", "silver hand", "nathrezim", "dreadlord", "dreadlords",
]

class MilestoneTierClassificationNarrativeTests(unittest.TestCase):
    def test_heading_present(self):
        content = NARRATIVE_PATH.read_text(encoding="utf-8")
        self.assertIn("## Milestone Tier Classification", content)

    def test_subheading_tier2_trigger_vocabulary_present(self):
        content = NARRATIVE_PATH.read_text(encoding="utf-8")
        self.assertIn("### Tier-2 Trigger Vocabulary (multi-session arc resolution)", content)

    def test_all_four_tier2_trigger_bullets_present(self):
        content = NARRATIVE_PATH.read_text(encoding="utf-8").lower()
        self.assertIn("multi-stage ritual", content)
        self.assertIn("severed binding", content)  # or whatever the bullet names
        self.assertIn("completed expedition arc", content)
        self.assertIn("acquired major artifact", content)

    def test_worked_example_section_present(self):
        content = NARRATIVE_PATH.read_text(encoding="utf-8")
        self.assertIn("### Worked Example (generic, setting-agnostic)", content)

    def test_decision_tree_still_present(self):
        # Regression guard — the fix must not break the existing tier-1 branch
        content = NARRATIVE_PATH.read_text(encoding="utf-8")
        self.assertIn("Event significance?", content)
        self.assertIn("~8–12% of band", content)
        self.assertIn("~25–35% of band", content)

    def test_no_banned_campaign_vocabulary_leaked(self):
        for path in (NARRATIVE_PATH, REWARDS_PATH):
            content = path.read_text(encoding="utf-8").lower()
            for term in BANNED_CAMPAIGN_TERMS:
                self.assertNotIn(term, content, f"{term} leaked into {path.name}")
```

8 tests like this are the canonical contract for any tier-classification fix.

**Anti-pattern (do NOT do this):**

Hardcoding campaign-specific vocabulary (Frostmourne, Warcraft, Lich King, etc.) in the trigger-phrase table. This violates `mvp_site/prompts/AGENTS.md` setting-agnostic enforcement and reproduces the same bug-class on a different campaign. The trigger-phrase vocabulary MUST use generic structural signatures (multi-stage ritual / severed binding / completed expedition arc / acquired major artifact) so the LLM translates to any setting automatically.

**Cross-reference:**

- `prompt-discovery-prompt-fix-delivery` SKILL.md — Phase 0 condition 6 verify-the-wrong-tier gate
- `repro` skill changelog 4.1.0 — original value-derivation drift sub-class
- PR jleechanorg/worldarchitect.ai#8950 — first verified fix for tier-mismatch sub-class
- Issue jleechanorg/worldarchitect.ai#8949 — original bug report
- `mvp_site/prompts/AGENTS.md` — setting-agnostic + banned-entity rules
