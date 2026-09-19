---
name: dark-factory-outage-triage
description: "Use when ddf-XXXX PR is hung. 5-evidence-block triage."
type: quality
---

# Dark-factory outage triage

When a `ddf-XXXX` intake or a hung PR review surfaces as "the factory is stuck," the cause is almost always one of these five:

1. **Backend rate-limit/quota** (codex, agy, claudem running out of quota)
2. **Backend missing CLI** (binary not installed on `jeff-ubuntu`)
3. **Backend divergence** (Python runner vs Rust daemon disagree on the priority queue)
4. **Phantom-session parking** (worker died mid-task, daemon holds state file)
5. **Real review verdict** (genuine FAIL from a reviewer — NOT a stall)

The factory never says "I'm waiting on codex" — it just hangs. This skill gives you the 5-evidence-block playbook to distinguish them, plus the recovery action for each.

## 5-evidence-block playbook

Run these in order; each one narrows the hypothesis. Always cite the exact command + raw output in the reply.

### 1. Current live state
- `gh pr view <N> --json state,mergeable,statusCheckRollup` — is the PR itself green?
- `tail -n 200 ${HOME}/Library/Logs/dark-factory/daemon.jsonl` (Linux: `ssh jeff-ubuntu tail ...`) — what is the daemon doing RIGHT NOW?
- `ls -la /tmp/dark-factory/dispatch-*/` — are there active worker tmux sessions, or are they all dead?
- `launchctl print gui/$(id -u)/ai.dark-factory.daemon` (macOS) or `systemctl status ai.dark-factory.daemon` (Linux) — is the daemon running? Last exit code?

### 2. Raw root-cause evidence
- **Codex/quota**: `codex exec --yolo "ping"` 2>&1 — does it return quota / 429 / "rate limit exceeded"? Repeat 3x; if all 3 quota, the backend is **rate-limited**, not missing.
- **Missing CLI**: `which codex` / `which agy` / `which claudem` — if PATH lookup fails, the backend is **missing**, not rate-limited.
- **Two code paths to check** (recurring source of false diagnosis):
  - `rg "rate_limit|quota|429|too many|fallback|next.*reviewer" ${HOME}/projects/dark-factory/runner/dispatcher.py` — **zero matches means the GHA skeptic gate does NOT walk the priority queue on rate-limit.** That's the bug.
  - `rg "skeptic_reviewer_priority" ${HOME}/projects/dark-factory/daemon/src/er_runner.rs` — **matches present means the daemon side walks the queue.** Compare to the GHA side.
- Check `${HOME}/projects/dark-factory/config/skeptic_reviewer_priority.json` — what is the canonical reviewer priority? Default: `["claudem", "agy", "cursor-agent"]`. **Codex and Gemini CLI are NOT in the default list** as of 2026-08-18.

### 3. Git state
- `git -C ${HOME}/projects/dark-factory status --short --branch` — is the daemon's working tree clean? Is the operator on a clean `origin/main`?
- `git -C ${HOME}/projects/dark-factory log --oneline origin/main..HEAD` — what commits are unmerged? (If the priority-queue plumbing is sitting uncommitted on a branch other than main, the daemon on `jeff-ubuntu` is running stale code.)
- `git -C ${HOME}/projects/dark-factory ls-files --others --exclude-standard` — watch for untracked `runner/reviewer_priority.py`, `daemon/src/reviewer_priority.rs`, `config/skeptic_reviewer_priority.json`. **If these are untracked, the fix is half-landed** — fixture plumbing exists but the callsite update is missing.

### 4. Verification result
- For codex quota: `codex exec --yolo "echo hi" 2>&1 | head -20` — if "rate limit exceeded" appears, confirmed.
- For chain-walking: `.venv/bin/python -m pytest tests/test_reviewer_priority_parity.py tests/test_dispatcher_reviewer_chain_walk.py -v` — green means the chain-walk works locally; the daemon just needs a rebuild.
- Note the timestamp + exit code; record in the reply.

