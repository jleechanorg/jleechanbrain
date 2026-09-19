# case — PR #9132: agent exemption matrix gap + validator-then-recovery race (issue #9114)

**Date:** 2026-08-19
**Reported via:** Slack `#worldai-bugs` C0BDEAJH8PK (this thread)
**Live URL (operator evidence):** https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/game/29l48q6zFo7chxWnyjEY
**PR context:** [#9132](https://github.com/jleechanorg/worldarchitect.ai/pull/9132) "fix(action_resolution): suppress warning for non-player-action agents + prune stale recovery" — MERGED state target, worktree at `${HOME}/.worktrees/worldarchitect.ai/fix-ar-warning-agent-exempt`
**Operator hypothesis (partially wrong, partially right):** "dice rolls are no longer in action_resolution and instead are in the code execution record field and the code hasn't been updated"

## Symptom

Operator saw live UI warning: `System Warnings: Missing action_resolution field (required for player actions)` on campaign `29l48q6zFo7chxWnyjEY` ("bg3 nocturne murder god v2"). Screenshot showed: Persuasion/Reassure Uther `1d20+14 = 15 vs DC 18 Failure` roll, level-up to Level 14, Sneak Attack 7d6, code execution confirmed via the dev GCP URL.

## First sweep (mistake)

Initial cross-campaign Firestore sweep across the **5 most-active** recent campaigns (operator's `last 14 days`, ≥50 entries filter) showed:

```
nocturne warcraft 3 (failed req no planning b)     ar_present=29 ar_null=0 warn=0 code_exec=22
nocturne warcraft 3                              ar_present=29 ar_null=0 warn=0 code_exec=22
nocturne warcraft 3 (code loop)                  ar_present=29 ar_null=0 warn=0 code_exec=22
bg3 nocturne murder god v2 (29l48q6zFo7chxWnyjEY) ar_present=30 ar_null=0 warn=0 code_exec=14
                                                  ---
                                              TOTALS: ar_present=117 ar_null=0 warn=0 code_exec=80
```

I concluded "the validator was working correctly even on code-execution turns" and reported "No warnings fire on any recent turn." Operator immediately replied with the campaign URL + screenshot showing the warning LIVE — on `29l48q6zFo7chxWnyjEY`, which I'd already swept.

The problem: my sweep tabulated `warn_fired` by checking `any('Missing action_resolution' in str(w) for w in warnings)` — but **the same campaign where I saw 0 warnings had warnings firing**. Re-running the sweep on just that campaign with verbose per-agent breakdown surfaced the bug:

## Targeted sweep (correct)

Same campaign, last 43 LLM entries, cross-tabulate by `debug_info.agent_name`:

| Agent | Total | Warning fired |
|---|---|---|
| GodModeAgent | 11 | 0 (0.0%) |
| PlanningAgent | 8 | 0 |
| CharacterCreationAgent | 3 | 0 |
| LevelUpAgent | 1 | 0 |
| SpicyModeAgent | 1 | 0 |
| **DialogAgent** | **9** | **7 (77.8%)** |
| **HeavyDialogAgent** | **5** | **3 (60%)** |
| **StoryModeAgent** | **4** | **3 (75%)** |
| **FactionManagementAgent** | **1** | **1 (100%)** |

**Total: 14/43 (32.6%) warning rate.**

Every warning-firing entry had `action_resolution` populated AND `code_execution_used=True` AND `dice_audit_events` non-empty:

```python
# Sample entry: campaign 29l48q6zFo7chxWnyjEY, ts=2026-08-19 09:54:44Z, DialogAgent
{
  "action_resolution": {
    "mechanics": {"rolls": [
      {"dc": 18, "rolls": [9], "total": 19, "label": "Dexterity (Thieves' Tools) to bypass magical seal", "modifier": 10, "success": true, "notation": "1d20+10"},
      {"dc": 15, "rolls": [2], "total": 2, "label": "Intelligence (Investigation) to decode Blackstaff cipher", "modifier": 0, "success": false, "notation": "1d20+0"}
    ]},
    "reinterpreted": false,
    "audit_flags": []
  },
  "dice_audit_events": [
    {"dc": 18, "rolls": [9], "total": 19, "label": "...Thieves' Tools...", "source": "code_execution", "modifier": 10, "success": true, "notation": "1d20+10"},
    {"dc": 15, "rolls": [2], "total": 2, "label": "...Investigation...", "source": "code_execution", "modifier": 0, "success": false, "notation": "1d20+0"}
  ],
  "dice_rolls": [],
  "debug_info": {
    "agent_name": "DialogAgent",
    "llm_model": "gemini-3-flash-preview",
    "code_execution_used": True,
    "executed_code": "...full python with random.seed + dex_roll/int_roll + json.dumps...",
    "stdout": "{...thieves_tools_check...investigation_check...}",
    "rng_verified": True,
    "dice_seed_verified": True,
    "cache_hit_rate_pct": 49.4,
    "prompt_tokens": "***",
    "_server_system_warnings": [
      "Missing action_resolution field (required for player actions)"
    ]
  }
}
```

The LLM's structured response on DialogAgent turns is `{"narrative": "...", "planning_block": {...}, "dice_audit_events": [...], "state_updates": {...}}` — no `action_resolution` key, because DialogAgent loads NARRATIVE_LITE which does not anchor the schema. The validator fires; the warning goes into `debug_info._server_system_warnings`. THEN downstream code (`add_action_resolution_to_response` at `world_logic.py:10368`) reads `dice_audit_events` and synthesizes an `action_resolution` dict from those audit events, copying it into `unified_response["action_resolution"]`. The warning is never cleared.

The Firestore story entry doc persists the warning forever — every UI reload shows it.

## Root cause (two bugs)

### Bug 1: Agent exemption matrix missing DialogAgent + FactionManagementAgent

```bash
grep -B1 -A4 "requires_action_resolution" mvp_site/agents.py
```

Existed: GodModeAgent (1529), CharacterCreationAgent (1790), LevelUpAgent (1985), PlanningAgent (2086), InfoQueryAgent (2188), RewardsAgent (2461), CampaignUpgradeAgent (3639).

Missing: **DialogAgent** (line 2790) — and HeavyDialogAgent + SpicyModeAgent inherit from it.

Missing: **FactionManagementAgent** (line 3211).

DialogAgent loads `narrative_lite_system_instruction.md` (9KB, lightweight mechanics) — no `action_resolution` schema anchor. FactionManagementAgent loads `faction_management_instruction.md` — no `action_resolution` schema anchor. Both legitimately don't emit the field, but inherit `_requires_action_resolution=True` from `_BaseAgent` (which defaults to True).

### Bug 2: Validator-then-recovery race

Validator fires at construction time (`narrative_response_schema.py:3413`):
```python
if action_resolution is None:
    if not is_exempt:
        # Add "Missing action_resolution field" to debug_info._server_system_warnings
        ...
    return {}
```

Recovery happens later in `action_resolution_utils.py:912` (`add_action_resolution_to_response`):
```python
action_resolution = getattr(structured_response, "action_resolution", None)
if action_resolution is not None:
    action_resolution_dict = action_resolution
    unified_response["action_resolution"] = action_resolution_dict
```

`unified_response["action_resolution"]` gets populated — but `unified_response["debug_info"]["_server_system_warnings"]` is NOT cleared. The warning persists to Firestore and surfaces on every UI load.

## Fix shipped (PR #9132)

### Part 1: agent exemption (Bug 1)

```python
# mvp_site/agents.py DialogAgent (line ~2870)
@property
def requires_action_resolution(self) -> bool:
    """Dialog mode is for NPC conversation and does not require action_resolution audit trails.

    The DialogAgent loads NARRATIVE_LITE (9KB), not the full narrative system
    instruction, so its LLM does not have the schema anchor for
    action_resolution. Validator must not fire the "Missing action_resolution"
    warning on DialogAgent turns; downstream code recovers dice rolls from
    dice_audit_events / code_execution_stdout when needed.
    """
    return False
```

HeavyDialogAgent + SpicyModeAgent inherit this — automatic coverage.

```python
# mvp_site/agents.py FactionManagementAgent (line ~3360)
@property
def requires_action_resolution(self) -> bool:
    """Faction management is administrative and does not require action_resolution audit trails.
    ...
    """
    return False
```

### Part 2: stale-warning prune on recovery (Bug 2)

```python
# mvp_site/action_resolution_utils.py (line ~962)
if action_resolution_dict:
    normalize_action_resolution_rolls(action_resolution_dict)
    if mechanics_hidden:
        apply_narrative_outcome(action_resolution_dict, enabled=True)

    # Clear stale "Missing action_resolution" warning when the validator fired
    # before downstream code populated action_resolution from
    # dice_audit_events / code_execution_stdout.
    debug_info = unified_response.get("debug_info")
    if isinstance(debug_info, dict):
        server_warnings = debug_info.get("_server_system_warnings")
        if isinstance(server_warnings, list) and server_warnings:
            pruned = [
                w for w in server_warnings
                if "Missing action_resolution field" not in str(w)
            ]
            if len(pruned) != len(server_warnings):
                debug_info["_server_system_warnings"] = pruned
```

```python
# mvp_site/llm_parser.py _merge_server_system_warnings_for_streaming_persistence (line ~639)
# Symmetric prune for the streaming path: if action_resolution is populated
# OR code_execution_used with dice_audit_events, strip the "Missing action_resolution"
# warning before persisting system_warnings to Firestore.
ar_populated = (
    isinstance(action_resolution, dict) and len(action_resolution) > 0
)
dice_audit_events = structured_fields.get("dice_audit_events") or []
code_execution_used = bool(debug_info.get("code_execution_used"))
pruned: list[str] = []
for warning in server_warnings:
    warning_str = str(warning)
    if "Missing action_resolution field" in warning_str and (
        ar_populated
        or (code_execution_used and len(dice_audit_events) > 0)
    ):
        continue
    pruned.append(warning)
```

### Tests (mvp_site/tests/test_action_resolution_utils.py)

```python
def test_add_action_resolution_prunes_stale_missing_warning(self):
    """Regression #9114: clear stale "Missing action_resolution" warning."""
    class FakeStructuredResponse:
        action_resolution = {
            "mechanics": {"rolls": [{"success": True, "purpose": "Stealth", "notation": "1d20+5"}]},
            "reinterpreted": False,
            "audit_flags": [],
        }
        outcome_resolution = None
    unified = {
        "debug_info": {
            "_server_system_warnings": [
                "Missing action_resolution field (required for player actions)",
                "Some other warning to keep",
            ],
        },
    }
    add_action_resolution_to_response(FakeStructuredResponse(), unified)
    warnings = unified["debug_info"]["_server_system_warnings"]
    self.assertNotIn(
        "Missing action_resolution field (required for player actions)", warnings
    )
    self.assertIn("Some other warning to keep", warnings)

def test_add_action_resolution_keeps_warning_when_no_recovery(self):
    """Companion to #9114: if action_resolution is still empty, keep the warning."""
    class FakeStructuredResponse:
        action_resolution = None
        outcome_resolution = None
    unified = {
        "debug_info": {
            "_server_system_warnings": [
                "Missing action_resolution field (required for player actions)",
            ],
        },
    }
    add_action_resolution_to_response(FakeStructuredResponse(), unified)
    warnings = unified["debug_info"]["_server_system_warnings"]
    self.assertIn(
        "Missing action_resolution field (required for player actions)", warnings
    )
```

Verified: all 76 existing tests in `test_action_resolution_utils.py` still PASS locally after the fix.

## Diagnostic recipe (re-runnable)

### Per-agent warning distribution on a campaign

```bash
unset PYTHONPATH && export GOOGLE_APPLICATION_CREDENTIALS=~/serviceAccountKey.json && export WORLDAI_DEV_MODE=true
.venv/bin/python -c "
import sys, json
sys.path.insert(0, '${HOME}/worldarchitect.ai/mvp_site')
sys.path.insert(0, '${HOME}/worldarchitect.ai')
from clock_skew_credentials import apply_clock_skew_patch
apply_clock_skew_patch()
import firebase_admin
from firebase_admin import auth, credentials, firestore
if not firebase_admin._apps:
    firebase_admin.initialize_app(credentials.Certificate('${HOME}/serviceAccountKey.json'))
uid = auth.get_user_by_email('jleechan@gmail.com').uid
db = firestore.client()
cid = '<CAMPAIGN_ID>'
docs = list(db.collection('users').document(uid).collection('campaigns').document(cid).collection('story').stream())
by_agent = {}
warns_by_agent = {}
for d in docs:
    e = d.to_dict()
    if e.get('actor') != 'gemini': continue
    debug = e.get('debug_info') or {}
    agent = debug.get('agent_name') or '?'
    by_agent[agent] = by_agent.get(agent, 0) + 1
    warnings = debug.get('_server_system_warnings') or []
    has_warn = any('Missing action_resolution' in str(w) for w in warnings)
    if has_warn: warns_by_agent[agent] = warns_by_agent.get(agent, 0) + 1
for ag, total in sorted(by_agent.items(), key=lambda x: -x[1]):
    warns = warns_by_agent.get(ag, 0)
    pct = 100 * warns / total if total else 0
    print(f'{ag:25s}: total={total:4d} warnings={warns:4d} ({pct:.1f}%)')
"
```

### Agent exemption matrix audit

```bash
cd ${HOME}/worldarchitect.ai
grep -B1 -A4 "requires_action_resolution" mvp_site/agents.py
```

Should show one `return False` per agent class. If a new agent class exists without an entry, that's a coverage gap.

### Validator exemption flag at runtime

```python
from mvp_site.agents import DialogAgent, HeavyDialogAgent, SpicyModeAgent, FactionManagementAgent, StoryModeAgent, GodModeAgent
for cls in [DialogAgent, HeavyDialogAgent, SpicyModeAgent, FactionManagementAgent, StoryModeAgent, GodModeAgent]:
    inst = cls.__new__(cls)
    print(f'{cls.__name__:30s} requires_action_resolution={inst.requires_action_resolution}')
```

Expected (post-#9132):
- DialogAgent: False
- HeavyDialogAgent: False (inherited)
- SpicyModeAgent: False (inherited)
- FactionManagementAgent: False
- StoryModeAgent: True (correct — it should require action_resolution; prune handles its case)
- GodModeAgent: False

## Lessons (the three things I got wrong this session)

1. **My initial sweep across 5 campaigns reported "0 warnings fired."** I had the sweep query right, but I was sweeping the wrong slice — the 5 largest + most recent campaigns happened to all be post-#9058 with `action_resolution` populated. The user-supplied screenshot showed a DIFFERENT campaign (29l48q6zFo7chxWnyjEY) where the warning was firing live. I should have trusted the user's evidence over my aggregate.

2. **The hypothesis "dice moved to code-execution, validator didn't follow" was half-right.** The data showed that on the user's campaign, `dice_audit_events[].source = "code_execution"` AND `dice_rolls: []` — confirming code-execution was indeed the dice source. But the validator wasn't broken — it was firing correctly on a field that legitimately should not be required for some agents. The bug was the agent exemption matrix gap + the post-validation recovery, not the validator itself.

3. **The first sweep's "warn_fired=0" conclusion was actively misleading** — it told the operator "the system is healthy" when the operator was looking at the warning on their screen. The lesson: aggregate sweeps can refute widespread regressions but they cannot refute a specific user-reported symptom on a specific surface. When the user provides evidence of a specific surface (URL, screenshot, TS), sweep THAT.

## When to fire this recipe

Use this Layer 7 recipe when ANY of:
- A WA UI warning fires AND a downstream code path could plausibly populate the field after validation (validator-then-recovery race candidate)
- A new agent class is being added — verify the exemption matrix
- An existing agent class was changed to load a lightweight prompt set without `action_resolution` schema anchor — verify exemption
- The `_server_system_warnings` field appears to have stale warnings (entries from before a fix was deployed, OR entries where downstream recovery happened post-validation)
- Operator provides a specific campaign URL / screenshot showing a warning that your aggregate sweep says isn't happening — re-sweep on the user's surface
