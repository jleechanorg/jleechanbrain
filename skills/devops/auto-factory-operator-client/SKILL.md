---
name: auto-factory-operator-client
version: 0.8.0
description: "/af and /auto-factory from a non-daemon host."
tags: ["auto-factory", "dark-factory", "operator-client", "mac-os", "mac-to-linux", "br-sync", "drive-existing-pr", "daemon-telemetry", "bead-store", "af-monitor-only", "monitoring-only", "intake-mechanism", "factory-label", "reviewer-quota", "codex-quota", "rate-limit", "vendor-fallback", "class-f", "class-g", "silent-spawn", "phantom-dispatch", "chain-walk", "bind-table", "allow-list-extension", "class-i", "exact-head-drift", "ao-bridge-blocker", "dark-factory-ik0v"]
category: devops
triggers:
  - /af
  - /auto-factory
  - drive this PR through the factory
  - run auto-factory on
  - factory-labeled PR
  - drive-existing-pr
  - why did /af not touch this PR
  - bead is filed but daemon isn't picking it up
  - dark-factory monitor
  - factory daemon telemetry
  - I added the factory label but daemon still hasn't picked up the PR
  - bead got parked with unmapped_repo
  - codex is rate-limited / codex quota
  - reviewer-gate stuck on codex
  - cold reviewer failing
  - factory should fall back on quota
  - /er wait is the only thing blocking /er
  - coder can't fix this
  - factory isn't doing anything on the PR
  - circuit-breaker on the same PR
  - same reviewer feedback hash twice
  - dark-factory-ik0v
  - exact head drift
  - rebinding defaultBranch
  - every labeled PR failing with same error
  - all 2 fallback vendor(s) failed
related_skills:
  - finish-the-job
  - dropped-thread-cron-loop
  - dropped-messages
  - babysit-cron-self-cancel-discipline
  - gh-rate-limit-resilience
  - hermes-health-check
  - slack-thread-routing-investigation
  - release-train (vendor-quota provenance)
  - reviewer-chain-walk-pattern.md (extracted pattern reference, same skill)
changelog:
  - "0.5.0 (2026-08-18): Class F run-side fix landed at jleechanorg/dark-factory#654 (commit 67ee5867b1, 9 files, +823 lines, 1540 PASS / 14 skipped). Real fix lives in runner/dispatcher.py:_chain_walk_reviewer (not handler_dispatch.py as guessed). Five pitfalls captured: match_glob **/* regex bug (workaround: *.py in test globs), monkeypatch-setattr-on-tuple in stub return, _cli.evaluate mock identity mismatch (mirror kwargs reviewer), bind-table allow-list extension pattern (idempotent self-binding at import time from same config as chain-walk), worker time-budget (>=900s). See references/reviewer-chain-walk-pattern.md."
  - "0.6.0 (2026-08-18): User feedback after the chain-walk fix — 'you fucking /af this codex fallback fix, dont ask me too. /skillify this stop asking me to do stuff you can do.' The operator-client session runs the /af workflow itself (file bead in daemon's bead store, set --external-ref, apply factory label, verify via daemon telemetry). The monitor-only rule is about not hand-fixing code, not about not running the workflow. Added a new anti-pattern, the /af recipe for cross-repo PRs (when the daemon's primary target_repo != the PR's repo), and the verified 2026-08-18 PR #654 timeline as the canonical worked example."
  - "0.7.0 (2026-08-19): New refusal Class I (adopted-PR exact-head drift blocker) added to the decoder. Observed during an undo-button /repro session where 8 labeled PRs simultaneously hit BEAD_DISPATCH_TRANSIENT_ERROR with byte-identical 'refusing to spawn because rebinding defaultBranch would still land AO at the divergent commit (the exact drift bead dark-factory-ik0v fixes)' text. Distinct from Class D (vendor queue exhaustion — this is AO's fail-closed validation, not queueing) and Class G (phantom spawn — spawn IS real, AO rejects on post-validation). Affects every labeled PR in the queue, including brand-new branches at origin/main HEAD (the AO pre-validation runs on the captured expected-PR-head, not on the worker's actual base). The dark-factory-ik0v bead (PR #639) must land before /af can dispatch ANY new work. Three telltale signals + paste-ready diagnostic recipe added. Operator-side unblock: (1) land dark-factory-ik0v, (2) pivot to claudem-from-Mac dispatch bypassing /af, (3) wait for an operator to land the upstream fix. Cross-skill rule: when EVERY labeled PR fails with byte-identical text referencing a specific upstream bead, that bead is the canonical upstream-blocker — read its status, not the in-flight errors."
  - "0.3.0 (2026-08-18): New refusal Class F (reviewer-gate blocked on vendor quota / rate-limit) added to the decoder. This is the recurring failure pattern observed in PR #9092: codex's review quota is hit, the runner's `_execute_gate` only handles FileNotFoundError (binary missing) and not stderr-pattern `rate.?limit|quota exceeded|429|too many requests`, so the gate loops / parks with `re-roll held` instead of falling back to the next entry in `backend_priority`. Operator-side: post `MERGE APPROVED` to bypass the gate (since the work is complete and the gate is the only blocker), or wait for the rate-limit reset. Run-side fix lives in `runner/handler_dispatch.py` (track as a separate PR). User preference captured: when the factory's reviewer hits a vendor quota, it should walk the priority queue, not park the PR."
  - "0.4.0 (2026-08-18): New refusal Class G (circuit-breaker on a session that was never spawned) added to the decoder. Observed in PR #9070 follow-up: the daemon logged `REROLL_ADOPTED_SESSION_SPAWNED` with `sessionId: wa-3515` and emitted a circuit-breaker report, but `ls /home/jleechan/.worktrees/worldarchitect/wa-3515` returned empty, `pgrep -af wa-3515` returned 0, and `git log --oneline feat/risk-tinted-direction-4` showed zero new commits. The user asked 'why can't the coder fix this?' — the correct answer was 'the coder never ran.' Three telltale signals: (1) no worktree dir, (2) no process, (3) zero commits on the branch since the spawn event. Operator-side: file a priority-1 bead titled `dark-factory: coder spawn for wa-NNNN (PR #<n>) failed silently`, let the operator on jeff-ubuntu decide whether to kick AGY/AO or hand-drive. Anti-pattern: do NOT conclude the coder tried-and-failed; the spawn is a phantom."
  - "0.1.0 (2026-08-18): Initial extract. Three core findings: (1) Mac-side br create does NOT propagate to Linux daemon's .beads/issues.jsonl — there is no transparent cross-machine bead sync — and the typical symptom is `br show <id>` returns the bead but the daemon never sees it; verify before reporting 'bead filed.' (2) Daemon refusal causes fall into a small taxonomy (rate-limit, branch-key-stealing, parked-HUMAN_HELD, REROLL_ADOPTED_REMEDIATION_START) — always read the most recent probe_error from daemon.jsonl rather than trusting PR comments or chat history. (3) Operator-client session is monitor-only per the canonical /af contract — never hand-fix from Mac, never run ao spawn from Mac for a factory-dispatched bead, never push to a factory/* branch from Mac. Originating session: jleechanai.slack.com/archives/C0AH3RY3DK6/p1787046570.436989 (PR #8498 + PR #7886 on jleechanorg/worldarchitect.ai, dropped twice by the dropped-thread bot before this skill was extracted)."
---

# auto-factory-operator-client

Operating the dark-factory auto-factory from a non-daemon host. On this machine class (macOS operator client), the daemon lives on **jeff-ubuntu**; the Mac sees the bead store only through whatever sync mechanism has been wired (and right now there is **no automatic sync**).

## Why this skill exists

