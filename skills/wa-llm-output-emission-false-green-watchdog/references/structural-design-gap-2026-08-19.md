# Structural-Design Gap Diagnostic (3-layer A/B/C)

**Trigger phrase pattern** (this is NOT a per-turn regression; this is a long-term architectural gap):

- "the world feels empty / I'm the only player in this world"
- "factions don't move / background events don't fire"
- "the LLM invents enemies / units / troops instead of following a system"
- "all factions and characters should follow the same physics"
- "1999 Archmage-style simulation" / "rules of the universe"
- "want async ticks for faction movements"
- "I just want them to follow a system instead of inventing"

When the user reports the world "feels dead" or the LLM "invents whatever is narratively interesting," they are describing a **structural gap between the deterministic simulation layer and the LLM-facing narrative layer** — NOT a one-off turn regression. Do NOT enter the per-turn `copy_campaign.py` + replay loop; the bug is upstream of any single turn.

## Why this is a sibling of the false-green family, not the same bug class

The `wa-llm-output-emission-false-green-watchdog` skill's 8 layers cover **per-turn emission regressions**: a specific structured field (`dice_rolls`, `action_resolution`, `planning_block`) goes missing because a prompt refactor removed its schema anchor, OR a partial-fix PR only fixed one render path. Those are per-field, per-turn bugs.

The structural-design-gap is broader:
- It's about whether the **deterministic world simulation engine** runs at all
- It's about whether the **canonical faction roster / unit counts / event log** reaches the LLM
- It's about whether the **prompt anchors** force the LLM to source enemies/troops/units from canonical state vs. fabricate from narrative vocabulary

Same root family (LLM is unbounded when it should be bounded) but the fix is **engine-port + state-wiring + prompt-anchor**, not a per-prompt-field patch.

## The 3-layer diagnostic

### Layer A — Does the engine exist anywhere?

The simulation engine may be built but not deployed to the URL the user is on. Search private/sibling repos:

```bash
# 1. Find all repos under the org
gh api /orgs/<ORG>/repos?per_page=100 --jq '.[].name' | grep -iE 'claw|world|engine'

# 2. Search globally for sibling projects
gh search repos "<project-name>" --limit 10 --json fullName,description,visibility
```

Then for each candidate repo, fetch its tree and look for simulation code:

```python
import urllib.request, base64, json, subprocess
tok = subprocess.check_output(["gh", "auth", "token"], text=True).strip()

def fetch(repo, path, ref="main"):
    url = f"https://api.github.com/repos/{repo}/contents/{path}?ref={ref}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}",
                                                "Accept": "application/vnd.github+json"})
    r = urllib.request.urlopen(req, timeout=15)
    d = json.loads(r.read())
    return base64.b64decode(d["content"]).decode()

# Look for faction / world / scheduler / simulation trees
import subprocess as sp
files_out = sp.run(["gh", "api", f"/repos/{repo}/git/trees/main?recursive=1"],
                   capture_output=True, text=True, timeout=30).stdout
tree = json.loads(files_out)["tree"]
candidates = [t["path"] for t in tree
              if any(kw in t["path"].lower()
                     for kw in ["faction", "world", "tick", "scheduler", "simulation", "background"])]
```

Key files to look for:
- `world_scheduler.ts` / `world_scheduler_lease.ts` — periodic + in-play triggers with multi-instance safety
- `faction_simulator.ts` (often the largest file — 100KB+ for mature engines) — the deterministic sim
- `faction_types.ts` — the canonical type system (Faction, FactionIdentity, FactionCapabilities, FactionDiplomacy)
- `world_triggers.ts` — 4h-bucket + day-rollover in-play triggers
- `events.ts` — event emission system

**Verified worldai_claw signature (2026-08-19):**
- `world_scheduler.ts`: 6059 chars, `WorldScheduler` class, periodic + lease + SQLite dedup
- `world_scheduler_lease.ts`: 5801 chars, `WorldSchedulerLeaseManager`, `TICK_STARVED_MS = 30_000`, `DEFAULT_LEASE_MS = 5 * 60 * 1000`
- `world_triggers.ts`: 5495 chars, `checkInPlayTriggers` with 4h-bucket + day-rollover semantics
- `faction_simulator.ts`: 102656 chars — the full simulation engine
- `faction_types.ts`: 11892 chars — canonical type system
- `events.ts`: 20018 chars — event emission
- `index.ts`: 1466 chars — `getScheduler`, `startWorldScheduler`, `generateWhileAwaySummary`

### Layer B — What's actually deployed at the URL the user is playing?

The engine existing somewhere ≠ the engine being deployed to the URL the user has open.

```bash
# Curl the URL + identify the stack
curl -sSL -A "Mozilla/5.0" "<deployed-url>" > /tmp/deployed.html

# Grep the HTML for stack signatures
grep -E '<script.*src=' /tmp/deployed.html | head -20
grep -iE 'engine|worldarchitect|worldai_claw' /tmp/deployed.html
```

Signatures:
- Python `worldarchitect.ai` stack: `/frontend_v1/js/theme-bootstrap.*.js`, `/frontend_v1/api.*.js`, `<meta name="viewport"...>` only
- TypeScript `worldai_claw` stack: bundled minified JS, presence of `ws://` WebSocket transport, `OpenClaw` references

**Verified 2026-08-19:** `mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/game/ArYA47Fvx8HTYC8jpleO` serves the Python `worldarchitect.ai` frontend_v1 bundle — NOT worldai_claw. The user is on the Python stack even though the engine lives in worldai_claw.

### Layer C — Where does the LLM-facing layer diverge from the engine?

Once you've established the deployed stack, find the divergence points:

