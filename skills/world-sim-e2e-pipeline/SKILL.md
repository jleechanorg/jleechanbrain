---
name: world-sim-e2e-pipeline
description: Drive the world-sim async tick pipeline end-to-end.
---

# World-Sim E2E Pipeline

Proven recipe for driving the async tick pipeline end-to-end against real Google Cloud Firestore. Captured 2026-08-20 from PR #9148 cluster (feat/world-sim-mega-local).

## When to use

- Verifying that `mvp_site/world_sim/*` works against real Firestore (not just FakeFirestoreClient).
- Capturing evidence of real LLM-decided events landing in `world_events[]` / `world_tick_events[]`.
- Smoke-testing after any change to `tick_engine.py`, `handler.py`, `dispatcher.py`, `firestore_lease.py`, `scoper.py`, `operations.py`, or `agy_client.py`.

## Required setup

1. **Venv has google-cloud-tasks installed** (added in PR #9148):
   ```bash
   cd ${HOME}/projects/worldarchitect.ai
   ./vpython -m pip install --quiet 'google-cloud-tasks>=2.16.0'
   ```
   If `tasks_v2` import is None, this is the most common cause of test failures.

2. **Dev Firestore service account** at `~/serviceAccountKey.json` with project_id `worldarchitecture-ai` (NOT prod — the operator's actual repro campaign `ArYA47Fvx8HTYC8jpleO` lives in prod and dev SA can't read it).

3. **Worktree** at `${HOME}/projects/wt-world-sim-mega-local` on `feat/world-sim-mega-local`. Tests MUST run from this worktree via `PYTHONPATH=.` (worktrees don't share venv).

## Fixtures — the canonical contract

`faction_roster` MUST be a `dict` keyed by faction_id (NOT a list). Each entry needs:
- `territory_nodes`: list of geography-graph node IDs (plural; NOT `home_territory` singular)
- `relationships`: dict like `{"ironpact": "war"}` for stance lookup
- `is_war_with_player`, `treaty_with_player`, `power_score`, `troops`, `name`

The top-level state needs:
- `geography`: adjacency dict, e.g. `{"keep_drakemoor": ["emerald_grove", "highvale"], ...}`
- `player_faction_id`, `player_location`
- `last_world_tick_turn` (for CAS lease), `current_turn`, `world_tick_events: []`

Common failure modes if any of these is missing:
- **0 events returned** → either roster is a list (not dict), or `territory_nodes` is missing, or `geography` is missing
- **All "discovery" triggers** → relationships missing (defaults to neutral)

## The canonical smoke command

```bash
cd ${HOME}/projects/wt-world-sim-mega-local
WORLD_SIM_QUEUE_DRIVER=local TICK_FAKE_LLM=1 TESTING_AUTH_BYPASS=true \
  PYTHONPATH=. ${HOME}/projects/worldarchitect.ai/vpython -c "
import os, json, time
from mvp_site.firestore_service import get_firestore_client
from mvp_site.world_sim.dispatcher import enqueue_world_tick
from mvp_site.world_sim.local_worker import start_local_worker
from mvp_site.world_sim.local_queue import get_default_queue
from mvp_site.world_sim.handler import handle_run_world_tick

fs = get_firestore_client()
camp_id = 'e2e-9139-real'

fs.collection('campaigns').document(camp_id).update({'world_tick_events': [], 'last_world_tick_turn': 10})
fs.collection('world_tick_leases').document(camp_id).delete()

def handler_with_fs(payload):
    return handle_run_world_tick(payload, firestore_client=fs)

worker = start_local_worker(handler=handler_with_fs)
for turn in [11, 13, 15, 17, 19]:
    enqueue_world_tick(campaign_id=camp_id, scheduled_for_turn=turn,
                       player_faction_id='ironpact', player_location='keep_drakemoor')
time.sleep(8)
worker.stop()

camp = fs.collection('campaigns').document(camp_id).get().to_dict()
evidence = {
    'campaign_id': camp_id,
    'event_count': len(camp.get('world_tick_events', [])),
    'events': camp.get('world_tick_events', []),
    'queue_history': get_default_queue().history(),
}
with open(f'${HOME}/projects/wt-world-sim-mega-local/e2e_evidence_{int(time.time())}.json', 'w') as f:
    json.dump(evidence, f, indent=2, default=str)
print(f'events: {len(evidence[\"events\"])}, queue_history: {len(evidence[\"queue_history\"])}')
"
```

## Canonical seed script

```bash
PYTHONPATH=. ${HOME}/projects/worldarchitect.ai/vpython -c "
import datetime
from mvp_site.firestore_service import get_firestore_client
fs = get_firestore_client()
fs.collection('campaigns').document('e2e-9139-real').set({
    'campaign_id': 'e2e-9139-real',
    'player_faction_id': 'ironpact',
    'player_location': 'keep_drakemoor',
    'current_turn': 11,
    'last_world_tick_turn': 10,
    'world_tick_events': [],
    'world_events': [],
    'faction_roster': {
        'silverbough': {
            'name': 'Silverbough Pact', 'stance': 'hostile', 'power_base': 'forest',
            'troops': {'soldiers': 40, 'spies': 5, 'elites': 2},
            'home_territory': 'emerald_grove',
            'territory_nodes': ['emerald_grove'],
            'power_score': 48, 'is_war_with_player': True, 'treaty_with_player': False,
            'in_campaign': True,
            'relationships': {'ironpact': 'war'},
        },
        'redcrown': {
            'name': 'Redcrown', 'stance': 'neutral', 'power_base': 'city',
            'troops': {'soldiers': 25, 'spies': 10, 'elites': 1},
            'home_territory': 'highvale',
            'territory_nodes': ['highvale'],
            'power_score': 36, 'is_war_with_player': False, 'treaty_with_player': False,
            'in_campaign': True,
            'relationships': {'ironpact': 'neutral'},
        },
        'ironpact': {
            'name': 'Ironpact (player)', 'stance': 'self', 'power_base': 'keep',
            'troops': {'soldiers': 30, 'spies': 3, 'elites': 5},
            'home_territory': 'keep_drakemoor',
            'territory_nodes': ['keep_drakemoor'],
            'power_score': 38, 'is_war_with_player': False, 'treaty_with_player': False,
            'in_campaign': True,
        },
    },
    'geography': {
        'keep_drakemoor': ['emerald_grove', 'highvale'],
        'emerald_grove': ['keep_drakemoor', 'highvale'],
        'highvale': ['keep_drakemoor', 'emerald_grove'],
    },
    'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'owner_uid': 'e2e-test',
})
fs.collection('world_tick_leases').document('e2e-9139-real').delete()
print('seeded e2e-9139-real')
"
```

## Expected output (10 events from 5 ticks)

```
events: 10, queue_history: 5
  turn=11 kind=upkeep faction=silverbough trigger=siege troops=0 fp=0
  turn=11 kind=upkeep faction=redcrown trigger=discovery troops=0 fp=0
  ... (5 turns × 2 factions = 10 events)
```

`trigger=siege` for hostile factions with `relationships[player_faction_id] == "war"`. `trigger=discovery` for non-war factions. `troops` and `fp` are 0 because `TICK_FAKE_LLM=1` (heuristic fallback) — real agy calls produce non-zero values.

## Verified bugs + fixes captured

1. **`@firestore.transactional` must be at module level** — defining it inside a method fails with `'generator' has no attribute 'exists'` / `'Transaction not in progress'`. Fix in `mvp_site/world_sim/firestore_lease.py`: lift `_firestore_cas` to module level, call from `compare_and_set`.
2. **`google-cloud-tasks` not in venv** — added to `mvp_site/requirements.txt` as `google-cloud-tasks>=2.16.0` in PR #9148.
3. **Design Doc Grep Gates** — PR body needs `## Tenets / Design Decision` section with bead ID + roadmap/.md link when delta_lines > 50 (issue #9148 had 2239 lines, failed until body fix).
4. **LocalQueue + GCP driver swap** — `WORLD_SIM_QUEUE_DRIVER=local` (default) uses in-process queue; `gcp` uses CloudTasksClient. Same `enqueue_world_tick()` call site for both.
5. **Agy auth required** — `agy --print` exits 2 with "authentication timed out" when AGY isn't authenticated; tick_llm_call correctly falls back to heuristic.

## Single-CLI proof

```bash
PYTHONPATH=. python scripts/run_local_world_sim.py simulate \
    --campaign-id ArYA47Fvx8HTYC8jpleO --scheduled-for-turn 11 \
    --player-faction-id ironpact --player-location keep_drakemoor
```

Captures the full chain via `LocalQueue.history()`: `task_name`, `enqueued_at`, `executed_at`, `result.status`, `result.event_count`, `result.events[]`, `transport="local"`.