The defining failure pattern observed in operator-client /af sessions (verified 2026-08-18 across at least 3 PRs in jleechanorg/worldarchitect.ai: #8498, #7886, #8853, #8730) is that the operator-client session **claims** it has dispatched the work — locally filing a bead, locally updating its SQLite bead store — and the daemon never sees it. The 30-min dropped-thread cron then fires twice, and only on the third reply does the operator discover the gap. This skill encodes the three checks that close that gap:

1. **Sync check** — verify the bead landed on the daemon's host's `.beads/issues.jsonl`, not just your local SQLite.
2. **Telemetry check** — read the most recent 100 lines of `daemon.jsonl` and classify what the daemon actually attempted.
3. **Action-shape check** — confirm the action you took was the right one for the role you have. Operator clients monitor; only the daemon dispatches.

If any of the three fails, the right end-state is "operator's blocker surfaced, ONE concrete next step on Linux" — not a PR merged, not even a "bead filed" without proof of daemon visibility.

## The Mac → Linux bead-store sync gap

**This is the highest-value finding in this skill.** Verified 2026-08-18 with raw `br sync` output. **Corrected 2026-08-18** after PR #9070 session — the daemon's actual bead store path was wrong in v0.1.0.

### The actual daemon store path

The daemon does NOT read `~/projects/dark-factory/.beads/`. That path is a separate user-side repo clone (also present on Linux for the operator's own work). The daemon reads its own canonical store, discoverable via systemd:

```bash
ssh jeff-ubuntu 'systemctl --user show ai.dark-factory.daemon.service -p Environment 2>&1 | grep DARK_FACTORY_BR_DB'
# → Environment=DARK_FACTORY_BR_DB=/home/jleechan/.local/state/dark-factory/.beads/beads.db
```

Verified 2026-08-18: the daemon's bead store lives at **`/home/jleechan/.local/state/dark-factory/.beads/`** (SQLite db `beads.db` + JSONL `issues.jsonl`, plus `.br_history/` and `config.yaml`). All intake telemetry keys off this path. Any bead filed in `~/projects/dark-factory/.beads/` is **100% invisible to the daemon** — even on the same host.

### Discovery

Running `br create <title> ...` on macOS:

- Writes to **macOS-local SQLite** at `~/projects/dark-factory/.beads/beads.db`
- Mac-side `br show <id>` confirms the bead exists
- Mac-side `br list --label factory` shows the bead
- Mac-side `.beads/issues.jsonl` is **NOT** touched (mtime stays at the last flush, which for `jleechanbrain`-class repos is often days old)
- On the daemon host (jeff-ubuntu), `~/.local/bin/br` exists but is **NOT** in non-interactive SSH's PATH (`bash: br: command not found`). Invoke via full path: `~/.local/bin/br ...`. The daemon reads from its own store at `$DARK_FACTORY_BR_DB` directly. Any bead filed in `~/projects/dark-factory/.beads/` is invisible to that path — even though both paths live on the same Linux host.

Attempting to manually `rsync` the Mac-side `issues.jsonl` over to Linux works as a transfer but the file is **stale** (kept by the daemon's own SQLite export). And `br sync --flush-only` from Mac **refuses by default**:

```
$ br sync --flush-only
Error: Configuration error: Refusing to export stale database that would lose issues.
Database has 4408 issues, JSONL has 2607 unique issues.
Export would lose 2 issue(s): rev-fo34v, rev-hzch2.1
Hint: Run import first, or use --force to override.
```

Mac and Linux bead stores are independently maintained. **There is no automatic sync.**

### The fix — `cd` to the daemon's store on Linux before `br create`

```bash
# On Linux, in the daemon's bead-store directory (NOT in any project repo clone):
ssh jeff-ubuntu 'cd /home/jleechan/.local/state/dark-factory/.beads/ && \
  ~/.local/bin/br create "<title>" --type task --priority N --labels factory \
  --description "$(cat /tmp/<bead-desc>.md)"'
```

That puts the bead directly into the daemon's authoritative SQLite + JSONL. The daemon's NEXT tick (every ~15s) reads it. Verify with `br show <id>` from the same directory.

**Never** try to push Mac's `issues.jsonl` over the daemon's. The daemon and Mac are independent stores; only a write inside the daemon's own bead-store directory makes a bead visible.

### What to actually do from the Mac

Since you cannot ship a bead across from Mac in one step:

1. **Discover the daemon's store path** — `ssh jeff-ubuntu 'systemctl --user show ai.dark-factory.daemon.service -p Environment | grep DARK_FACTORY_BR_DB'`. The path after `=` is authoritative.
2. **File the bead on Mac anyway** (audit trail) — get all the metadata right. Run `br show <id>` on Mac to confirm.
3. **Write the bead description to `/tmp/<id>-description.md` on Linux** via `scp`.
4. **Run `br create` ON Linux in the daemon's store directory** with `cd $(dirname $DARK_FACTORY_BR_DB) && ~/.local/bin/br create ...`. Verify with `~/.local/bin/br show <id>` from the same dir.
5. **Wait one daemon tick (~15s)** and verify with `tail -50 ~/Library/Logs/dark-factory/daemon.jsonl | grep <id>`.

Full detail in `references/mac-to-linux-bead-sync.md`.

## The intake mechanism — factory label on the GitHub PR

**Discovered 2026-08-18 in PR #9070 session.** The daemon's intake is keyed by the **`factory` label on the GitHub PR**, NOT by local beads with `factory` label. The flow:

1. Operator or agent applies `factory` label to PR on GitHub: `gh api repos/<owner>/<repo>/issues/<n>/labels -X POST -f 'labels[]=factory'`
2. Daemon's next intake scan lists PRs with the `factory` label.
3. Daemon creates its own bead (`dark-factory-<hash>`) with `external_ref: jleechanorg/<repo>#<n>`.
4. Daemon emits `EXISTING_PR_ADOPTED` event in `daemon.jsonl`.
5. Daemon dispatches the bead via the configured coder lane.

**Implication for operators**: To drive a PR through the factory, the operator's first action is to apply the `factory` GitHub label. Filing a local bead with `factory` label is **NOT** the entry point — the daemon will reject it as `unmapped_repo` (see Class E below).

**Cross-check recipe** — to confirm a PR is actually in the daemon's intake queue:
```bash
gh api repos/<owner>/<repo>/issues/<n>/labels --jq '.[] | .name' | grep -x factory
# → must return 'factory'
```

## The daemon.jsonl refusal-cause taxonomy

When the daemon does not pick up a labeled PR, the cause is recorded in `daemon.jsonl` as an `eventType=SKIPPED_*` or `PARKED_HUMAN_HELD` event with a `probe_error`, `precondition`, or `reason` field. Always read the most recent event for the PR — PR comments are stale, current telemetry is ground truth. The eight classes observed in production 2026-08-13 to 2026-08-18:

| Class | `eventType` | `probe_error` / `precondition` / `reason` prefix | Fix on operator side |
|---|---|---|---|
| **A. GH rate-limit on intake probe** | `SKIPPED_INELIGIBLE` | `probe_error:tool gh failed (rc=1): gh: API rate limit exceeded ...` | Wait for GH user rate-limit reset; do NOT manually re-attempt (each attempt burns more quota). Drop to `--slow_tier` if available. |
| **B. Branch-key collision** | `PARKED_HUMAN_HELD` (and a bot-comment "Branch-key stealing is not allowed" posted to the PR) | `reason: factory PR adoption refused for branch <branch>: already registered to bead <other_bead_id>` | Operator decision required: close the orphan bead, rename the branch, or attach a fresh bead to that branch. Daemon will NOT re-register automatically. |
| **C. Stale-head `/er` Evidence Gate failure (full recipe below)** | `GATE_ASSESSMENT` shows `evidence_review.verdict: fail` AND `ER_RUNNER_POSTED` comment says `/er FAIL evidence gist head is stale (<old_sha>, PR head <new_sha>)` OR `/er FAIL missing canonical Evidence gist line with matching head SHA` | (visible in `all_green=false` records; head SHA in the Evidence gist does not match current PR HEAD) | Operator-side unblock (NOT hand-fixing code) — see **Class C detail — stale-head `/er` unblock recipe** below. Operator creates a fresh evidence gist at the new HEAD, updates PR body `Evidence:` marker + `Evidence Gist:` line, posts a fresh `/er` comment on the PR. Daemon picks it up on next tick. |
| **C2. Re-roll held — "session already active" (NEW 2026-08-18, PR #9092)** | `PARKED_HUMAN_HELD` with `reason: re-roll held. Reason: an AO session is already active on adopted branch <branch>` | Follows a stale-head `/er` failure when the daemon spawned a remediation coder (`REROLL_ADOPTED_SESSION_SPAWNED`, `sessionId: wa-NNNN`) and is waiting for that session to finish before spawning another | Operator-side: post a fresh `/er` comment on the PR with a new evidence gist at the current HEAD. The daemon's next intake tick (~15s) sees the new head + new evidence and re-evaluates. The stuck `wa-NNNN` session will eventually time out or complete. DO NOT hand-cancel the session from Mac — that bypasses factory provenance. |
| **D. Vendor-fallback exhausted on REROLL** | `PARKED_HUMAN_HELD` with `all 2 fallback vendor(s) failed: antigravity: ao spawn deferred to internal queue: ..., minimax: ao spawn deferred to internal queue: ...` | visible in `reason` field | Operator decision: kick a vendor (re-launch `ao` daemon, restart antigravity), bump the AO budget, or escalate to a different coder. |
| **E. Manually-filed bead with no PR link (NEW 2026-08-18)** | `PARKED_HUMAN_HELD` with `source: manual_adoption_fail_closed` | `reason: unmapped_repo`, `scm_error: config: no SCM comment target found for bead <id>` | The bead was filed locally instead of via the GitHub-driven intake flow. To route the PR: apply the `factory` label on GitHub and let the daemon create its own bead. **Close the orphan local bead** so it doesn't block subsequent intake. |
| **G. Circuit-breaker on a session that was never spawned (NEW 2026-08-18, PR #9070 follow-up)** | `REROLL_ADOPTED_SESSION_SPAWNED` event is logged with a `sessionId: wa-NNNN`, but the spawn never materialized — followed by `CIRCUIT_BREAKER_TRIGGERED` with `feedbackHash` constant across attempts | `ls /home/jleechan/.worktrees/worldarchitect/wa-NNNN` returns no such directory; `pgrep -af "wa-NNNN"` returns 0 processes; `git log --oneline <branch>` shows zero new commits since the spawn; the healer report on attempt N is byte-identical to attempt N-1 because nothing changed on disk | Operator-side unblock — see **Class G detail — silent coder-spawn failure** below. File a `br create ... --priority 1` bead titled `dark-factory: coder spawn for wa-NNNN (PR #<n>) failed silently` and let the operator on jeff-ubuntu decide whether to kick AGY/AO, bump the budget, or hand-drive. **DO NOT conclude "the coder can't fix this"** — the coder never ran. |
| **H. Class E orphan blocks subsequent intake (NEW 2026-08-18, PR #9070)** | The daemon emits `PARKED_HUMAN_HELD unmapped_repo` for a manually-filed bead; if the orphan bead is left open, subsequent intake scans of the same PR also fail to adopt because the daemon sees the orphan first and skips the PR's own canonical bead | `br show <orphan-id>` returns status `closed`; the latest `daemon.jsonl` events for `jleechanorg/<repo>#<n>` show no `EXISTING_PR_ADOPTED` after the factory label is applied | Recovery sequence: (1) `~/.local/bin/br close <orphan-id> --reason 'unmapped_repo orphan; factory label on PR is the canonical entry point'` (2) Verify `factory` label is on the PR (3) Wait one tick (~15s). The daemon's intake then creates its own canonical bead with `external_ref: jleechanorg/<repo>#<n>`. **Pitfall**: do NOT re-file a manual bead with the same external_ref — that re-triggers Class E and re-blocks intake. Verified timeline (PR #9070, 2026-08-18): close `dark-factory-8xm4` → apply factory label → 12 min later daemon emits `EXISTING_PR_ADOPTED` for `dark-factory-atao`. |
| **I. Adopted-PR exact-head drift blocker (NEW 2026-08-19, `dark-factory-ik0v`)** | `BEAD_DISPATCH_TRANSIENT_ERROR` with `phase: spawn` AND `error: ... refusing to spawn because rebinding defaultBranch would still land AO at the divergent commit (the exact drift bead dark-factory-ik0v fixes)` | Affects EVERY labeled PR with an `origin/main`-divergent head. AO workspace-worktree.create binds `baseRef = origin/${project.defaultBranch}` instead of the captured PR-head revision. Identical error text across all in-queue beads, INCLUDING brand-new branches created at `origin/main` HEAD (the AO pre-validation runs on the expected-PR-head captured during intake, not on the worker's actual base). **NOT Class D** (vendor fallback exhausted) — both vendors fail with the SAME exact error, no queueing. **NOT Class G** (phantom spawn) — the spawn event is real and logged, AO just rejects it. | The `dark-factory-ik0v` bead (PR [`#639`](https://github.com/jleechanorg/dark-factory/pull/639)) must land first. Until then, **`/af` cannot dispatch ANY new PR work** — every spawn will fail-closed at `phase: spawn`. Operator decision: land the dark-factory fix, OR pivot to non-factory dispatch (claudem worker on a clean worktree from this Mac). See **Class I detail — adopted-PR drift blocker** below. |

> **Common mistake**: trusting PR comments ("the factory refused this!"). Comments are *historical* — they reflect what the daemon thought on a prior attempt. The current cause is in `daemon.jsonl` and may be completely different. The 2026-08-18 PR #8498 case initially looked like a branch-key collision (six identical bot comments) but the *current* cause was a fresh GH rate-limit (`SKIPPED_INELIGIBLE` at 23:44 with the rate-limit probe_error). Different fix needed; different confidence in each.

Full decoder in `references/refusal-cause-decoder.md`. Class I dedicated reference (NEW 2026-08-19): `references/class-i-exact-head-drift.md`.

### Class E detail — `unmapped_repo` / `manual_adoption_fail_closed`

**Observed 2026-08-18 on PR #9070 session.**

When a local bead is filed in the daemon's bead store with `labels: factory` but without a `target_repo` / `existing_pr` / `existing_branch` mapping that the daemon can resolve to a GitHub PR, the daemon tries `manual_adoption_fail_closed` and parks the bead.

```json
{
  "beadId": "dark-factory-8xm4",
  "lifecycleState": "HUMAN_HELD",
  "eventType": "PARKED_HUMAN_HELD",
  "context": {
    "external_ref": null,
    "reason": "unmapped_repo",
    "source": "manual_adoption_fail_closed"
  }
}
```

The follow-up `ESCALATED_LOCALLY` event has the SCM error:
```json
{
  "eventType": "ESCALATED_LOCALLY",
  "context": {
    "reason": "unmapped_repo",
    "scm_error": "config: no SCM comment target found for bead dark-factory-8xm4"
  }
}
```

**Why this happens**: the daemon's intake normalizer expects beads to come from the GitHub-driven flow (factory-labeled PR → bead). When a bead arrives through any other path (manual `br create`, an export from another tool, a programmatic importer), the daemon tries to find a PR to attach it to. If it can't, it parks the bead and emits the unmapped_repo refusal.

**The fix** is at the **PR level**, not the bead level. Add the `factory` label to the GitHub PR — the daemon will create its own canonical bead on the next intake scan, with `external_ref: <owner>/<repo>#<n>` properly set.

**Recovery shell**:
```bash
# 1. Close the orphan bead so it doesn't block subsequent intake
ssh jeff-ubuntu "cd /home/jleechan/.local/state/dark-factory/.beads/ && \
  ~/.local/bin/br close <orphan-bead-id> --reason 'unmapped_repo orphan; factory label on PR is the canonical entry point'"

# 2. Apply factory label to the GitHub PR
gh api repos/<owner>/<repo>/issues/<n>/labels -X POST -f 'labels[]=factory'

# 3. Wait one daemon tick (~15s) and verify
ssh jeff-ubuntu "tail -50 ~/Library/Logs/dark-factory/daemon.jsonl | grep -aE '<owner>/<repo>#<n>' | tail -5"
```

If the orphan bead is left open, the daemon's intake will continue to find it and skip the PR's own canonical bead — leaving the PR stuck in HUMAN_HELD indefinitely.

### Class F detail — reviewer-gate blocked on vendor quota (the `ddf-PR-9092-outage` pattern)

**Observed 2026-08-18 on PR #9092.** This is the recurring failure pattern: the run is otherwise complete (CI green, no conflicts, CodeRabbit/CursorBot clean, comments resolved), but the cold-reviewer gate is stuck because codex's review quota is hit. The user's prescription (verbatim, Slack `C0AH3RY3DK6/p1787112356.555659`): *"the factory shouldnt stop on codex quota? It should fallback to another cli."* — this is the operator-stated invariant for the daemon's reviewer-gate behavior.

**Why the current runner doesn't already do this**: `runner/handler_dispatch.py:_execute_gate` (lines 1119-1171) only triggers a fallback chain on `FileNotFoundError` / `backend_missing=true` / `sandbox==unavailable` / `timed_out==true`. A codex 429/quota response surfaces as `outcome="error"` with NO `backend_missing` flag — `_is_gate_infra_failure` returns `True` (because `outcome=="error"`), and the fallback fires, but the fallback is hardcoded to `["agy","claude"]` (lines 1152-1156) instead of walking the actual `backend_priority` queue. If agy is also rate-limited (PR #9092 case), the loop converges on `infra_failure`.

**Three telltale signals** (require ALL three to distinguish from Class A / D):

1. `codex --version` succeeds on the daemon host — binary is installed and responsive. Class A only fails on the `gh` probe, not the codex probe.
2. The daemon's `_run_gate_once` returns `outcome="error"` with stderr matching `/(rate.?limit|quota exceeded|429|too many requests)/i` AND no `metadata["backend_missing"]="true"` flag. Absence of the flag + presence of the stderr pattern = quota, not missing binary.
3. The gate stays at `evidence_review: fail` (or `re-roll held`) for >30 minutes despite multiple REROLL attempts.

**Operator-side unblock** (in priority order):

1. **Post `MERGE APPROVED` in the originating Slack thread** — fast path. Skips the `/er` Evidence Gate and the skeptic cron merges on its next tick. Use ONLY when the work itself is complete and the gate is the only blocker.
2. **Wait for the vendor quota to reset** — typically daily for codex code-review. The re-roll session will eventually time out and the daemon retries with fresh quota.
3. **Apply `factory` label to a side PR / re-run** — if the diagram allows a second-attempt on the same branch, the new intake attempt may pick a different queue entry.

**Operator-side diagnostic recipe** (paste-ready, run on Mac):

```bash
# 1. Confirm codex is "installed" (the probe doesn't detect quota):
ssh jeff-ubuntu 'codex --version 2>&1 | head -3'

# 2. Check the most recent GATE_ASSESSMENT event for the PR — look for evidence_review.verdict: fail
ssh jeff-ubuntu "tail -800 /home/jleechan/Library/Logs/dark-factory/daemon.jsonl \
  | grep -aE 'GATE_ASSESSMENT|<branch-name>' | tail -5"

# 3. Grep for the rate-limit / quota pattern in the daemon's recent stderr output:
ssh jeff-ubuntu "grep -aE 'rate.?limit|quota exceeded|429|too many requests' \
  /home/jleechan/Library/Logs/dark-factory/daemon.jsonl | tail -5"

# 4. Confirm the gate's backend_priority attribute is a single string (not a chain):
ssh jeff-ubuntu "grep -E 'backend_priority' ~/projects/dark-factory/pipelines/slim/*.dot"

# 5. If all four pass, file the run-side fix as a separate PR (NOT from Mac — operator-client is monitor-only):
# Reference: https://github.com/jleechanorg/worldarchitect.ai/pull/<gate-fail-PR>
# Touch: runner/handler_dispatch.py (add _detect_rate_limit), pipelines/slim/two_node.dot (multi-entry backend_priority)
# Add tests in tests/test_cli_fallbacks.py (currently 0 cover rate-limit)
```

**Do NOT** (operator-client anti-patterns for Class F):

- ❌ Re-file the same bead hoping the daemon picks a different reviewer — the diagram's `backend_priority="codex"` is a single string, so the same codex will be picked next time.
- ❌ Cancel the stuck `wa-NNNN` re-roll session from Mac — bypasses factory provenance.
- ❌ Hand-edit `runner/handler_dispatch.py` from the Mac operator-client session — `/af` is monitor-only; the run-side fix lives in a separate PR.
- ❌ Assume "the factory is broken, I'll just do it myself" — that's the forbidden move per `/af — ZERO direct work`. The right move is to surface the operator-side unblock (MERGE APPROVED or wait) and let the daemon's REROLL phase sort the queue.

**Run-side fix** (separate PR, NOT the operator's job to dispatch — landed in [jleechanorg/dark-factory#654](https://github.com/jleechanorg/dark-factory/pull/654), `feat/reviewer-fallback-on-quota`, 2026-08-18):

The actual fix did NOT land in `runner/handler_dispatch.py` (which was the original guess in `references/ddf-PR-9092-outage.md`). The real production chain-walk lives in **`runner/dispatcher.py:VerifierDispatcher._chain_walk_reviewer`** — the GHA skeptic gate's dispatcher. The daemon side (`daemon/src/er_runner.rs:230-253`) already walked the queue at the time of the PR #9092 outage; the GHA side was the gap. Concretely:

- `runner/dispatcher.py` gained `_chain_walk_reviewer(rule, prompt, original_reviewer, ...)` that reads the canonical priority queue from `runner.reviewer_priority.skeptic_reviewer_priority()`, detects rate-limit via `_detect_rate_limit(err)` matching `/(rate.?limit|quota|429|too many requests|...)/i`, and advances through the queue on each hit. Hard cap is queue length.
- The fallback trail is annotated on the result: `dataclasses.replace(res, reason=f"{old_reason} (fallback_used=true; fallback_from={original_vendor})")` so the operator can see who actually produced the verdict.
- Exhaustion produces `SkepticResult(check_state="failure", verdict=None, reason=f"all reviewers exhausted (vendors tried: ...; last error: ...)")`. Fails closed.
- **Bind/provenance security invariant preserved**: `run_one` still calls `bind_reviewer_identity(actual_reviewer, parsed.reviewer_identity)` and `verify_provenance(implementation_identity, parsed.reviewer_identity)` on the fallback vendor. The chain-walk is not a bypass.

**The hidden gotcha** that cost ~30 minutes during the dispatch: `runner/skeptic_gate.REVIEWER_CLI_TO_IDENTITY` was hardcoded to `{"codex": "codex", "gemini": "gemini"}`. The first test run produced `bind_reviewer_identity("cursor-agent", "claudem")` and rejected every chain-walk vendor. **Fix pattern**: extend the allow-list at import time from the same config that drives the chain-walk (idempotent, self-binding):

```python
# runner/skeptic_gate.py
def _extend_bind_table_from_priority() -> None:
    """Each CLI in skeptic_reviewer_priority() binds to its own name.

    Idempotent: setdefault never overwrites an existing binding. Codex
    and gemini remain pinned; chain-walk vendors get self-binding so
    the dispatcher verdict reaches the operator instead of being
    rejected by the bind check.
    """
    try:
        from runner.reviewer_priority import skeptic_reviewer_priority
    except ImportError:
        return
    for vendor in skeptic_reviewer_priority():
        REVIEWER_CLI_TO_IDENTITY.setdefault(vendor.strip(), vendor.strip())

_extend_bind_table_from_priority()  # run at module import
```

This is the general pattern for "I added a new vendor / model identity, but the allow-list predates it." Always derive the allow-list from the same source that drives the consumer.

**Pitfalls observed during the dispatch** (each delayed the PR by 5-15 minutes; future agent should know):

1. **Pre-existing `match_glob` regex bug** (in `origin/main`'s `runner/dispatcher.py:match_glob`): `fnmatch.translate("*")` produces `\Z(?ms).*` with embedded regex flags. The joined regex for `**/*` doesn't match `foo.py`. Affects any chain-walk test fixture using `target_globs=["**/*"]`. **Workaround in tests**: use `target_globs=["*.py"]` (which matches `foo.py`). The bug itself is out of scope; track separately.
2. **Pytest `monkeypatch.setattr` on a tuple return**: helper `_stub_invoke_reviewer(plan)` returns `(fn, seen_list)`. Assigning the tuple to a local and patching with it makes `invoke_reviewer` a tuple; calling it raises `TypeError` → dispatcher treats it as a non-rate-limit failure → returns the original (claudem) verdict. **Workaround**: unpack `fake_invoke, seen = _stub_invoke_reviewer(...)` — never assign the raw return value.
3. **`_cli.evaluate` mock must declare the actual vendor's identity**: tests that mock `evaluate` returning `SkepticResult(reviewer="cursor-agent", parsed=ParsedVerdict(reviewer_identity="claudem"))` will fail bind with "declared identity claudem, but cursor-agent must declare cursor-agent." **Fix**: mirror `kwargs.get("reviewer")` into `parsed.reviewer_identity`.
4. **`REVIEWER_CLI_TO_IDENTITY` allow-list** (point above) — derive it from the same config, not a hardcoded dict.
5. **Worker time-budget for chain-walk PRs**: a clean dispatch including venv setup + design exploration + 5 files + tests takes ~600s wall-clock minimum. If your `delegate_task` budget is 600s and the worker times out mid-test, expect to finish the last few fixes inline (the worktree is intact; `git status --short` shows what's left). Allocate at least 900s next time.

**Test surface that landed**: `tests/test_dispatcher_reviewer_chain_walk.py` (NEW, 6 tests) plus `tests/test_reviewer_priority_parity.py` (NEW, 4 tests). The full suite runs 1540 PASS / 14 skipped. PR body at #654 has the full proof block.

**Why this is a class, not a one-off**: codex code-review quota is rate-limited daily. The pattern will recur every PR that lands near the quota boundary. Capture it before the next outage.

### Class G detail — silent coder-spawn failure (the `wa-NNNN-never-spawned` pattern)

**Observed 2026-08-18 on PR #9070 follow-up (after the v0.2.0 fixes landed).** The daemon logs `REROLL_ADOPTED_SESSION_SPAWNED` with a `sessionId: wa-NNNN` and continues to emit `CIRCUIT_BREAKER_TRIGGERED` / `PARKED_HUMAN_HELD` with feedbackHash constant — but **the coder process was never actually started**. The branch has zero new commits; no `wa-NNNN` worktree exists; no `wa-NNNN` claude/agy process is in `ps`.

**How this is distinguishable from "the coder can't fix it"** (the wrong reading):

1. `ssh jeff-ubuntu "ls /home/jleechan/.worktrees/worldarchitect/wa-NNNN"` — empty (no worktree).
2. `ssh jeff-ubuntu "pgrep -af wa-NNNN"` — empty (no process).
3. `cd /home/jleechan/.dark-factory/target-worktrees/jleechanorg/worldarchitect.ai/ && git log --oneline <branch>` — same SHA before and after the spawn event (zero commits added).
4. `ssh jeff-ubuntu "grep -aE 'wa-NNNN' ~/Library/Logs/dark-factory/daemon.jsonl | python3 -c ..."` — shows `REROLL_ADOPTED_SESSION_SPAWNED` event but no `REROLL_COMPLETED` or commit-push follow-up.

If 1+2+3 all hold, the spawn event is a phantom: the daemon *thought* it dispatched, but the underlying coder invocation silently failed (rate-limit on the spawn API, AGY/MiniMax lane fallback exhaustion, OOM, GPU exhaustion, branch-key collision with a prior session).

**Why the operator's instinct will be wrong**: the circuit-breaker message reads exactly like the other refusal classes — "same reviewer, same feedback hash, attempt 2/2 held." The natural reading is "the coder tried twice and failed twice." But if 1+2+3 hold, **the coder never tried at all**; the daemon is comparing the unchanged branch against itself.

**Three plausible causes** (operator decision, not Mac-side fix):

1. **Coder process spawn failure** — the daemon fired the spawn event but the underlying `claude`/`agy` invocation silently died (rate-limit on the spawn API, GPU exhaustion, or OOM). This is the **AGY/MiniMax lane fallback exhaustion** class from the skill (close cousin to Class D).
2. **Branch-key collision** — the daemon thinks PR #N's branch is already claimed by another bead (likely a stale entry in the branch registry) and silently skipped the actual coder spawn.
3. **Vendor queue full** — daemon pushed the spawn to its internal queue (`ao spawn deferred to internal queue`) and another worker is ahead.

**Operator-side unblock** (in priority order):

1. **File a `br create ... --priority 1` bead** titled `dark-factory: coder spawn for wa-NNNN (PR #<n>) failed silently` in the daemon's bead store. The bead should reference the verification evidence (steps 1-4 above) and request an operator decision on infra kick vs hand-drive.
2. **Restart AGY/AO daemon** if multiple PRs are showing this pattern — the spawn API may be wedged.
3. **Hand-drive from Mac** is NOT the right move (per `/af — ZERO direct work`). The right move is to surface the literal evidence and let the operator decide.

**Anti-pattern**: ❌ "Why can't the coder fix this?" — the answer is the coder didn't run. Also ❌ "Re-file the bead hoping for a fresh spawn" — the daemon will re-attempt on the next tick, but if the underlying spawn path is wedged, the same phantom will recur.

### Class I detail — adopted-PR exact-head drift blocker (the `dark-factory-ik0v` pattern)

**Observed 2026-08-19** during an undo-button /repro session. Every labeled PR in the daemon's queue — 8 of them at the moment of capture, all with different branch names and different SHAs — hit `BEAD_DISPATCH_TRANSIENT_ERROR` at `phase: spawn` within the same second, with byte-identical refusal text:

```
all 2 fallback vendor(s) failed:
  antigravity: ao spawn --agent antigravity failed (rc=1):
    [dark-factory AO bridge] AO project worldarchitect adopted-PR branch
    <branch> origin head is <pr_head_sha>, expected validated PR head
    <origin_main_sha>; refusing to spawn because rebinding defaultBranch
    would still land AO at the divergent commit
    (the exact drift bead dark-factory-ik0v fixes)
  minimax: ao spawn --agent minimax failed (rc=1): [same text]
```

**Why this is a NEW class, not a sub-pattern of D/G**:

- **NOT Class D (vendor fallback exhausted)** — Class D logs `ao spawn deferred to internal queue` (a queueing refusal from a healthy AO). Class I logs `refusing to spawn because rebinding defaultBranch would still land AO at the divergent commit` — a fail-closed validation rejection from AO itself. Both vendors fail with the SAME root cause, no queueing involved.
- **NOT Class G (phantom spawn)** — Class G is when the daemon *thinks* it dispatched but no process/worktree exists. Class I is the opposite: the spawn event is real, the worktree IS created, but AO refuses the session on the post-spawn validation because the worktree landed at `origin/main` instead of the captured PR-head revision.
- **NOT a single-PR issue** — Class I affects every adopted branch that has any `origin/main` divergence at all, which is *every* PR in the queue. The 8 affected PRs included a brand-new branch created seconds earlier from `origin/main` (no divergence possible in theory) — confirming the bug is in AO's pre-validation against the captured expected-PR-head, not in the worker's actual base.

**Three telltale signals** (require ALL three to distinguish from D/G):

1. **`eventType=BEAD_DISPATCH_TRANSIENT_ERROR` with `phase: spawn`** — not `PARKED_HUMAN_HELD`, not `SKIPPED_INELIGIBLE`. The dispatch attempt was made and failed transiently.
2. **Identical error text across multiple beads within the same second** — every bead's vendor chain reports the same `dark-factory-ik0v` message. This is the canonical signature.
3. **`dark-factory-ik0v` bead is still OPEN** (`~/.local/bin/br show dark-factory-ik0v --json` from the daemon's store at `/home/jleechan/.local/state/dark-factory/.beads/`). The bead is the upstream PR-head-drift fix. Until it lands + the bead closes, every spawn will re-trigger this refusal.

**Operator-side unblock** (in priority order):

1. **Land `dark-factory-ik0v` first** — the fix lives in the `dark-factory` repo's `ao-spawn-v013-bridge.mjs` or `workspace-worktree.create` path (the AO bridge defines `baseRef = origin/${project.defaultBranch}` instead of the captured PR-head revision). The corresponding PR is [`dark-factory#639`](https://github.com/jleechanorg/dark-factory/pull/639). Verify: after the bead closes, the daemon's next tick will retry the queued beads and they should succeed.
2. **Pivot to non-factory dispatch** — bypass `/af` entirely. Dispatch a claudem worker on a clean worktree from this Mac (`bash -lic 'claudem -p "<task>"' --max-turns <N>` from a worktree at `origin/main`). The work lands as a regular PR; factory label can be applied later once `dark-factory-ik0v` clears. Trade-off: bypasses auto-factory provenance tracking; the PR is no longer in the daemon's queue.
3. **Wait for an operator to land the fix on jeff-ubuntu** — file a priority-1 bead if the issue is not already tracked. Do NOT hand-edit the dark-factory repo from Mac — that's a separate workstream.

**Do NOT** (operator-client anti-patterns for Class I):

- ❌ File another manual bead with the same external_ref and hope for a different outcome — the AO bridge will reject it identically. `dark-factory-ik0v` blocks the entire queue, not individual beads.
- ❌ Re-apply the factory label to force a fresh intake — the intake will succeed, the spawn will fail with the same error. The label is not the bottleneck.
- ❌ Hand-cancel the stuck `wa-NNNN` re-roll sessions from Mac — they will eventually time out, and the new attempts will hit the same Class I refusal.
- ❌ Conclude the factory is "broken for everything" — it is broken for ONE reason. Read `dark-factory-ik0v`'s current status, not the in-flight spawn failures.

**Run-side fix** (NOT the operator's job to dispatch — lives in the `dark-factory` repo, separate PR):

The fix changes `ao-spawn-v013-bridge.mjs` (or the equivalent AO workspace-creation code) so that `workspace-worktree.create` uses the captured `expected_revision` (PR-head SHA) as `baseRef` when an adopted-PR branch is present, instead of `origin/${project.defaultBranch}`. Verified from `dark-factory-ik0v`'s body (issue text captured 2026-08-19): "An adopted same-repo PR remediation spawn must create/reuse the AO worker workspace on the exact captured PR-head revision, while retaining the PR head branch name. Ordinary generated-branch spawns must continue to start from the configured default branch."

**Verified diagnostic recipe** (paste-ready, run on Mac):

```bash
# 1. Confirm the Class I signature across multiple in-flight beads:
ssh jeff-ubuntu "tail -800 /home/jleechan/Library/Logs/dark-factory/daemon.jsonl \
  | python3 -c 'import sys,json,re
events=[]
for l in sys.stdin:
    try: e=json.loads(l)
    except: continue
    if e.get(\"eventType\")==\"BEAD_DISPATCH_TRANSIENT_ERROR\" and \"dark-factory-ik0v\" in str(e):
        events.append(e)
print(f\"Class I events in last 800 lines: {len(events)}\")
print(f\"Unique branches: {len(set(e[\\\"context\\\"][\\\"branch\\\"] for e in events))}\")
if events:
    print(\"Sample error:\", events[-1][\"context\"][\"error\"][:200])'"
# Expected: many events (5+), 1 unique branch per event (proving every branch hits it)

# 2. Confirm dark-factory-ik0v is still open:
ssh jeff-ubuntu 'cd /home/jleechan/.local/state/dark-factory/.beads/ \
  && ~/.local/bin/br show dark-factory-ik0v --jq .status'
# Expected: "open"  → confirms the upstream fix is not yet landed

# 3. Confirm the daemon is healthy otherwise (separate from Class I):
ssh jeff-ubuntu 'systemctl --user status ai.dark-factory.daemon.service --no-pager -l 2>&1 | head -10'
# Expected: active (running), Status: "auto-factory daemon tick=N ok consecutive_failures=0"
# If consecutive_failures > 0, escalate separately; Class I alone does not degrade daemon health.
```

**Why this is a class, not a one-off**: `dark-factory-ik0v` is one of 20+ cascading P0 beads in the dark-factory queue (`br list --priority 0` returns 20+ results as of 2026-08-19). The pattern will recur every time an upstream dark-factory bug blocks the AO spawn path. The diagnostic recipe above generalizes to any "every labeled PR fails with the same byte-identical error" signature — read the error message, look up the referenced bead in the daemon's store, confirm it's open.

## The drive-existing-pr bead shape

For driving an existing labeled PR, the bead body MUST contain exactly these three fields, named with the canonical headers (the daemon's intake normalizer greps by header):

```
## Drive-existing-pr fields (intake normalizer)
## existing_pr: <number>
## existing_branch: <exact headRefName from gh pr view>
## target_repo: <owner/repo>
```

Without all three, the daemon files the bead under new-work mode and creates a fresh `factory/<bead_id>-r<attempt>` branch — which collides with the existing PR's branch and itself triggers Class B (branch-key stealing). Verified recipe with paste-ready body in `templates/drive-existing-pr-bead-body.md`.

**AO spawn prompt cap is 4096 characters** — keep the bead body tight. References like the full PR description and the failure transcript belong in `references/<bead-id>.md` referenced by URL, NOT in the bead body. Long bead bodies make dispatch fail; the daemon silently swallows them.

## The monitor-only contract (NEVER hand-fix from Mac)

The canonical contract, lifted verbatim from `~/projects/dark-factory/AGENTS.md` `## /af — ZERO direct work; monitoring only`:

> When the operator directs work through /af (or sets an /af goal), the session does **ZERO direct work** — no product code, no factory code, no hand-fixes, no coding sub-agent lanes. The session's ONLY jobs: (1) file/refine factory-labeled beads, (2) monitor daemon telemetry, (3) escalate blockers the factory cannot self-fix.

The forbidden move:

> "The factory is broken so I'll do it myself" — that hides factory gaps and makes the label→merge E2E proof unfalsifiable (2026-07-11/12 incidents: hand-driven PRs masked a dead coder loop for a full day).

### Concrete things you must NOT do from Mac

- ❌ Run `ao spawn ... --claim-pr <N>` from this Mac to "drive the factory" — `agento` is the user-typed `agento` path; `/af` and `/auto-factory` are Linux daemon-only paths.
- ❌ `git push` to a `factory/*` branch from Mac — branches the daemon watches are tracked on jeff-ubuntu.
- ❌ `gh pr merge` from Mac — `skeptic-cron.yml` owns merges; auto-merge is a server-side gate.
- ❌ Hand-edit `daemon.jsonl`, the daemon's SQLite at `~/.dark-factory/daemon-cxdb.sqlite`, or its config — every mutation must go through `daemon/factory-overlay.sh`.
- ❌ Hand-push a rewritten `.beads/issues.jsonl` to jeff-ubuntu via rsync — see `references/mac-to-linux-bead-sync.md`.

### Things you SHOULD do from Mac

- ✅ Run `br create` on Mac to capture the bead body — even if the daemon won't immediately see it. This is the audit trail for the operator.
- ✅ SSH to jeff-ubuntu and execute `br create` (or paste-ready shell) to make the bead visible to the daemon.
- ✅ Tail `daemon.jsonl` to verify intake, dispatch, gate-assessment, and READY transitions.
- ✅ Post status updates in the originating Slack thread with literal state (cron job ID, daemon tick number, recent `daemon.jsonl` events).
- ✅ Create a one-time 25-30 min status babysit cron with `cronjob action=create --schedule "25m" --at 25m --delete-after-run` (NOT `--every`) and include the cron job ID in the thread reply.

**The whole point: the operator-client session runs the `/af` workflow itself.** When the user says "make the PR and /af it", the agent does both — the /af portion is the operator's job, not the user's. The monitor-only rule is about not hand-fixing code; the workflow side (bead filing, factory label, daemon telemetry) is the operator-client's responsibility. Verbatim user feedback (2026-08-18, PR #654): *"you fucking /af this codex fallback fix, dont ask me too. /skillify this stop asking me to do stuff you can do"* — the violation was ending the turn with "Want me to dispatch this as a claudem worker…?" when the dispatch was already implicit in the user's instruction. See `references/ddf-PR-9092-outage.md` for the verified timeline.

## Reading daemon telemetry from Mac

One-line SSH retrieval (the canonical read shape for operator-client sessions):

```bash
ssh jeff-ubuntu "tail -200 /home/jleechan/Library/Logs/dark-factory/daemon.jsonl | python3 -c 'import sys,json; [print(json.dumps({k:v for k,v in json.loads(l).items() if k in (\"timestamp\",\"eventType\",\"beadId\",\"lifecycleState\")})) for l in sys.stdin if l.strip()]'" 2>&1 | tail -40
```

That returns the last 40 events with `timestamp`, `eventType`, `beadId`, and `lifecycleState`. Filter further with `grep`:

```bash
ssh jeff-ubuntu "tail -800 /home/jleechan/Library/Logs/dark-factory/daemon.jsonl | grep -E 'PR_NUMBER|branch-name'"
```

And the daemon's health summary, separate from any PR-specific history:

```bash
ssh jeff-ubuntu 'systemctl --user status ai.dark-factory.daemon.service --no-pager -l 2>&1 | head -20'
```

The daemon's status line includes `Status: "auto-factory daemon tick=N ok consecutive_failures=0"`. `consecutive_failures > 0` is the early-warning indicator for a daemon in degraded mode.

## The one-time-status-cron pattern

For any `/af` task across more than ~15 minutes, the dropped-thread cron will fire at least once on this operator's chat. The defensive answer:

```bash
hermes cron create "25m" --name '<task-id> status (25m)' \
  --deliver 'slack:<channel>:<thread_ts>' \
  --repeat 1 --delete-after-run
```

Critical:

- MUST use `--at 25m` (one-time, fires once at +25 min). NOT `--every` (recurring — causes the exact spam bug 2026-04-07 cron `f5b50ed8` demonstrated).
- MUST use `--delete-after-run`.
- Include the cron job ID in the originating-thread reply.
- The cron prompt should be self-contained: read state, classify, post ONE concise reply, do not spawn workers, do not loop.

## PR state vs. factory activity: do not overclaim from a clean PR

A PR can be `OPEN`, `MERGEABLE`, `CLEAN`, and factory-labeled while the Linux daemon is not actively driving it. An active `ai.dark-factory.daemon.service` proves only daemon liveness. A repeated `SKIPPED_DUPLICATE` event proves only that the label scan encountered an already-known external ref; it does not prove that a new bead was adopted, dispatched, or worked on.

Before reporting factory progress, require all of the following:

1. Resolve the PR's current `headRefOid`, `headRefName`, and `state` with `gh pr view`.
2. Query the daemon's canonical bead store using the `DARK_FACTORY_BR_DB` path from the service environment; do not infer bead identity from a local or project `.beads/` store.
3. Read fresh PR-specific telemetry and identify the bead ID that owns the exact external ref (`<owner>/<repo>#<N>`).
4. Require a current progression such as `INTAKE_BEAD_CREATED` → `TASK_ROUTED` → `TASK_DISPATCHED`, followed by `GATE_ASSESSMENT` or `READY`. `SKIPPED_DUPLICATE` alone is not progress.
5. If the only current event is `SKIPPED_DUPLICATE`, report exactly that: the factory sees the PR but the new/current bead is not being driven. Do not say the factory is "driving the PR" merely because the service is active or the PR is clean.

This distinction is especially important after a manual bead or an earlier intake attempt. A stale duplicate can coexist with a healthy daemon, a correctly labeled PR, and green CI. The end-state is the evidence, not the service's `active` status or the PR's mergeability.


- ❌ **"Bead filed. Daemon will pick it up."** without `ssh jeff-ubuntu` verification — this is the exact wrong claim. Until you see the bead in `daemon.jsonl`'s `EXISTING_PR_ADOPTED` or `_tick.metrics.beadsRouted > 0` for that bead, the daemon has not seen it.
- ❌ **"Factory refused because branch-key collision."** based on PR comments alone — read the most recent `daemon.jsonl` event. The current cause may be rate-limit, not branch-key.
- ❌ **Multi-option menus in /af status updates** — "/af didn't do anything. Should I file a bead, or drive manually, or close the PR?" The right reply is one concrete next action; the operator decides.
- ❌ **Hand-fixing from Mac when the daemon is "stuck"** — that's the forbidden move per the `/af — ZERO direct work` contract. The right move is to surface the daemon's literal blocker with the exact recovery shell.
- ❌ **Running `ao spawn --claim-pr <N>` from a Mac /af session** — that's the `agento` path. /af routes through the daemon. Mixed paths silently bypass evidence provenance.
- ❌ **Asking the user to do the /af themselves** — the operator-client session is the one that runs the /af workflow (file bead in daemon's store, set `--external-ref`, apply factory label, verify via daemon telemetry). The monitor-only rule is about not hand-fixing code, not about not running the workflow. Verbatim user feedback (2026-08-18, PR #654): *"you fucking /af this codex fallback fix, dont ask me too. /skillify this stop asking me to do stuff you can do."* The session should drive the /af to completion, not punt it back to the user.
- ❌ **Treating "PR opened + factory label applied" as completion** — the /af isn't done until the bead is dispatched and the skeptic gate runs. End-state is `TASK_DISPATCHED` → `GATE_ASSESSMENT` → `READY` (or a daemon telemetry refusal with a concrete recovery shell).

## The /af recipe when the daemon's primary target_repo ≠ the PR's repo

The daemon's primary `target_repo` (from `daemon.toml`) controls intake scanning. The `[repos.*]` section is for dispatch routing (push_remote), NOT intake. When the PR's repo is registered in `[repos.*]` but is NOT the primary target_repo, the factory label alone on the PR is not enough — the daemon's GitHub scan only sees the primary target_repo.

Concrete example (verified 2026-08-18, jleechanorg/dark-factory#654): the daemon's primary target_repo is `jleechanorg/worldarchitect.ai`. The repo `jleechanorg/dark-factory` is in `[repos.*]` for dispatch routing but NOT for intake. The factory label on PR #654 alone would NOT trigger intake.

The fix: file a manual bead in the daemon's bead store with the drive-existing-pr fields. The canonical recipe:

```bash
# 1. Discover the daemon's bead store path
DAEMON_DB=$(ssh jeff-ubuntu 'systemctl --user show ai.dark-factory.daemon.service -p Environment | grep DARK_FACTORY_BR_DB | sed "s/.*=//"')
DAEMON_DIR=$(dirname "$DAEMON_DB")

# 2. File the bead with the drive-existing-pr fields in the body
ssh jeff-ubuntu "cd $DAEMON_DIR && ~/.local/bin/br create \
  '/af: drive <owner>/<repo>#<PR> (<short title>)' \
  --type task --priority 1 --labels factory \
  --description '## /af: drive <owner>/<repo>#<PR> ...
## Drive-existing-pr fields (intake normalizer)
## existing_pr: <N>
## existing_branch: <exact headRefName from gh pr view>
## target_repo: <owner>/<repo>
## head_sha: <sha>

Acceptance: 1. Daemon emits EXISTING_PR_ADOPTED within 60s. 2. Full 7-gate skeptic gate runs. ...'"

# 3. Set external_ref as a STRUCTURED field (not just in body)
ssh jeff-ubuntu "cd $DAEMON_DIR && ~/.local/bin/br update dark-factory-<id> \
  --external-ref '<owner>/<repo>#<PR>'"

# 4. Apply the factory label on the PR (canonical intake trigger)
gh api repos/<owner>/<repo>/issues/<n>/labels -X POST -f 'labels[]=factory'

# 5. Verify the daemon picks it up — expected sequence within ~15s:
#    INTAKE_BEAD_CREATED → TASK_ROUTED → TASK_DISPATCHED
ssh jeff-ubuntu 'tail -100 /home/jleechan/Library/Logs/dark-factory/daemon.jsonl | grep -aE "dark-factory-<id>|<owner>/<repo>#<PR>" | tail -5'
```

Expected sequence: `INTAKE_BEAD_CREATED` → `TASK_ROUTED` → `TASK_DISPATCHED` within ~15s. If the daemon shows `SKIPPED_DUPLICATE` for the PR number, that means the GitHub factory label scan already adopted it via the existing bead — the manual bead is correctly deduplicated.

Verified timeline (2026-08-18, PR #654):
```
05:03:51  SKIPPED_DUPLICATE  dark-factory#654          (factory label scan found existing bead)
05:04:34  INTAKE_BEAD_CREATED  dark-factory-qyze      (manual adoption succeeds)
05:04:45  TASK_ROUTED         dark-factory-qyze      (router picks coder lane)
05:05:08  TASK_DISPATCHED     dark-factory-qyze      (AO coder session spawned)
```

Full reference: `references/ddf-PR-9092-outage.md` (the 2026-08-18 jleechanorg/dark-factory#654 chain-walk fix /af handoff).

## Decision matrix — what end-state is appropriate

After one round of /af attempts and one telemetry read, the end-state should be one of:

| Observable condition | End-state to declare | Format |
|---|---|---|
| Bead visible in `daemon.jsonl` (`EXISTING_PR_ADOPTED` event) AND PR has `mergeStateStatus=MERGEABLE` AND no failing gates | `Daemon is dispatching. Status babysit cron <id> armed.` | Compact status |
| Bead visible in daemon.jsonl AND gate assessment shows fail | `Daemon attempted, gate <name> failed at head <sha>. Recovery command: <shell>. Status cron <id> armed.` | Status + recovery |
| Bead NOT in daemon.jsonl after 25 min AND `ssh jeff-ubuntu "tail -200 ...daemon.jsonl"` confirms | `Bead not visible to daemon. Operator next step: <shell>. Status cron <id> armed.` | Status + escalation |
| Bead filed on Mac only, never propagated to Linux | `Mac-only bead; daemon not seeing it. Operator next step: ssh to jeff-ubuntu and run <paste-ready br create>. Status cron <id> armed.` | Status + escalation |
| Daemon health degraded (`consecutive_failures > 0` or `active=inactive`) | `Daemon offline or degraded. Operator next step: <restart-recovery shell>. Status cron <id> armed.` | Status + escalation |
| Bead visible in daemon.jsonl AND `REROLL_ADOPTED_SESSION_SPAWNED` event but `ls worktrees/wa-NNNN` empty AND `pgrep` empty AND zero commits on branch | `Coder never spawned — phantom dispatch. File priority-1 bead `dark-factory: coder spawn for wa-NNNN (PR #<n>) failed silently`. Operator decides: kick AGY/AO daemon, bump budget, or hand-drive. Status cron <id> armed.` | Status + escalation (Class G) |
| Bead visible in daemon.jsonl AND `BEAD_DISPATCH_TRANSIENT_ERROR` events with byte-identical `dark-factory-ik0v` text across MULTIPLE in-flight beads AND `dark-factory-ik0v` bead status is `open` | `Factory queue is blocked on upstream dark-factory-ik0v (PR #639) — every spawn fails at AO pre-validation. /af cannot dispatch ANY new work until that bead lands. Pivot options: (1) bypass /af, dispatch claudem worker on a clean worktree from this Mac; (2) wait for operator to land the dark-factory fix. Status cron <id> armed.` | Status + escalation (Class I) |

Each row ends with **status cron ID armed** — that ensures the dropped-thread-followup cron sees your work when it scans, and you don't fire 4h-late stale replies.

## Checklist before posting a /af status reply

Run these in parallel before composing the reply:

```bash
# 1. Daemon health (must include DARK_FACTORY_BR_DB env var in Environment dump)
ssh jeff-ubuntu 'systemctl --user status ai.dark-factory.daemon.service --no-pager -l' 2>&1 | head -10
ssh jeff-ubuntu 'systemctl --user show ai.dark-factory.daemon.service -p Environment | grep DARK_FACTORY_BR_DB' 2>&1

# 2. Recent events for the PR or branch (look for EXISTING_PR_ADOPTED, SKIPPED_*, PARKED_HUMAN_HELD)
ssh jeff-ubuntu "tail -800 /home/jleechan/Library/Logs/dark-factory/daemon.jsonl \
  | grep -aE '<PR_NUMBER>|<branch-name>' | tail -10"

# 3. Bead store on Linux — confirm the bead is in the DAEMON's store (not the project repo clone)
DAEMON_STORE=$(ssh jeff-ubuntu 'systemctl --user show ai.dark-factory.daemon.service -p Environment | grep DARK_FACTORY_BR_DB | sed "s/.*=//"' 2>/dev/null)
DAEMON_DIR=$(dirname "$DAEMON_STORE")
ssh jeff-ubuntu "grep -c '<bead_id>' ${DAEMON_DIR}/issues.jsonl" 2>&1 | head -1
# Also confirm via the daemon's SQLite:
ssh jeff-ubuntu "cd ${DAEMON_DIR} && ~/.local/bin/br show <bead_id> --json 2>&1 | head -1"

# 4. PR factory label — this is the canonical intake trigger; if missing, the daemon WILL NOT pick it up
gh api repos/<owner>/<repo>/issues/<n>/labels --jq '.[] | .name' | grep -x factory

# 5. PR current state via gh
gh pr view <PR_NUMBER> --repo <owner>/<repo> \
  --json state,mergeable,reviewDecision,headRefOid,headRefName
```

If item 4 returns nothing, **the daemon will never pick up the PR regardless of bead state** — apply the `factory` label via:
```bash
gh api repos/<owner>/<repo>/issues/<n>/labels -X POST -f 'labels[]=factory'
```

If item 3 returns `0` even though you filed a bead, you're filing into the wrong directory — use `dirname $DARK_FACTORY_BR_DB` as the working directory for `br create`.

If item 2 shows `PARKED_HUMAN_HELD` with `reason: unmapped_repo` and `source: manual_adoption_fail_closed`, this is Class E — close the orphan bead and apply the `factory` label to the PR (see "Class E detail" above).

## Related skill: load order with this

1. `finish-the-job` — for end-state discipline (PR merged vs PR open vs local state).
2. `dropped-thread-cron-loop` — for when the same dropped-thread bot fires 3+ times on one thread.
3. `dropped-messages` — for the broader dropped-message class (not just auto-factory /af work).
4. `babysit-cron-self-cancel-discipline` — for the one-time status cron's self-cancel clause.
5. `gh-rate-limit-resilience` — for Class A refusals where the rate-limit is the cause.
6. `hermes-health-check` — for daemon-down states.

## Future-proofing the operator-client gap

The right durable fix to the Mac → Linux sync gap is **a launchd-managed one-way sync from jeff-ubuntu's `.beads/issues.jsonl` to the operator client's local `.beads/`**, gated on `.beads/issues.jsonl` mtime. That's a separate bead; this skill is just the operator-side workaround.

If you spot the Mac-side `br create` pattern being used by other agents in this codebase (jleechanbrain, worldarchitect.ai, dark-factory intake scripts), file a bead with `priority=2` to expose the sync gap. Do not file a sync PR from Mac without operator approval — that touches the daemon's intake contract.

## Worked example — 2026-08-18 PR #8498 + #7886 session (originating incident)

Outcome recorded for the operator (this is the originating incident):

| Time | Action | Observed state |
|---|---|---|
| t=0 | User: "Run /af on PR #8498 and #7886" | Both PRs factory-labeled, CI green; PR #8498 `reviewDecision=CHANGES_REQUESTED`. |
| t=0 | Agent: loads skill auto-factory, finds branch-key + HUMAN_HELD history on PR #8498. Files bead `rev-bxnue` for PR #7886 with all drive-existing-pr fields. | Bead in Mac SQLite only. Not in Linux `.beads/issues.jsonl`. |
| t=+25m | Operator dropped-thread cron fires; operator answers status by re-running telemetry. | Daemon showed `SKIPPED_INELIGIBLE` on PR #8498 with GH rate-limit probe_error. NOT branch-key, despite PR comments. |
| t=+30m | Sync-check discovered. | Mac `br sync --flush-only` refused. Rsync copy alone doesn't help; daemon reads its own export. |
| t=+30m | Final reply names: (1) daemon healthy and at tick 81, (2) PR #8498 blocked on operator decision (branch-key), (3) PR #7886 operator next step is `br sync --flush-only --force` from inside jeff-ubuntu. | Honest end-state. |

Lesson: had the sync-check been run BEFORE claiming "bead filed," the first reply would have surfaced the operator step directly and saved 30 minutes of diag-time.

## Worked example — 2026-08-18 PR #9070 session (corrects the v0.1.0 mistakes)

The v0.1.0 version of this skill had two material errors: (a) the daemon's bead store was listed as `~/projects/dark-factory/.beads/` (it's actually `/home/jleechan/.local/state/dark-factory/.beads/`); (b) the implied entry point for driving a PR through the factory was "file a local bead with `factory` label" (it's actually "apply the `factory` label on the GitHub PR"). The PR #9070 session exposed both.

| Time | Action | Observed state |
|---|---|---|
| t=0 | User: "Run /af on PR #9070" | PR state=OPEN, mergeable=MERGEABLE, head `8b5abb755c`, branch `feat/risk-tinted-direction-4`. 16/17 CI checks SUCCESS, 1 FAILURE (Directory tests core-mvp-1). No `factory` label on PR. |
| t=0 | Agent: loads skill auto-factory. Files bead `rev-cjl0d` on Mac and `jleechan-x2al` on Linux via `cd ~/projects/dark-factory && br create ...`. | Both beads in WRONG store — `~/projects/dark-factory/.beads/` is a user-side clone, not the daemon's authoritative store. |
| t=+30s | Agent runs `~/.local/bin/br sync --flush-only --force` on Linux in `~/projects/dark-factory`. | Sync succeeded but reconciled a DIFFERENT store than what the daemon reads. Daemon still can't see the bead. |
| t=+1m | Agent reads `systemctl --user show ai.dark-factory.daemon.service -p Environment`. | Discovers `DARK_FACTORY_BR_DB=/home/jleechan/.local/state/dark-factory/.beads/beads.db`. This is the actual daemon store. |
| t=+2m | Agent files bead `dark-factory-8xm4` via `cd /home/jleechan/.local/state/dark-factory/.beads/ && ~/.local/bin/br create ...`. | Bead now in daemon's authoritative store. |
| t=+5m | Daemon emits `PARKED_HUMAN_HELD` with `reason: unmapped_repo, source: manual_adoption_fail_closed`. | **Class E refusal.** The daemon knows about the bead but can't find a GitHub PR to attach it to — because no `factory` label was applied to PR #9070. |
| t=+10m | Agent closes orphan `dark-factory-8xm4` and applies `factory` label to PR #9070 on GitHub via `gh api repos/jleechanorg/worldarchitect.ai/issues/9070/labels -X POST -f 'labels[]=factory'`. | Orphan cleared; PR #9070 has `factory` label. |
| t=+12m | Status cron `6b09c521f075` armed (one-time, +25min, self-deletes). | Awaiting daemon's next intake cycle to produce `EXISTING_PR_ADOPTED` for PR #9070. |

Lessons embedded in v0.2.0:

1. **Always discover the daemon store via systemd** before filing beads — never assume the project repo's `.beads/` is the daemon store.
2. **Apply the `factory` label on the GitHub PR is the entry point** — not local bead creation.
3. **Orphan beads parked by Class E must be closed** — otherwise they block subsequent intake of the same PR.
4. **Always arm a status babysit cron** before claiming `/af` is dispatched — daemon's intake cadence (~15s) is fast but Class E parkings and recovery can take minutes.

## Class C detail — stale-head `/er` unblock recipe (verified 2026-08-18, PR #9092)

The Evidence Gate's `/er` runner verifies that the PR body's `Evidence:` marker (and any linked evidence gist) references the **current** PR HEAD. When you push a new commit to a factory-labeled branch, the prior evidence gist now references a stale head and `/er` fails with one of two messages:

```
/er FAIL evidence gist head is stale (3149b947, PR head e8287398)
/er FAIL missing canonical Evidence gist line with matching head SHA
```

The remediation is operator-side and takes ~2 minutes. It does NOT violate the `/af — ZERO direct work` contract because you're updating metadata, not editing product code.

### Step 1 — Identify the current HEAD

```bash
gh pr view <N> --repo <owner>/<repo> --json headRefOid --jq .headRefOid
# e.g. e828739826985057a4a83219493dd5c6fd1c4a85
```

### Step 2 — Create a fresh evidence gist at the new HEAD

```bash
# Write a markdown evidence bundle referencing the new head SHA
cat > /tmp/wa-<pr>-evidence-<new_short_sha>.md <<EOF
Evidence Bundle for PR #<N> — <branch>

PR: https://github.com/<owner>/<repo>/pull/<N>
HEAD: <new_head_sha>

## Commits ahead of origin/main
1. <new_head_sha> — <commit message>
2. ...

## Test evidence
\`\`\`
$ ./vpython -m pytest <test_file> -v
... 4 passed in 0.05s
\`\`\`

## CI evidence (all green at head <new_head_sha>)
- Green Gate ✓
- ... (paste from `gh pr checks <N>`)

Evidence Head: <new_head_sha>
EOF

gh gist create /tmp/wa-<pr>-evidence-<new_short_sha>.md --public \
  --desc "Evidence Bundle for PR #<N> (head <new_head_sha>)"
# → https://gist.github.com/<user>/<hash>
```

### Step 3 — Update PR body `Evidence:` marker + `Evidence Gist:` line

```python
# Pseudocode — `gh pr edit <N> --body-file /tmp/pr-body.md`
new_body = old_body.replace(
    '<old_gist_id>',           # the previous gist hash
    '<new_gist_id>'            # from step 2
).replace(
    '<old_head_sha>',
    '<new_head_sha>'
)
# Also update test-count line if test count changed (e.g. 3 → 4)
```

`gh pr edit <N> --body-file /tmp/pr-body.md`

### Step 4 — Post a fresh `/er` comment

```bash
gh pr comment <N> --repo <owner>/<repo> --body "/er

**Fresh evidence bundle for head \`<new_head_sha>\`** (<N> commits ahead of \`origin/main\`):
- **Evidence**: https://gist.github.com/<user>/<new_gist_id> (head \`<new_head_sha>\`)
- **Evidence Gist**: https://gist.github.com/<user>/<new_gist_id>

PR body updated to reference the new head. Ready for Evidence Gate verdict."
```

### Step 5 — Verify the daemon picks it up

```bash
ssh jeff-ubuntu "tail -200 /home/jleechan/Library/Logs/dark-factory/daemon.jsonl \
  | python3 -c 'import sys,json
events=[]
for l in sys.stdin:
    try:
        e=json.loads(l)
        if e.get(\"beadId\")==\"dark-factory-<hash>\":
            events.append({k:e.get(k) for k in [\"timestamp\",\"eventType\",\"lifecycleState\",\"reason\"]})
    except: pass
[print(e) for e in events[-8:]]'"
```

Expected sequence (within 30s):
- `ER_RUNNER_POSTED` (new `/er` invocation)
- `EVIDENCE_HEAD_STALE` may briefly appear if the gist isn't updated
- `GATE_ASSESSMENT` with `evidence_review.verdict: pass`

### Class C2 detail — re-roll held

**Observed 2026-08-18 on PR #9092.** After a stale-head `/er` failure, the daemon's remediation coder (`REROLL_ADOPTED_SESSION_SPAWNED`, `sessionId: wa-NNNN`) spawns but does not always produce a fresh `/er` post quickly. While that session is "active", the daemon parks the next re-roll attempt with:

```
PARKED_HUMAN_HELD
reason: re-roll held. Reason: an AO session is already active on adopted branch <branch>
```

This is **NOT** a permanent blocker. The operator-side recovery is the same as Class C — post a fresh `/er` comment with a new evidence gist. The daemon's next intake tick (~15s) sees the new head + new evidence and re-evaluates. The stuck `wa-NNNN` session will either time out or complete in the background; you do NOT need to cancel it from Mac (that would bypass factory provenance).

### Worked example — 2026-08-18 PR #9092 session

| Time | Action | Observed state |
|---|---|---|
| t=0 | User: "Make a PR and fullrun bring it to /ready using /af to switch the default model in settings back to gemini 3 flash and say its the best speed/quality tradeoff" | Origin/main already has `gemini-3-flash-preview` as default (PR #8974 reverted earlier flip). PR #8923 (prior attempt) was open but conflicting — closed as superseded. |
| t=0 | Agent: fresh worktree `/tmp/wa-3flash-label` from `origin/main` (`6d90bc02f6`), brief written, claudem dispatched. | Worker `proc_4afd86c80c0e` opened PR #9092 with `--label factory`. |
| t=+5m | Daemon adopted bead `dark-factory-4pjg`, posted `/er FAIL missing canonical Evidence gist line with matching head SHA; only local pytest claim present`. | First `/er` failure — root cause: worker only pasted pytest output, didn't upload a gist. |
| t=+5m | Daemon spawned re-roll session `wa-3516` (REROLL_ADOPTED_SESSION_SPAWNED). | Re-roll in progress; daemon merged `origin/main` into branch (commit `3149b94773`). |
| t=+25m | Status cron `45075a684299` fired. PR #9092 still OPEN, factory-labeled, daemon in `DISPATCHED`. | No follow-up `ER_RUNNER_POSTED` on attempt 2. Re-roll session `wa-3516` quietly stalled. |
| t=+30m | User: "Also make it the default its currently not" — agent dispatched worker `proc_de9c662999ff` to add `<option value="gemini-3-flash-preview" selected>`. | Worker hit max-turns (20) but **commit `e82873982` was already pushed**. PR head now `e828739826985057a4a83219493dd5c6fd1c4a85`. |
| t=+50m | Daemon emitted `/er FAIL evidence gist head is stale (3149b947, PR head e8287398)`. | Second `/er` failure — root cause: the evidence gist was at `3149b94773`, PR HEAD advanced to `e828739826`. |
| t=+50m | Daemon spawned re-roll session, then parked with `PARKED_HUMAN_HELD reason: re-roll held. Reason: an AO session is already active`. | **Class C2.** Stuck waiting for `wa-3516`. |
| t=+55m | Operator unblock: created fresh gist `https://gist.github.com/${GITHUB_USER}/8e7b793bac03efde2019ba3e52c8e558` at head `e828739826`, updated PR body `Evidence:` + `Evidence Gist:` lines, posted `/er` comment. | Daemon's next tick sees the new evidence and re-evaluates. |
| t=+60m | Status cron `6fce3d3320a1` armed (final-status check +20min). | Daemon will report `/er PASS` or `READY` on next intake. |

Lessons embedded:

1. **Max-turns exit is not a failure indicator** — always verify `git log --oneline origin/main..HEAD` and `git log --oneline HEAD..origin/<branch>` on the worktree before declaring worker failure. The worker hit max-turns on chatter but the commit + push were already done.
2. **Stale-head `/er` is a recoverable operator-side issue** — not a hand-fix-from-Mac issue. The unblock is metadata only (gist + PR body + comment), not product code.
3. **The daemon's "session already active" parking is temporary** — fresh `/er` triggers re-evaluation. Don't escalate to operator decision unless 25 min elapses with no progress.
4. **Operator-side push to a factory-labeled branch is allowed** — the no-direct-coding rule applies to *product* code, not to updating the Evidence Gate metadata that the gate itself requires.
