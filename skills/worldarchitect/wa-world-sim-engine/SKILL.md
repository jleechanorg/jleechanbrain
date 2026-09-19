---
name: wa-world-sim-engine
version: 1.0.0
description: Build, test, and fix world-sim tick engine internals.
author: Hermes (auto-curated)
license: MIT
metadata:
  hermes:
    tags: [worldarchitect, async, tick-engine, faction-sim, gcp-tasks]
    related_skills: [world-sim-e2e-pipeline, wa-llm-output-emission-false-green-watchdog, wa-daily-dice-audit-fix, pr-dispatch-defaults]
---

# WA World-Sim Engine

Class-level skill for working on `mvp_site/world_sim/*` — the async tick engine that drives faction movements, background events, and deterministic wiki-rule decisions for WorldArchitect.AI. Verified from PR #9148 cluster (feat/world-sim-mega-local, 2026-08-20).

## When to load

- Touching any file under `mvp_site/world_sim/` (`tick_engine.py`, `handler.py`, `dispatcher.py`, `firestore_lease.py`, `scoper.py`, `operations.py`, `agy_client.py`, `local_queue.py`, `local_worker.py`, `tools.py`).
- Adding the production trigger for world-tick enqueue from `process_action`.
- Debugging "events=0" / "scoper returned empty" / "tick stuck" bugs in this pipeline.
- Wiring `LocalQueue` ↔ `CloudTasksClient` for the same `enqueue_world_tick()` call site.
- Reviewing PRs that change world-tick semantics (CAS, idempotency, candidate scoping, faction roster authority).

## Module map

| Module | Purpose | Key surface |
|---|---|---|
| `tick_engine.py` | Server-executed brain. Idempotent tick with 3-layer dedup. | `TickEngine.run_tick()`, `canonical_tick_payload()`, `TickLease`, `seed_factions_from_guardrails()` |
| `handler.py` | HTTP worker entrypoint. Reads state from Firestore, runs TickEngine, appends events via `firestore.ArrayUnion`. | `handle_run_world_tick(payload, *, firestore_client=None)` |
| `dispatcher.py` | Enqueues to Cloud Tasks OR LocalQueue based on `WORLD_SIM_QUEUE_DRIVER`. Deterministic task name `tick-{campaign_id}-{turn_number}`. | `enqueue_world_tick(*, campaign_id, scheduled_for_turn, ...)` |
| `firestore_lease.py` | `@firestore.transactional` CAS lease — must be at module level (see Pitfall 1). | `FirestoreTickLease(campaign_id, expected, new_value)` |
| `scoper.py` | Server-computed candidate selector. Reads canonical `faction_roster` + `geography`. Never invents faction IDs. | `list_candidate_factions(state, player_location, top_k=5)` |
| `operations.py` | Server-computed deterministic army/intel operations (`faction_calculate_power`, `execute_*` aliases). | `execute_faction_tool(name, args)` router |
| `tools.py` | OpenAI-schema tool definitions for the LLM. | `WORLD_SIM_TOOLS`, `WORLD_SIM_TOOL_NAMES`, `execute_world_sim_tool()` |
| `agy_client.py` | Cheap SLM wrapper for the LLM-decided operation. Falls back to deterministic heuristic if `agy` is unauthenticated or `WORLD_SIM_TICK_LLM != agy`. | `tick_llm_call(prompt, schema_hint=None)` |
| `local_queue.py` | In-process FIFO queue — same `enqueue/dequeue` interface as `CloudTasksClient`. | `LocalQueue`, `get_default_queue()` |
| `local_worker.py` | Background thread that drains the LocalQueue. | `start_local_worker(handler, *, queue=None, poll_interval=0.25)` |

## The fixture contract (canonical data shape)

A campaign that drives ticks end-to-end MUST have this shape:

```python
{
    'campaign_id': 'e2e-9139-real',
    'player_faction_id': 'ironpact',          # required
    'player_location': 'keep_drakemoor',      # required
    'current_turn': 16,
    'last_world_tick_turn': 15,               # for CAS lease
    'world_tick_events': [],                  # events land here
    'world_events': [],
    'faction_roster': {                       # MUST be a DICT keyed by faction_id
        'silverbough': {
            'name': 'Silverbough Pact',
            'stance': 'hostile',
            'troops': {'soldiers': 40, 'spies': 5, 'elites': 2},
            'units':  {'soldiers': 40, 'spies': 5, 'elites': 2},  # BOTH troops + units
            'home_territory': 'emerald_grove',
            'territory_nodes': ['emerald_grove'],  # PLURAL list, NOT home_territory singular
            'power_score': 48,
            'is_war_with_player': True,
            'treaty_with_player': False,
            'in_campaign': True,
            'relationships': {'ironpact': 'war'},   # stance lookup
        },
        'redcrown': {
            'name': 'Redcrown', 'stance': 'neutral',
            'troops': {'soldiers': 25, 'spies': 10, 'elites': 1},
            'units':  {'soldiers': 25, 'spies': 10, 'elites': 1},
            'home_territory': 'highvale',
            'territory_nodes': ['highvale'],
            'power_score': 36,
            'is_war_with_player': False,
            'relationships': {'ironpact': 'neutral'},
            'in_campaign': True,
        },
        'ironpact': {
            'name': 'Ironpact (player)', 'stance': 'self',
            'troops': {'soldiers': 30, 'spies': 3, 'elites': 5},
            'units':  {'soldiers': 30, 'spies': 3, 'elites': 5},
            'home_territory': 'keep_drakemoor',
            'territory_nodes': ['keep_drakemoor'],
            'power_score': 38,
            'is_war_with_player': False,
            'in_campaign': True,
        },
    },
    'geography': {                              # top-level adjacency graph
        'keep_drakemoor': ['emerald_grove', 'highvale'],
        'emerald_grove': ['keep_drakemoor', 'highvale'],
        'highvale':     ['keep_drakemoor', 'emerald_grove'],
    },
}
```

### Failure modes when the contract is violated

| Symptom | Cause | Fix |
|---|---|---|
| `events=0` returned | `faction_roster` is a `list` (not `dict`) | Reshape to dict keyed by faction_id |
| `events=0` returned | `territory_nodes` missing | Add `territory_nodes: [<node_id>]` per faction |
| `events=0` returned | `geography` top-level missing | Add adjacency dict |
| `troops_committed=0` always | `units` missing (engine reads `units`, not `troops`) | Add `units: {soldiers, spies, elites}` |
| All events have `trigger=discovery` | `relationships[player_faction_id]` missing | Add per-faction relationships dict |
| Handler crashes silently | `player_faction_id` or `player_location` empty | Both required on the dispatch payload OR fetched from campaign doc by handler |

## Production trigger wiring (the canonical pattern)

Every player action on `/api/campaigns/<id>/interaction` enqueues a world-tick for the current turn. The hook is in `mvp_site/main.py` right before the `safe_jsonify(result), 200` return:

```python
try:
    from mvp_site.world_sim.dispatcher import enqueue_world_tick

    _state = run_blocking_io(
        firestore_service.get_campaign_game_state,
        user_id,
        campaign_id,
    )
    if _state is not None:
        _current_turn = int(_state.turn_number or 0)
        if _current_turn:
            _task_name = enqueue_world_tick(
                campaign_id=campaign_id,
                scheduled_for_turn=_current_turn,
            )
            logging_util.info(
                "WORLD_TICK_ENQUEUED: campaign=%s turn=%s task=%s",
                campaign_id, _current_turn, _task_name,
            )
except Exception as _exc:
    logging_util.warning(
        "WORLD_TICK_ENQUEUE_FAILED: campaign=%s err=%s",
        campaign_id, _exc,
    )
```

Rules:
- **Per `worldarchitect.ai/AGENTS.md`**: NEVER use `hasattr`/`getattr` on `GameState`. `GameState.turn_number` is the canonical attribute (NOT `current_turn`).
- The exception fence is intentional — a tick-enqueue failure must NOT fail the player's action response. Log as `WORLD_TICK_ENQUEUE_FAILED`.
- `WORLD_TICK_ENQUEUED` info-log line lets you trace per-action enqueues in Cloud Logging without joining on campaign_id.
- `enqueue_world_tick()` does NOT require `player_faction_id`/`player_location` — the handler reads them from the campaign doc via `load_canonical_state`.

## The e2e smoke (real Dev Firestore, no GCP)

