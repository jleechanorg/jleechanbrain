# Case — issue #9133 dice-rolls renders `[object Object]` (Layer 8 sibling render-path gap)

## Bug class

A partial-fix PR adds string coercion / label extraction to ONE render path of a structured field whose backend data shape can be dict-OR-string, but misses the sibling render path that consumes the same field. The symptom then shifts to the unpatched path. The bug class is the **frontend cousin of Layer 1** (LLM-output-side vs audit-event-source drift) — when the backend introduces a new data shape into a field the frontend used to receive as one shape, every frontend consumer needs shape-handling, not just the one the partial-fix PR touched.

## Symptom

User screenshot 2026-08-19T16:45 UTC, campaign `FsiyESY987DF2lfgolCI`, turn 133, dev GCP `mvp-site-app-dev`:

```
🎲 Dice Rolls:
  • [object Object]
  • [object Object]

⚠ System Warnings:
  • Missing action_resolution field (required for player actions)
```

Two warnings in one panel. The `[object Object]` is a JS-side toString fallback on a dict value; the "Missing action_resolution" is the Layer 7 validator-then-recovery + agent-exemption race.

## Evidence — direct from BQ `llm_payloads`

Turn 133, agent = StoryModeAgent, ingested_at = 2026-08-19T16:45:08Z:

- `dice_rolls`: **`[]`** (LLM regression — was empty)
- `dice_audit_events`: **populated with 2 dict entries**:
  - `{notation: "1d20+9", rolls: [12], total: 21, dc: 16, success: true, label: "Masking Resonance"}`
  - `{notation: "1d20+7", rolls: [18], total: 25, dc: 15, success: true, label: "Maintaining Mask"}`
