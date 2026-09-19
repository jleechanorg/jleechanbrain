---
name: dark-factory-rate-limit-fallback
version: 1.0.0
description: |
  Add reviewer-priority queue chain-walking to the dark-factory GHA skeptic
  gate so the factory no longer stops on a codex/claudem/agy/cursor-agent
  rate-limit / quota bust. Origin: ddf-PR-9092-outage (PR #9092 stuck on
  codex review quota, blanket park instead of next-vendor walk; fix landed
  in jleechanorg/dark-factory#654).

when_to_use: |
  Use when:
  - The dark-factory GHA skeptic gate hits a vendor rate-limit / quota
    bust and the run parks instead of walking to the next reviewer.
  - You see `SKIPPED_DUPLICATE` followed by `dispatched → re-roll held`
    on the `evidence_review` gate, with `probe_error` matching
    `rate.?limit|quota exceeded|429|too many requests`.
  - The daemon's `er_runner.rs` already walks the priority queue but
    the gate path's `runner/handler_dispatch.py:_execute_gate` only
    fires the hardcoded `["agy","claude"]` fallback on `FileNotFoundError`,
    not on rate-limit.
  - Same as the parent skill `auto-factory-operator-client` Class F
    fix recipe — this skill is the durable implementation, the parent
    skill is the operator-side unblock (post `MERGE APPROVED`).

triggers:
  - "the factory shouldn't stop on codex quota"
  - "reviewer gate is stuck on rate-limit"
  - "dark-factory rate-limit fallback"
  - "chain-walk reviewer priority"
  - "skeptic gate fell back to agy and got stuck"
  - "extending REVIEWER_CLI_TO_IDENTITY for the new CLIs"
  - "ddf-PR-9092-outage"

allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep

context: inline

---

# dark-factory-rate-limit-fallback

Land a clean PR on `jleechanorg/dark-factory` that adds vendor-fallback
chain-walking to the GHA skeptic gate's reviewer dispatcher so the
factory no longer stops on a single-vendor rate-limit bust.

## Origin

PR #9092 (2026-08-18) on `jleechanorg/worldarchitect.ai` was stuck on
the `/er` Evidence Gate waiting for codex code-review quota. The
factory's reviewer-gate path (`runner/handler_dispatch.py:_execute_gate`)
only handles `FileNotFoundError` for missing binaries; it does not detect
rate-limit / quota errors (`429`, "rate limit exceeded", "quota exceeded",
"too many requests"). When codex busts, the gate loops or parks
(`re-roll held`), waiting for next-day quota reset instead of walking
to the next vendor in `backend_priority`.

The daemon-side already walks the canonical priority queue in
`daemon/src/er_runner.rs:230-253` for the `er_runner` evidence verdict.
The GHA-side (`runner/skeptic_gate.py` + `runner/skeptic_gate_cli.py`
+ `runner/dispatcher.py:VerifierDispatcher`) did not. This skill closes
the GHA-side gap.

## Contract

A PR is "properly skilled" when:

1. `runner/dispatcher.py:VerifierDispatcher._chain_walk_reviewer` walks
   `skeptic_reviewer_priority()` on detected rate-limit errors
   (regex: `rate.?limit|quota|429|too many requests|usage limit|...`).
2. The fallback trail is annotated on the result:
   `reason = "<original> (fallback_used=true; fallback_from=<original>)"`.
3. The queue-exhausted path returns
   `SkepticResult(check_state="failure", verdict=None, reason="all reviewers exhausted (vendors tried: ...; last error: ...)")`.
4. `runner/skeptic_gate.REVIEWER_CLI_TO_IDENTITY` is extended at
   module-import time from `skeptic_reviewer_priority()` so the
   chain-walk vendor names pass the `bind_reviewer_identity` check.
   Each chain-walk CLI is bound to its own name (not the legacy
   codex/gemini shorthand). Codex and gemini remain pinned.
5. `runner/skeptic_gate_cli.py` reads default cheap/premium reviewer
   names from the priority config (not hardcoded `gemini`).
6. Bind / provenance security checks still run on the fallback vendor
   — chain-walk is NOT a bypass.
7. `tests/test_dispatcher_reviewer_chain_walk.py` covers 4 cases:
   - Plan-mode (`*.py` target_glob, not `**/*` — that pre-existing bug
     is out of scope here).
   - Vendor identity in the mocked `evaluate` MUST match the routed
     vendor name (the bind map rejects mismatched identity).
   - On rate-limit, the dispatcher advances through the queue.
   - On exhaustion, the reason carries the last error verbatim.
   - On fallback, `bind_reviewer_identity` and `verify_provenance`
     are called on the actual fallback vendor (not bypassed).
8. Full test suite green: `pytest tests/` reports 0 failures.
9. PR pushed to a fresh branch from `origin/main` (NOT from any
   in-progress branch with reap-idle workers / unrelated work).
10. `gh pr create` with the title prefixed `feat(skeptic):`.

## Phases

### Phase 0 — Discover the existing priority config

```bash
# The canonical priority queue lives at this path on Linux:
ssh jeff-ubuntu 'cat /home/jleechan/.local/state/dark-factory/.beads/../releases/$(ls -1 /home/jleechan/.local/share/dark-factory/releases/ | tail -1)/config/skeptic_reviewer_priority.json'
# OR on the daemon source repo:
grep -rn "skeptic_reviewer_priority\|reviewer_priority" ${HOME}/projects/dark-factory/
```

The canonical vendor list (`["claudem", "agy", "cursor-agent"]` under
the operator's 2026-08-18 directive) is the contract; do not change
the order without operator approval.

If the priority config is missing on `origin/main`, file the canonical
content as part of this PR (matches the JSON the daemon side already
reads via `include_str!`).

### Phase 1 — Worktree the fix

```bash
git -C ${HOME}/projects/dark-factory fetch origin
git -C ${HOME}/projects/dark-factory worktree add -b feat/reviewer-fallback-on-quota \
  ${HOME}/projects/dark-factory.worktrees/reviewer-fallback-quota origin/main
cd ${HOME}/projects/dark-factory.worktrees/reviewer-fallback-quota
./install.sh --no-smoke --no-link --no-cmds
```

### Phase 2 — Implement

The 7 files (the worker that shipped this skill produced exactly these):

1. `runner/reviewer_priority.py` (NEW, ~57 lines) — Loads
   `config/skeptic_reviewer_priority.json`; exposes
   `skeptic_reviewer_priority()` (mandatory reviewer list) and
   `default_reviewers_json()` (the JSON shape for
   `SKEPTIC_REVIEWERS_JSON`).
2. `runner/dispatcher.py:VerifierDispatcher._chain_walk_reviewer`
   (NEW method, ~120 lines) — wraps invoke+evaluate in a chain-walk
   loop. Annotates `fallback_used=true; fallback_from=<original>` on
   the result. Hard cap = queue length.
3. `runner/skeptic_gate.py` (NEW helper, ~30 lines) —
   `_extend_bind_table_from_priority()` extends
   `REVIEWER_CLI_TO_IDENTITY` at import time. Called at module bottom
   so every import of `skeptic_gate` (dispatcher, GHA gate, daemon
   python shims) sees the extended table.
4. `runner/skeptic_gate_cli.py` (small change, ~17 lines) — read
   default cheap/premium from `skeptic_reviewer_priority()` instead
   of hardcoded `gemini`.
5. `daemon/src/reviewer_priority.rs` (NEW, ~50 lines) — Rust parity
   reader; mirrors `runner/reviewer_priority.py` via `include_str!`.
   Optional — only land if the daemon-side reader does not already
   exist; if it does, just adopt the existing one.
6. `config/skeptic_reviewer_priority.json` (NEW, 6 lines) —
   `{"reviewer_priority": ["claudem", "agy", "cursor-agent"], ...}`.
7. `tests/test_dispatcher_reviewer_chain_walk.py` (NEW, ~400 lines)
   with 6 tests; `tests/test_reviewer_priority_parity.py` (NEW, 4
   tests).

**Two non-obvious pitfalls the worker hit:**

- `runner/reviewer_priority.py` must use `from __future__ import annotations`
  so the `lru_cache` decorator on a typed function works on Python 3.9+.
- `tests/test_dispatcher_reviewer_chain_walk.py` fixtures must use
  `target_globs=["*.py"]` (NOT `["**/*"]`), because `match_glob`
  has a pre-existing regex bug for `**/*` patterns (out of scope here).
- The `_mock_success_evaluate` test fixture must mirror the routed
  vendor's identity in `parsed.reviewer_identity` (e.g. for cursor-agent
  fallback, declare `reviewer_identity="cursor-agent"`), or the
  bind-rejection path short-circuits with a misleading failure.
- The test fixture for `test_chain_walk_preserves_provenance_check`
  must unpack `_stub_invoke_reviewer(...)[0]` to extract the function
  (not assign the tuple to `fake_invoke`), or the dispatcher sees a
  tuple-as-callable and throws a TypeError that the chain-walk
  misreads as a non-rate-limit "false success".

### Phase 3 — Test

```bash
cd ${HOME}/projects/dark-factory.worktrees/reviewer-fallback-quota
.venv/bin/python -m pytest tests/test_dispatcher_reviewer_chain_walk.py tests/test_reviewer_priority_parity.py -v
# expect: 10 passed
.venv/bin/python -m pytest tests/test_cli_fallbacks.py -v
# expect: 16 passed (no regressions)
.venv/bin/python -m pytest tests/ 2>&1 | tail -3
# expect: 1540 passed, 14 skipped, 0 failed
```

### Phase 4 — Commit, push, PR

```bash
git add config/skeptic_reviewer_priority.json daemon/src/reviewer_priority.rs \
        runner/dispatcher.py runner/reviewer_priority.py runner/skeptic_gate.py \
        runner/skeptic_gate_cli.py tests/skeptic_helpers.py \
        tests/test_dispatcher_reviewer_chain_walk.py tests/test_reviewer_priority_parity.py
git commit -m "claudem/minimax-M3: feat(skeptic): chain-walk reviewer priority on rate-limit"
git push origin HEAD:refs/heads/feat/reviewer-fallback-on-quota
gh pr create --base main --title "feat(skeptic): chain-walk reviewer priority on rate-limit" --body "..."
```

Commit message prefix MUST be `claudem/minimax-M3:` per
`~/.claude/CLAUDE.md` (env-preferences.mdc commit provenance).

### Phase 5 — /af the PR

Apply the `factory` GitHub label on the PR. The daemon's intake
scans for the label and the bead-driven intake normalizer picks
up the PR. With this fix landed, the daemon's gate will walk the
queue on quota, so PR #9092 (and any future quota-stuck PR) is
no longer a blocker.

```bash
gh api repos/jleechanorg/dark-factory/issues/654/labels -X POST -f labels[]=factory
```

## Output Format

A successful run produces:

- **PR URL** at `https://github.com/jleechanorg/dark-factory/pull/<N>`
- **Branch** `feat/reviewer-fallback-on-quota` from `origin/main`
- **Commit** `claudem/minimax-M3: feat(skeptic): chain-walk reviewer priority on rate-limit`
- **Tests** 1540 suite green + 6 new chain-walk tests + 4 parity tests
- **Diff** ~9 files, ~800 lines, single commit
- **/af trigger** `factory` label applied on the PR

## Pitfalls

- ❌ **Don't push onto `fix/jleechan-w0r4-reap-idle-worker-sessions`.**
  That branch has its own worktree-history scope. Stay on a fresh
  branch from `origin/main`.
- ❌ **Don't touch PR #9092.** That needs a separate user-side
  `MERGE APPROVED` per `jleechanorg/worldarchitect.ai/AGENTS.md`.
  This skill fixes the durable code path; PR #9092's batching is
  a separate user decision.
- ❌ **Don't widen scope to `match_glob`.** Pre-existing regex bug
  for `**/*` patterns; use `*.py` in test fixtures and file a
  separate bead.
- ❌ **Don't add chain-walk vendors to `REVIEWER_CLI_TO_IDENTITY`
  as a hardcoded dict.** Extend via
  `_extend_bind_table_from_priority()` at import time so the bind
  table stays in lockstep with the canonical priority config.
- ❌ **Don't bypass the bind/provenance checks on the fallback
  path.** The chain-walk is a routing mechanism, not a security
  bypass.
- ❌ **Don't replace the dispatcher wholesale.** The chain-walk is
  a wrapper around the existing invoke+evaluate call. The
  `bind_reviewer_identity` and `verify_provenance` checks in
  `dispatch()` MUST still run on the actual fallback vendor.

## Companion skills

- `auto-factory-operator-client` — the operator-side /af workflow.
  Class F (reviewer gate stuck on vendor quota) is the parent
  context; this skill is the runtime fix for that failure class.
- `claude-code-claudem` — the worker contract for delegating this
  code change to a claudem session on a clean worktree.

## Anti-patterns

- ❌ Adding the new CLIs (`claudem`, `agy`, `cursor-agent`) directly
  to `REVIEWER_CLI_TO_IDENTITY` as a hardcoded literal — drifts
  from the priority config, needs to be added in two places.
- ❌ Removing the `bind_reviewer_identity` check on the fallback
  vendor — the chain-walk is not a security bypass.
- ❌ Pushing onto a branch with unrelated work — see
  `pr-clean-branch-from-main-no-history-bloat` in SOUL.md.
- ❌ Hand-editing from the operator-client Mac session — use
  `claudem` on a fresh worktree, NOT inline edits.

## Verification

After the PR is merged and the daemon is restarted with the new
release on `jeff-ubuntu`:

```bash
# Verify the daemon picks up the new priority queue
ssh jeff-ubuntu 'grep -aE "skeptic_reviewer_priority\|claudem" /home/jleechan/Library/Logs/dark-factory/daemon.jsonl | tail -3'

# Verify a codex rate-limit now walks the queue
# (simulate by inspecting the bind-table extension):
ssh jeff-ubuntu "systemctl --user show ai.dark-factory.daemon.service -p Environment | grep -E 'DARK_FACTORY_REVIEWER'"
```

The durable test that the fix works: a fresh PR that triggers
`/er` with codex busted should produce `EXISTING_PR_ADOPTED` →
no re-roll held → `GATE_ASSESSMENT` with `evidence_review.verdict: pass`
on the next vendor in the queue.

## Provenance

- Author: claudem worker `deleg_026626d8` (timed out at 600s, finished
  132/132 tests in 16s after rescope).
- Final fix landed manually by the operator-client session on
  `feat/reviewer-fallback-on-quota` (commit `67ee5867b1`).
- PR: https://github.com/jleechanorg/dark-factory/pull/654
- /af: bead `dark-factory-qyze` filed in daemon's
  `/home/jleechan/.local/state/dark-factory/.beads/`, dispatched
  via `INTAKE_BEAD_CREATED` → `TASK_ROUTED` → `TASK_DISPATCHED`
  at 2026-08-19T05:05:08Z.
