# Case study: world-sim tick engine (PR #9148, 2026-08-19)

The canonical application of the local-testable-infra-pattern. Worked example
for any GCP-dependent feature.

## Why the pattern was needed

Operator (verbatim, Slack C0AH3RY3DK6 thread): *"How can we make it
testable locally? Can those talk to local servers?"*

Without the pattern, every code change requires a GCP credential + a deployed
Cloud Run worker to verify. That's a 5-30 min feedback loop. With the pattern,
the same verification runs in 0.5-3s on a Mac.

## Component mapping

| Component | File | Lines | Role |
|---|---|---|---|
| In-process queue (same interface as Cloud Tasks) | `mvp_site/world_sim/local_queue.py` | ~150 | `LocalQueue.enqueue/dequeue/drain/qsize/history` |
| Env-driven driver switch | `mvp_site/world_sim/dispatcher.py` | +30 | `QUEUE_DRIVER` from `WORLD_SIM_QUEUE_DRIVER` env |
| Background drainer thread | `mvp_site/world_sim/local_worker.py` | ~80 | `start_local_worker()` + `WorkerHandle.stop()` |
| End-to-end integration test | `mvp_site/tests/integration/test_local_world_sim_e2e.py` | ~280 | 8 tests, full chain + history assertion |
| Canonical CLI | `scripts/run_local_world_sim.py` | ~180 | `simulate` subcommand prints `queue.history()` |

## Live smoke output (the operator's "show me it really worked" evidence)

```
task_name=tick-cmp-smoke-001-11
LOCAL_WORKER: drained=1 tasks; running_total=1
=== captured evidence ===
{
  "task_name": "tick-cmp-smoke-001-11",
  "result": {
    "status": "ran",
    "events": [{
      "source": "world_tick", "kind": "upkeep",
      "turn_generated": 11, "trigger_type": "discovery",
      "faction_id": "silverbough",
      "description": "Warring faction consolidates"
    }],
    "transport": "local"
  }
}
```

## Production swap is one env var

```bash
WORLD_SIM_QUEUE_DRIVER=gcp python -m mvp_site.main
```

Same dispatcher code path, `tasks_v2.CloudTasksClient` instead of `LocalQueue`.
No code changes; no branch in the caller.

## Lessons specific to this case

- The handler also needed a local path: `if firestore_client is None: use
  in-memory lease + skip Firestore writes`. Don't forget to handle BOTH the
  producer side (queue) and the consumer side (handler).
- The agy_client wrapper had to fall back to a deterministic heuristic when
  the agy binary is unavailable — otherwise offline test environments break.
- Capture `events` (the actual world_tick events) in the handler result so
  the history assertion has real evidence to verify, not just status codes.
- The dispatcher driver module reads `WORLD_SIM_QUEUE_DRIVER` at IMPORT time,
  not per-call. Tests that want to swap drivers mid-suite must patch
  `dispatcher_module.QUEUE_DRIVER = "..."` after import.

## Test counts (before / after pattern)

- Before pattern (PR #9144 had this): 24 unit tests, all mocked. No e2e proof.
- After pattern (PR #9148 has this): 75 tests total (24 unit + 43 PR2 + 8
  e2e). The 8 e2e tests are the ones the operator cited as "show me it
  really worked".