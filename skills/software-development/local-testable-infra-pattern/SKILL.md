---
name: local-testable-infra-pattern
description: Features with external infra needing local testability.
---

# Local-Testable Infra Pattern

When shipping a feature that depends on external managed infrastructure, the
default failure mode is "works in staging, breaks in dev, can't reproduce". The
operator's recurring request — "how can we make it testable locally?" — is a
class-level signal that this pattern applies.

## When this applies

- The feature writes to / reads from / dispatches to managed infra that needs
  credentials (Cloud Tasks, PubSub, BigQuery, S3, Cloud Storage, Firestore,
  GCP APIs in general).
- Operator explicitly asks for local testability, OR a `/cs` (compartmentalized
  / strict) work item is in play, OR you're shipping to a repo where
  `./local.sh` or `run_local_server.sh` is the canonical dev workflow.
- There's a flaky-cloud-cred or "I can't reproduce" signal in the conversation.

## The 4-component pattern

1. **In-process alternative with same interface** — `LocalQueue` exposes the
   same `enqueue(payload, *, task_name)` + `drain(handler)` + `qsize()` as
   `google.cloud.tasks_v2.CloudTasksClient.create_task`. Both raise
   `AlreadyExists` on dedup hit. The interface, not the implementation, is the
   contract.

2. **Env-driven driver switch** — `QUEUE_DRIVER = os.environ.get(...)`
   (default `local` for safe offline behavior; production sets `gcp`). Same
   call site, no code branches at the caller:

   ```python
   if QUEUE_DRIVER == "gcp":
       client.create_task(parent=..., task=...)
   else:
       q.enqueue(payload, task_name=...)
   ```

3. **Background drainer thread for local** — `local_worker.start_local_worker`
   runs a `daemon=True` thread that polls every ~250ms and calls the same
   `handle_*` function the production worker would. `WorkerHandle.stop()`
   exits the loop cleanly via a `threading.Event`.

4. **End-to-end integration test** — `tests/integration/test_local_*.py`
   exercises the full chain (enqueue → queue → worker → handler → events in
   handler result) with zero GCP credentials, then asserts on the captured
   `queue.history()` entries as the canonical evidence.

## When the pattern is overkill

- Pure-CLI tools that already work locally — skip it.
- One-off batch jobs that run once and never change — skip it.
- Serverless functions that ARE the cloud endpoint — wrap with a thin local
  HTTP shim (different pattern; not this one).

## Verification

- `PYTHONPATH=. vpython -m pytest mvp_site/tests/integration/test_local_*.py -v`
  shows every chain step passing.
- Live smoke: `python scripts/run_local_*.py simulate` prints `queue.history()`
  entries with the captured task_name + payload + result. This is the canonical
  evidence the operator wants when they ask "show me it really worked".
- Production-path coverage: run the same integration test with the production
  driver env var set + a mocked client. The local test proves the chain works;
  the mocked test proves the GCP code path is wired.

## Anti-patterns to avoid

- **Don't wrap the GCP call in a mock-only test** — mocks prove nothing about
  the production path. The integration test must use the REAL handler, the
  REAL worker, the REAL engine — just with in-process transport.
- **Don't add a `--local` CLI flag** to the GCP code path — the env var is
  the single switch. Flags cause drift (one team uses flag, another uses env).
- **Don't allow the local driver to silently no-op in production** — set
  `QUEUE_DRIVER=gcp` in production deploys; default `local` is for dev only.
- **Don't share the in-memory queue between processes** — it's per-process.
  If you need cross-process testing, run a real Cloud Tasks emulator
  (`gcloud beta emulators tasks`).

## Pitfalls (real failures)

- **Worker thread dies silently if the handler raises** — wrap handler in
  try/except in `drain()` and log the exception. Otherwise one bad task kills
  the worker and nobody notices.
- **In-memory lease is per-process** — if the Flask server and the worker
  thread are in different processes, the lease state diverges. Use a single
  process for local dev, OR share state via a module-level dict keyed by
  the resource id (e.g. `campaign_id`).
- **Default driver in tests must match production intent** — if production
  uses GCP, tests should default to GCP-with-mocked-client, with the local
  driver explicitly opted-in via `WORLD_SIM_QUEUE_DRIVER=local`. Otherwise the
  local driver silently passes integration tests when the GCP code path is
  buggy.
- **`LocalQueue.drain()` swallows exceptions** — fine for fire-and-forget
  tasks; for at-least-once semantics, log + retry once before swallowing.
- **Handler needs a local path too** — don't forget the consumer side. The
  handler that calls Firestore/Cloud SQL/etc. needs a `if client is None: use
  in-memory stub` branch, mirroring the dispatcher pattern.

## Operator preference (recurring signal)

The operator has asked "how can we make it testable locally" or
"queue real jobs in the local server" on multiple sessions. Treat this as a
**first-class acceptance criterion** for any feature that touches external
infra — the operator wants to be able to verify the full chain on a Mac with
zero GCP credentials before pushing to CI.

## Related skills

- `drive-pr-to-green` — for the broader PR-completion workflow
- `testing-mcp-real-server-proof` — for testing patterns that require real infra
- `dispatch-task` — for the ao spawn side of the same workflow
- `local-testable-infra-pattern/references/world-sim-case-study.md` —
  the world-sim tick engine worked example