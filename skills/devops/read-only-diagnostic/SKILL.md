---
name: read-only-diagnostic
description: Skip persistent artifacts. Return verdict only.
tags: [diagnostic, read-only, analyze, verdict, firestore, bq]
version: 1.1.0
changelog:
  - "1.1.0 (2026-08-20, campaign ArYA47Fvx8HTYC8jpleO): Add Pitfall 7 — `npc_data[X].status=null` is not equivalent to \"alive\"; never conclude NON-REPRO without `story_history[]` cross-reference. Worked example: agent initially diagnosed NON-REPRO (canonical state had Kel'Thuzad at L18 alive, user claimed \"kelthuzad is dead\"); user correction \"i killed him at hyal earlier\" forced a second-pass story-doc grep that surfaced the Hyjal overkill at 03:23:11Z + the resurrection at 09:26:51Z + the canonical death in core_memories. Final verdict: REPRO, render-side resurrection sub-class. Updated Step 2 row for `npc forgot`/`resurrected` titles to point at Pitfall 7 (was over-confident NON-REPRO). Updated cross-references to note the recipe supersession."
license: MIT
---

# Read-only diagnostic workflow

## When to Use

Activate when user message contains "analyze", "analyze only", "diagnostic", "diagnose", "investigate", "what's wrong", "why does", "why is", "don't code", "no code", "no fix", "just tell me", "NALYZE" (typo for ANALYZE), "read-only", "don't write", "no mutation", OR posts a live URL + asks "what's happening" / "why this state" / "is this correct", OR pastes a campaign/state ID + asks for diagnostic without action.

**Do NOT activate** when user explicitly asks for a fix, invokes a workflow that requires writing (`/repro` without "analyze", `/green <PR>`, `/finish <task>`, `/a <task>`), or asks "how do I fix this" — those are fix-shaped requests.

When the user asks for analysis without execution — "analyze only", "don't code", "just diagnose", "what's wrong", "investigate but don't fix" — collapse the workflow to **read-only** steps. Do NOT create persistent artifacts (GitHub issues, beads, PRs, branches, files on disk).

## Triggers

Activate this skill when ANY of:
- User message contains "analyze", "analyze only", "diagnostic", "diagnose", "investigate", "what's wrong", "why does", "why is", "don't code", "no code", "no fix", "just tell me", or "NALYZE" (typo for ANALYZE)
- User message contains "read-only", "don't write", "no mutation"
- User posts a live URL + asks "what's happening" / "why this state" / "is this correct"
- User pastes a campaign/state ID + asks for diagnostic without action

**Do NOT activate** when:
- User explicitly asks for a fix ("fix it", "ship a PR", "make it work")
- User explicitly invokes a workflow that requires writing (`/repro` without "analyze", `/green <PR>`, `/finish <task>`, `/a <task>`)
- User asks "how do I fix this" — that's a fix-shaped request, not analyze

## The 4-step recipe

### Step 1 — Read-only source resolution

If the user pastes a URL, extract the canonical ID from the URL pattern:

| URL pattern | ID extractor | Skill to load |
|---|---|---|
| `.../game/<CID>` | take `<CID>` after `/game/` | this skill + `wa-directive-scope-factor-i-diag` |
| `https://github.com/<owner>/<repo>/issues/<N>` | take `<N>` after `issues/` | this skill + `github-issue` |
| `https://github.com/<owner>/<repo>/pull/<N>` | take `<N>` after `pull/` | this skill + `github-pr` |
| campaign_id literal | use as-is | this skill |

For Firestore-backed systems: resolve source UID via `copy_campaign.py --find-by-id <CID>` (read-only, no `--dest-email`). The script refuses to copy and prints source UID + email + title. **The "Error: refusing copy" line is expected and signals the read-only path succeeded.**

### Step 2 — Title-as-bug-name scan

Before any Firestore read, scan `meta.title` for canonical bug-class substrings:

| Title substring | Bug class | Reference |
|---|---|---|
| `json leak` / `serializ` | json-serialization-leak | `references/json-serialization-leak.md` |
| `god mode ignored` / `directive` | Factor F + Factor I | `wa-directive-scope-factor-i-diag` |
| `cache` / `slow` / `latency` | prompt-cache-invalidation | `references/bq-llm-payload-truncation-pitfall.md` |
| `npc forgot` / `resurrected` | **VERIFY story_history BEFORE concluding NON-REPRO** — see Pitfall 7 below | `references/non-repro-verification-recipe.md` + Pitfall 7 |
| `invent` / `made up` | LLM-invented-lore-artifacts | `references/repro-llm-invented-lore-artifacts-2026-07-18.md` |
| `level up stuck` | unbounded-scaling | `references/unbounded-scaling-l30-level-up-bug-class-2026-07-21.md` |
| `parenthetical bug name` | any — load `phenotype-lock-static-evidence.md` 3-grep | this skill |

Verified 2026-08-16 on `hf6mdyTHGVXuPxuR8r9C` — title was `"Genius doctor (json leak + god mode ignored)"` — pre-routed to Factor F + Factor I before any Firestore query. Saved 2-3 diagnostic turns.

### Step 3 — Canonical-state proof (Firestore direct read)

```python
import os, json
os.environ.setdefault('GOOGLE_APPLICATION_CREDENTIALS', os.path.expanduser('~/serviceAccountKey.json'))
from google.cloud import firestore
db = firestore.Client(project='<project-id>')  # e.g. 'worldarchitecture-ai'
UID = '<from step 1>'
CID = '<from step 1>'
gs = db.collection('users').document(UID).collection('campaigns').document(CID)\
        .collection('game_states').document('current_state').get()
gs_d = gs.to_dict() or {}

# 1. persisted directives
print('directives:', json.dumps(gs_d.get('custom_campaign_state', {}).get('god_mode_directives', []), default=str)[:1500])

# 2. persisted NPCs
npc_data = gs_d.get('npc_data') or {}
for k, v in npc_data.items():
    print(f'  KEY: {k!r}  status={v.get("status")}  tier={v.get("tier")}')

# 3. canonical location
print('last_location:', gs_d.get('custom_campaign_state', {}).get('last_location'))
```

**Pitfalls:**
- `character = {}` doesn't mean character creation didn't happen. Check both `character` (legacy) AND `player_character_data` (canonical).
- Some Firestore nested dicts have name-key corruption (a key like `"Dr: { Julian Mercer"` with leading space). Use `for k, v in npc_data.items(): print(repr(k))` to spot these.
- `entity_tracking = {}` often hides the active NPC roster. Read it explicitly.

### Step 4 — BQ / log forensics (claimed-vs-persisted cross-reference)

Pull the relevant agent's response_text and cross-reference LLM's `dm_notes` / `god_mode_response` claims against Firestore actual state.

For each `dm_notes` claim of the form "Added X to npc_data" / "Updated location to Y" / "Added a directive to maintain Z":

| LLM claim (from `dm_notes` / `god_mode_response`) | Persisted in canonical state? | Verdict |
|---|---|---|
| "Replaced Elena Vance with Marcus Andrews" | Elena Vance `status="normal"`; Marcus Andrews NOT in `npc_data` keys | **Factor F — narrative-ack-as-write** |
| "Added Drs. Lim, Reznick, Park" | 0 of 3 names in `npc_data` keys | **Factor F — narrative-ack-as-write** |

When the LLM self-flagellates in a later turn ("I apologize for the oversight. I failed to honor your instruction...") AND canonical state still doesn't reflect the fix, the verdict is **STALE PERSISTED STATE + FACTOR F BUNDLE**. The self-flagellation is itself evidence of Factor F — it's the LLM acknowledging the narrative-ack-as-write pattern it cannot break out of without a writeback hook.

## Verdict template

```
## 🔍 <workflow-name> — Analysis Only (no code, no gates, no replay)

**Subject:** <CID / issue# / URL> — "<title>"
**Source:** <email/owner> / UID <uid>
**State at <ts>**

### 1. What you actually said (reconstructed from BQ turn logs)
[table or quote block]

### 2. Canonical-state proof (read-only direct read)
[LLM claim vs persisted field table]

### 3. BQ evidence — what the served prompt saw
[Factor I checklist — prefix received, directives.add emitted, narrative honored, state written]

### 4. Bug class verdict
[FACTOR X — short name + 2-line explanation]

### 5. What you can do (your call, no action taken)
1. <end-state option A>
2. <end-state option B>
3. <end-state option C>
```