```bash
# Python stack living-world module surface
gh api /repos/jleechanorg/worldarchitect.ai/git/trees/main?recursive=1 --jq '.tree[].path' \
  | grep -iE 'living_world|faction|background_event|world_event|tick|scheduler'

# Then read the most likely culprits:
# - mvp_site/living_world.py — trigger cadence
# - mvp_site/living_world_contract.py — field stripping on cooldown
# - mvp_site/faction/* — static data generation only
# - mvp_site/prompts/living_world_instruction.md — does prompt force canonical sourcing?
```

Common divergence patterns:

1. **Cooldown strips canonical state from LLM payload.** `AUTHORITATIVE_LIVING_WORLD_FIELDS = {world_events, faction_updates, time_events, scene_event, complications, rumors}` is STRIPPED on non-LW turns via `strip_lw_fields_from_mapping`. Verified 2026-08-19: `living_world_contract.py:strip_lw_fields_from_mapping` + `restore_cooldown_state` mean faction moves get routinely removed from the LLM-facing state.

2. **Stale-event retirement depends on missing field.** `STALE_EVENT_TURN_THRESHOLD = 80` exists but `turn_generated` is missing on the events that get emitted → retirement never fires. Verified 2026-08-19 from `~/roadmap/2026-06-21-1724-slack-thread-roadmap.md:257` ("Horgus event" example).

3. **No "follow canonical roster" prompt anchor.** The narrative layer has `living_world_instruction.md` but no contract forcing the LLM to source enemy/troop/unit counts from `custom_campaign_state.faction_roster[id]` vs. narrative vocabulary. The LLM is free to invent whatever is dramatically interesting.

## Where to record the durable state

This class DOES warrant an issue + bead — the structural gap is real engineering work — but does NOT warrant `copy_campaign.py` + replay (there's no per-turn bug to reproduce).

- **GitHub issue**: file on `jleechanorg/<deployed-stack-repo>` with the 3-layer diagnosis in the body. Label it `archmage-mode` + `living-world` + `structural-gap`.
- **Bead**: `br create "<title>" --type bug --priority 2 --description-file <path>` from the deployed repo's checkout. The bead body should mirror the issue's 3-layer structure.
- **Skip**: `scripts/copy_campaign.py`, `download_campaign.py`, BQ `llm_payloads` query — all of these assume a per-turn bug that doesn't exist here.

## Proposed 3-PR fix shape (verified pattern)

When Layer A shows a complete engine exists in a sibling repo, propose a port:

- **PR 1** (low-risk, ~50 LOC): backfill `turn_generated` on every event-emit site so the existing `_retire_stale_background_events` actually fires. Branch: `fix/living-world-stale-events-turn-generated`.

- **PR 2** (medium-risk, ~300 LOC): port the WorldScheduler + WorldSchedulerLeaseManager semantics into the deployed stack as a Cloud Run Job that ticks `world_events` every N minutes for active campaigns. Use Firestore-locked lease pattern (acquire lease → if acquired run tick → release); one LLM call per tick via the SLM narrator pattern the source engine uses. Branch: `feat/living-world-tick-scheduler-cloud-run`.

- **PR 3** (medium-risk, prompt + test): add a `## Canonical Faction Roster` anchor to `mvp_site/prompts/living_world_instruction.md` that says "any enemy/troop/unit count you narrate MUST come from `custom_campaign_state.faction_roster[id]` — fabrication is a contract violation"; mirror in `narrative_system_instruction.md`; 8-test contract pinning the rule. Branch: `feat/llm-must-source-from-faction-roster`.

## Verified worked example — campaign ArYA47Fvx8HTYC8jpleO, 2026-08-19

- User symptom: "I am the only player in this world / the LLM just invents enemies and units"
- Layer A finding: worldai_claw has complete engine (102KB faction_simulator + WorldScheduler + lease + 4h triggers + generateWhileAwaySummary) — NOT deployed to user's URL
- Layer B finding: URL serves Python frontend_v1 bundle
- Layer C finding: `mvp_site/living_world_contract.py:strip_lw_fields_from_mapping` strips `world_events` on cooldown turns; `_retire_stale_background_events` has `turn_generated` missing on emitted events; no "follow canonical roster" prompt anchor
- GitHub issue: [#9139](https://github.com/jleechanorg/worldarchitect.ai/issues/9139)
- Bead: `rev-bru2q`
- 3-PR fix shape posted in Slack thread for user direction

## Cross-references

- `repro` skill — the user invoked `/repro` but this class is a documented off-ramp in the Failure-handling section (added 2026-08-19). The /repro workflow (copy_campaign + replay) does NOT apply to structural gaps.
- `wa-prompt-engineering` — companion for PR 3's prompt anchor (canonical-state-source rule).
- `wa-llm-output-emission-false-green-watchdog` — the umbrella skill this reference lives under; this is the Layer-9 narrative-side cousin (LLM inventing lore because the canonical-state plumbing isn't connected).
- SOUL.md `## COMMIT: finish-the-job` — when the user pivots from diagnosis to "ship the fix", dispatch to a claudem worker on a clean worktree, not inline.
- Wiki prior art (April 2026): `~/llm_wiki/wiki/concepts/{BackgroundEvent,CampaignCoherence,ArmyFactionPower,SpyOperations}.md` — the canonical schemas for immediate/long-term events, validation categories, army power formula, spy detection formula. Always grep the wiki before designing the fix shape — the rules often already exist as specifications, they just weren't wired into code.
- Roadmap prior art: `~/roadmap/2026-06-21-1724-slack-thread-roadmap.md:257` — the 2026-06 "stale background events" investigation thread that identified `_retire_stale_background_events` but never closed.