### 5. Prior incidents
- `session_search "codex quota outage"` — has this PR or one like it been stuck on codex before? PR #9092 was the second Codex-quota incident in 30 days as of 2026-08-18.
- `br list --type bug --priority 0 | grep -i quota` — is there already a filed bug for the missing chain-walking?

## Recovery actions (after diagnosis)

### Codex/rate-limit (most common)
- **Fastest path**: operator posts `MERGE APPROVED` in the PR thread per worldarchitect.ai/AGENTS.md — bypasses `/er` Evidence Gate.
- **Medium path**: forge the fix — dispatch a claudem worker on `feat/reviewer-fallback-on-quota` (clean branch from `origin/main`) to land chain-walking in `runner/dispatcher.py` + 4 new tests. See `references/chain-walking-fix-recipe.md`.
- **Slow path**: wait for codex quota reset (typically daily).

### Missing CLI / Binary gone
- Install on `jeff-ubuntu` via `~/.local/bin/<cli>` symlink.
- Existing `runner/handler_dispatch.py:_execute_gate` (lines 1119-1171) already handles missing-CLI via `_is_gate_infra_failure` → fallback to agy/claude. **But this is the gate path, not the skeptic/dispatcher path — different code.**

### Backend divergence (daemon vs runner)
- Daemon-side (Rust) is at `daemon/src/er_runner.rs:230-253` — iterates `skeptic_reviewer_priority()`.
- Runner-side (Python) is at `runner/dispatcher.py:91-180` — does NOT iterate; only single reviewer.
- The fix needs to land in BOTH. The runner-side is the one users hit most often because it's the GHA path.

### Phantom-session parking
- Worker died mid-task. Daemon holds `state-dispatched.json` files.
- Look in `daemon/src/tick.rs` for `reap_idle_worker_tmux_sessions` (added in bead `jleechan-w0r4`).
- Recovery: `br close <bead> --reason "session died; reopened as fresh intake"` → re-apply `factory` label on PR.

### Real review verdict
- Genuine FAIL/partial from a reviewer. **STOP — do not retry on a different backend** (no-reviewer-shopping rule, see `docs/cli-fallback-audit-2026-06-12.md`).
- Recovery: address the reviewer's comments, push fixes, re-arm.

## Pitfalls

- **Don't blame the operator** for "fallback didn't fire" — the fallback often doesn't exist yet. See `references/chain-walking-fix-recipe.md`.
- **Don't push onto `fix/jleechan-w0r4-reap-idle-worker-sessions`** — that's someone else's branch. Branch from `origin/main`.
- **Don't confuse "codex quota" with "codex missing"** — `which codex` succeeds in both cases. Check the actual subprocess output.
- **Don't skip the daemon rebuild** — even if the Python side is fixed, the daemon on `jeff-ubuntu` also needs `cargo build --release && systemctl restart ai.dark-factory.daemon`.
- **Don't assume the daemon `daemon.jsonl` is canonical** — the agent-operator daemon can log milestones without ingesting gate results. Check the GHA Actions log, not just the daemon log.
- **Don't end your reply with "Say 'go' or correct scope"** — that violates `finish-the-job` / `no-confirmation-gate` and fires the dropped-thread followup. When the goal is clear, drive to conclusion.

## Verification

After applying any fix from this skill:
- `.venv/bin/python -m pytest tests/test_reviewer_priority_parity.py tests/test_dispatcher_reviewer_chain_walk.py -v` (Python side)
- `cd ${HOME}/projects/dark-factory && cargo build --release && cargo test --release` (daemon side)
- `gh pr view <N> --json state,mergeable` — confirm CI is green and PR is mergeable.

## References

- `references/chain-walking-fix-recipe.md` — exact file/line locations and the test pattern for landing chain-walking in `runner/dispatcher.py`.
- `references/priority-queue-canonical-json.md` — copy of `config/skeptic_reviewer_priority.json` + the parity-test invariants.
- `references/incident-2026-08-18-pr-9092.md` — the canonical Codex-quota outage (full transcript) that this skill was extracted from.