## Anti-patterns

- **Don't run any write-capable path.** No `gh issue create`, no `br create`, no `git commit`, no file creation, no `copy_campaign.py --dest-email`.
- **Don't open a worktree.** Read-only means read-only.
- **Don't post a 2-or-3-way menu asking the user to pick the next step.** They said "analyze", not "plan". Give them the verdict + 3 end-states they can pick from.
- **Don't trust the LLM's "I will fix this next turn" as a durable resolution.** Always cross-reference `dm_notes` claims against Firestore pre-state. Verified on 2026-08-16 — the LLM self-flagellated in 1 of 5 god-mode turns, then proceeded to fail again the next turn with the same Factor F pattern.
- **Don't assume `request_json` in BQ contains the user's raw input.** On `GodModeAgent` rows the field is empty in the verified case; reconstruct user intent from `response_text.god_mode_response` and `dm_notes` instead.
- **Don't conclude NON-REPRO from `npc_data[X].status=null` alone — Pitfall 7.** `status=null` means the canonical *field* is empty; it does NOT mean the NPC is alive. The LLM may have written the death into `story_history[]` (narrative-only) without ever emitting `state_updates.npc_data[X].status="dead"`. If you see `status=null`, you MUST cross-reference `story_history[]` for prior kill scenes before concluding NON-REPRO. Verified 2026-08-20, campaign `ArYA47Fvx8HTYC8jpleO`: agent concluded "non-repro — LLM honored the canonical alive state" from `npc_data.Kel'Thuzad.status=null` + `core_memories[67]="alive at L18"`. User corrected with "i killed him at hyal earlier". Story-doc grep surfaced the Hyjal overkill trail (`OFI6BDsbeKPNqlJJVxGX`, 2026-08-20 03:23:11Z, HP 135 → 0 overkill) + the resurrection at Icecrown (`JQNlBnU07dgv6Br9byxe`, 09:26:51Z, "led by the skeletal majesty of Kel'Thuzad"). The bug was REAL — LLM missed the canonical death at offset 462,617 of the served prompt. See full recipe below.

## Pitfall 7 — `npc_data[X].status=null` is not "alive"; verify story_history before NON-REPRO (added 2026-08-20)

The non-repro-verification-recipe (`references/non-repro-verification-recipe.md`) was authored from issue #8506 where the LLM correctly honored canonical state. That recipe's Step 3 — *"grep `npc_data[<NPC>].status` for the user's claimed status (case-insensitive bare name AND surname-composed form); 0 matches for `status="dead"` ⇒ LLM honored canonical state, NON-REPRO"* — assumes `status=null` and `status` absent are equivalent signals. **They are not.**

`status=null` (or missing) means: the canonical *structural field* was never written. It does NOT tell you whether the NPC is alive or dead in the narrative — that information lives in `story_history[]` and `core_memories[]`. When the LLM narrates a death but fails to emit `state_updates.npc_data[X].status="dead"`, the field stays `null` while the death is canonically recorded in narrative. A subsequent LLM read of `status=null` cannot distinguish "alive" from "narratively-dead but structurally-unset".

**The 5-step recipe that would have caught the Kel'Thuzad bug on the first pass:**

1. `copy_campaign.py --find-by-id <CID>` (read-only) to resolve UID.
2. Read `current_state.game_states` directly. Print every NPC key + `status` + `entity_id` + `name`. Flag any `status=null` NPC the user mentioned.
3. **Grep `story_history[]` for the NPC name + kill/death/destroy/consume/overkill patterns.** Sort by `timestamp` ascending. The output is a per-scene event list — for each scene the NPC appears in, what happened?
4. Grep `core_memories[]` (sorted by index) for any entry that asserts the NPC is dead OR alive. Cross-reference indices against the story_history timeline.
5. **Only NOW classify the verdict.** If the user claims the NPC is dead AND `story_history[]` has a kill scene with `hp_current=0 overkill` for that NPC AND `core_memories[]` has a confirming entry AND `npc_data.status=null`, the bug class is **`npc-status-persistence-bug` — render-side resurrection sub-class**: LLM wrote the death to narrative but not to `state_updates.npc_data[X].status`. The LLM at a later turn reads `status=null` + a confirming `core_memories[]` entry + a story_history kill scene, then fails to honor the death because the served-prompt narrative near the current turn may show the NPC alive (e.g. a recent worldbuilding summary or post-kill-but-pre-burial scene).

**Recipe — story_history grep in Python:**

```python
from google.cloud import firestore
db = firestore.Client(project='worldarchitecture-ai', database='(default)')
UID = '<from step 1>'
CID = '<from step 1>'
col = db.collection('users').document(UID).collection('campaigns').document(CID).collection('story')
events = []
for d in col.stream():
    data = d.to_dict() or {}
    text = data.get('text', '') if isinstance(data.get('text'), str) else json.dumps(data.get('text',''), default=str)
    ts = data.get('timestamp')
    if ts and '<NPC_NAME_LOWER>' in text.lower():
        import re
        for m in re.finditer(r'[^.]*<NPC_NAME_LOWER>[^.]{0,400}\.', text, flags=re.IGNORECASE):
            events.append((ts, d.id, data.get('actor'), m.group()[:400]))