```bash
cd ${HOME}/projects/wt-world-sim-mega-local
WORLD_SIM_QUEUE_DRIVER=local TICK_FAKE_LLM=1 TESTING_AUTH_BYPASS=true \
  PYTHONPATH=. ${HOME}/projects/worldarchitect.ai/vpython -c "
import json, time
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
    enqueue_world_tick(campaign_id=camp_id, scheduled_for_turn=turn)
time.sleep(8)
worker.stop()

camp = fs.collection('campaigns').document(camp_id).get().to_dict()
print(f'world_tick_events: {len(camp.get(\"world_tick_events\", []))}')
for e in camp.get('world_tick_events', [])[:10]:
    print(f'  turn={e[\"turn_generated\"]} faction={e[\"faction_id\"]} kind={e[\"kind\"]} trigger={e[\"trigger_type\"]}')
"
```

Expected: war faction (silverbough) produces `trigger=siege`, neutral faction (redcrown) produces `trigger=discovery`. `faction_calculate_power(40,5,2) → fp=48` is server-computed.

## Verified bugs + fixes (pitfalls library)

### Pitfall 1: `@firestore.transactional` must be at module level

Defining it inside a method fails with `'generator' has no attribute 'exists'` / `'Transaction not in progress'`. Fix in `mvp_site/world_sim/firestore_lease.py`: lift `_firestore_cas` to module level, call from `compare_and_set`:

```python
@firestore.transactional
def _firestore_cas(transaction, ref, expected, new_value):
    snap = ref.get(transaction=transaction)
    current = int(snap.to_dict().get("last_tick_turn", 0)) if snap.exists else 0
    if current != expected:
        return False
    transaction.set(ref, {"last_tick_turn": int(new_value)})
    return True

class FirestoreTickLease:
    def compare_and_set(self, campaign_id, *, expected, new_value):
        ...
        if hasattr(self._client, "transaction"):
            transaction = self._client.transaction()
            return _firestore_cas(transaction, ref, expected, new_value)
        ...
```

### Pitfall 2: `google-cloud-tasks` missing from venv

Symptom: 3 dispatcher tests fail with `tasks_v2 = None`. Fix: add `google-cloud-tasks>=2.16.0` to `mvp_site/requirements.txt` and install in venv (`./vpython -m pip install --quiet 'google-cloud-tasks>=2.16.0'`).

### Pitfall 3: Design Doc Grep Gates Gate 0

`jleechanorg/worldarchitect.ai` `Design Doc Gate` workflow fails any PR whose non-test `mvp_site/*.py` delta exceeds 50 lines unless the PR body contains `## Tenets` OR `## Design Decision` with a `rev-xxxx` bead ID or `.md` path. The PR #9148 cluster had 2239 lines — body needed the section. Other jleechanorg repos may have different gates; verify with `gh workflow list`.

### Pitfall 4: `faction.units` vs `faction.troops`

`tick_engine.py:_evaluate_candidate` does `sum((faction.get("units") or {}).values())` for headcount. Seed fixtures with BOTH `troops` (display) AND `units` (engine). If you only seed `troops`, `faction_calculate_power` is called with `soldiers=0, spies=0, elites=0`.

### Pitfall 5: Agy auth required

`agy --print` exits 2 with "authentication timed out" when AGY isn't authenticated. `tick_llm_call` correctly falls back to deterministic heuristic. With `WORLD_SIM_TICK_LLM=agy` + auth, real LLM decides non-war factions (heuristic returns `ignore` for non-war).

### Pitfall 6: Heuristic skips non-war factions

In `TICK_FAKE_LLM=1` mode, `_heuristic_decision` returns `ignore` for factions whose prompt doesn't contain "war"/"pending"/"discovery". Result: only war factions produce events. This is expected fallback behavior; real LLM (agy) decides non-war behavior.

### Pitfall 7: Scoper requires `territory_nodes` (plural), not `home_territory`

`scoper._factions_within_proximity` reads `entry.get("territory_nodes")` and tests membership in the BFS-reachable set. Singular `home_territory` is ignored → 0 candidates → 0 events.

## Cost estimate

10k players × 30 actions/day = 300k tasks/day ≈ $0.36/day Cloud Tasks + $300-900/day LLM (with real agy). Local-mode costs nothing.

## Files to read when this skill loads

- `mvp_site/world_sim/__init__.py` — package surface
- `mvp_site/world_sim/tick_engine.py` — TickEngine + TickLease (read this first)
- `mvp_site/world_sim/handler.py` — HTTP worker entrypoint
- `mvp_site/world_sim/dispatcher.py` — LocalQueue + Cloud Tasks driver swap
- `mvp_site/faction/dual_mode.py` — TriggerType enum (what `world_sim` events map to)
- `mvp_site/faction/tools.py` — the `execute_faction_tool` router `world_sim` calls