- `action_resolution`: **missing** (LLM regression — same family as #9021 / #9057 / #9114)
- Narrative text correctly describes both rolls

Query that surfaced the evidence:
```bash
cd / && unset PYTHONPATH && bq query --use_legacy_sql=false --project_id=worldarchitecture-ai --format=csv "
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
       turn_index, agent, response_text
FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
WHERE campaign_id = 'FsiyESY987DF2lfgolCI'
  AND turn_index = 133
ORDER BY ingested_at DESC
LIMIT 3"
```

## Root cause — two independent fixes, one PR-or-two

### Fix A (5 lines, frontend-only): coerce dict → string in `app.js:1713`

`mvp_site/frontend_v1/app.js:1710-1716`:
```js
html += '<div class="dice-rolls">';
html += '<strong>🎲 Dice Rolls:</strong><ul>';
diceRollsToShow.forEach((roll) => {
  html += `<li>${sanitizeHtml(roll)}</li>`;  // ← stringifies dict as [object Object]
});
html += '</ul></div>';
```

Fix shape:
```js
const _rollText = (r) => {
  if (typeof r === 'string') return r;
  if (!r || typeof r !== 'object') return String(r ?? '');
  const core = [r.roll, r.result].filter((x) => x != null).join(' = ');
  const lbl = r.label || r.purpose || r.type;
  return core + (lbl ? ` (${lbl})` : '');
};
// then in the forEach:
html += `<li>${sanitizeHtml(_rollText(roll))}</li>`;
```

Contract test in `mvp_site/tests/frontend/test_dice_rolls_dict_render.js`:
```js
import { test } from 'node:test';
import { renderDiceRollsPanel } from '../frontend_v1/dice_panel_extract.js';

test('dice-rolls panel does NOT emit [object] for dict rolls', () => {
  const html = renderDiceRollsPanel([
    { roll: '1d20+9', result: 21, label: 'Masking Resonance' },
    { roll: '1d20+7', result: 25, label: 'Maintaining Mask' },
  ]);
  assert.match(html, /<li>1d20\+9 = 21 \(Masking Resonance\)<\/li>/);
  assert.doesNotMatch(html, /\[object /);
});
```

### Fix B (Layer 7): PR #9132 agent exemption + warning prune

`PR #9132` (`fix/action-resolution-warning-agent-exempt-9114`) ships:
- `mvp_site/agents.py:2870` DialogAgent override (`requires_action_resolution=False`, inherited by HeavyDialogAgent + SpicyModeAgent)
- `mvp_site/agents.py:3360` FactionManagementAgent override
- `mvp_site/action_resolution_utils.py:962` prune stale "Missing action_resolution" warning after recovery
- `mvp_site/llm_parser.py:639` symmetric prune in streaming path
- 2 new tests in `test_action_resolution_utils.py`

**STATUS CORRECTION as of session-end 2026-08-19:** PR #9132 is **state=OPEN, merged_at=null**. NOT on origin/main. Deployed revision `mvp-site-app-dev-04527-dvr` is on commit `6b7377c` (pre-#9132). Verify with:
```bash
gh pr view 9132 --repo jleechanorg/worldarchitect.ai --json state,mergedAt
gcloud run revisions list --service=mvp-site-app-dev --region=us-central1 --project=worldarchitecture-ai --limit 1 --format="table(metadata.name,metadata.labels.commit-sha)"
```

## Detection recipe — when to suspect this bug class

The user reports a literal JS-side string in the rendered UI (`[object Object]`, `[object HTMLDivElement]`, `[object Array]`, etc.). NOT a regex/LLM pattern, NOT a console error.

Before grepping code:

1. `git log --oneline -10 -- mvp_site/frontend_v1/app.js` to find recent partial-fix PRs in the same file
2. `grep -rn "renderDiceRoll\|diceRolls\.forEach\|forEach.*roll" mvp_site/frontend_v1/` to enumerate sibling loops
3. For each partial-fix candidate, grep the diff for terms like `label`, `coerce`, `String(`, `rollText` — these signal a coercion site that might not span sibling paths
4. Search the file for `sanitizeHtml(<varname>)` where `<varname>` is the loop iterator (`roll`, `item`, `entry`, `r`) in any other branch

Diagnostic test for the recovery shape:
```bash
# Did the partial-fix PR change the render but not all consumers?
git -C <repo> show <partial_fix_merge_commit> -- app.js | grep -E '^-.*sanitizeHtml|^\+.*sanitizeHtml'
```

## Why two PRs, not one

- Fix A is ~5 lines + 1 contract test in `app.js` — independent of Fix B
- Fix B (PR #9132) is already authored but unmerged; rebasing Bug A onto it just shifts the merge conflict set without saving work
- If the operator chooses "drive PR #9132 to green + add Bug A as a second commit", the merge-base stays clean

## Why this is Layer 8 (not Layer 1, Layer 4, or Layer 6)

- **Not Layer 1 (LLM-output-side vs audit-event-source):** the bug is JS-side toString, not an LLM regression (the LLM correctly omitted `dice_rolls[]` because it's an LLM regression, but the rendered `[object Object]` is downstream of that — the backend backfilled the audit into `dice_rolls[]` as dicts, and the frontend forEach did not coerce)
- **Not Layer 4 (aggregate compliance):** this is a single-turn, single-component, single-campaign issue — not a statistical sampling question
- **Not Layer 6 (JS-side CSS-hook-attribute drop):** Layer 6 is about a bot review's "X is unchanged" summary missing a render-site change. Layer 8 is about a **human-author's** "fixed the symptom" PR missing a render-site sibling
- All three layers share the diagnostic: "when reviewing a render function, enumerate ALL sibling render paths" — but the cause differs (bot review hallucination vs. human-author partial PR)

## Cross-references

- Layer 7 (`references/case-pr-9132-agent-exempt-validator-recovery-2026-08-19.md`) — companion fix; still OPEN
- Layer 6 (`references/case-pr-9104-css-hook-data-risk-drop.md`) — cousin case on the bot-review path
- Layer 1 (this skill's "The 3-layer false-green guard" → Layer 1) — the LLM-output-side vs audit-event-source distinction this Layer 8 case complements
- `mvp_site/structured_fields_utils.py:29-114` — `backfill_dice_rolls()` is the source of the dict shape that the frontend must coerce
- `mvp_site/narrative_response_schema.py:3413-3536` — validator that fires the "Missing action_resolution" warning
- `mvp_site/world_logic.py:10368` — `add_action_resolution_to_response` is the downstream recovery that PR #9132 throttles