events.sort()
# Print full timeline of NPC events
for ts, did, actor, sentence in events:
    print(f'-- {ts} {did} actor={actor}: {sentence[:300]}')
```

**Decision table:**

| User claim | npc_data.status | story_history has kill scene | core_memories entry | Verdict |
|---|---|---|---|---|
| NPC dead | "dead" | yes | yes (confirming death) | Honor — canonical consistent, look elsewhere |
| NPC dead | null | **yes** | **yes** | **REAL BUG — render-side resurrection** (verified case) |
| NPC dead | null | no | no | LLM hallucinated a death — Factor G (LLM-invented lore) |
| NPC alive | null | yes (with resurrection scene) | yes (alive entry post-resurrection) | Honor resurrection OR bug class render-side persistence |
| NPC alive | "dead" | yes | yes (confirming death) | User wrong; NON-REPRO |

**Lesson:** the original recipe's NON-REPRO column was over-confident for `status=null`. The fix is to require `story_history[]` cross-reference whenever `status=null` and the user asserts a death. This is the same diagnostic discipline as `references/non-repro-verification-recipe.md` Step 3, but with the additional rule: **never conclude NON-REPRO from `status=null` without grepping `story_history[]` first.**

**Source:** Verified 2026-08-20, campaign `ArYA47Fvx8HTYC8jpleO` ("nocturne warcraft 3"), source `jleechan@gmail.com` / UID `vnLp2G3m21PJL6kxcuAqmWSOtm73`. First-pass verdict: NON-REPRO. User correction ("run /repro and read the campaign i killed him at hyal earlier"). Second-pass: story_history grep surfaced Hyjal overkill at 03:23:11Z + resurrection at 09:26:51Z + canonical-state death at core_memories index ~67. Final verdict: REPRO, render-side resurrection sub-class. Issue [#9162](https://github.com/jleechanorg/worldarchitect.ai/issues/9162) filed with full evidence (3-block diagnostic: served-prompt offset 462,617 confirmed LLM had the rule; response_text at offset 1,279,029 confirmed resurrection; npc_data persisted state unchanged). Bead `rev-ogk2j`.

## Cross-references

- `~/.smartclaw/skills/repro/SKILL.md` — the canonical /repo skill. This skill is the read-only variant.
- `~/.smartclaw/skills/worldarchitect/wa-directive-scope-factor-i-diag/SKILL.md` — the Factor I + claimed-vs-persisted diagnostic discipline.
- `~/.smartclaw/skills/worldarchitect/wa-directive-scope-factor-i-diag/references/title-as-bug-name-signal-2026-08-16.md` — title-scan pattern (Step 2 of this skill).
- `references/non-repro-verification-recipe.md` — original NON-REPRO recipe. Pitfall 7 above updates the Step-3 logic: never conclude NON-REPRO from `npc_data[X].status=null` without `story_history[]` cross-reference.

## Source

Verified 2026-08-16, campaign `hf6mdyTHGVXuPxuR8r9C`, source `jleechan@gmail.com` / UID `vnLp2G3m21PJL6kxcuAqmWSOtm73`. Title in Firestore: `"Genius doctor (json leak + god mode ignored)"`. 4 tool calls + 4 BQ queries. Verdict: Factor F bundle (LLM acknowledged canon instruction 5 times but never persisted).