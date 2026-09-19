# daemon.jsonl refusal-cause decoder

The dark-factory daemon (`ai.dark-factory.daemon.service`) records every action as a JSONL event in `/home/jleechan/Library/Logs/dark-factory/daemon.jsonl` on jeff-ubuntu. When a labeled PR doesn't get picked up, the cause is in the **most recent** matching event — not in PR comments, not in chat history.

**Updated 2026-08-18** to add Class F (reviewer-gate blocked on vendor quota — distinct from binary-missing) and recap the previous Class E fix. The previous "Class E — Vendor queued (subclass of D)" was a misnomer; vendor-queued remains a sub-pattern of D. The new Class F is the recurring failure pattern observed in PR #9092 (2026-08-18) where Codex code-review quota is hit but the runner only has a `FileNotFoundError` fallback — it does NOT recognize a 429/quota signal as a reason to walk `backend_priority`.

This reference is a decoder for the **seven** refusal classes observed in production 2026-08-13 to 2026-08-18.

## Where to find the events

```bash
# All recent events
ssh jeff-ubuntu "tail -200 /home/jleechan/Library/Logs/dark-factory/daemon.jsonl" 2>&1

# Filter to a specific PR or branch
ssh jeff-ubuntu "tail -800 /home/jleechan/Library/Logs/dark-factory/daemon.jsonl | grep -E '<PR_NUMBER>|<branch-name>'" 2>&1

# Daemon health
ssh jeff-ubuntu 'systemctl --user status ai.dark-factory.daemon.service --no-pager -l' 2>&1 | head -10
```

## Class A — GH rate-limit on intake probe

**Symptom**: PR doesn't get dispatched. `eventType=SKIPPED_INELIGIBLE` with `precondition` starting `probe_error:tool gh failed (rc=1): gh: API rate limit exceeded`.

**Raw event shape:**
```json
{
  "timestamp": "2026-08-18T23:44:38Z",
  "beadId": "jleechanorg/worldarchitect.ai#8498",
  "lifecycleState": "INTAKE",
  "eventType": "SKIPPED_INELIGIBLE",
  "context": {
    "branch": "docs/campaign-agnostic-prompts-clause",
    "pr_number": 8498,
    "precondition": "probe_error:tool gh failed (rc=1): gh: API rate limit exceeded for user ID 13840161. If you reach out to GitHub Support for help, please include the request ID CC16:157E66:148648:4461C1:6A84EE5F and timestamp 2026-08-18 23:44:31 UTC..."
  }
}
```

**Fix**: Wait for GH user rate-limit reset (authenticated tier: 5000 req/h). Each manual retry burns more quota, so just wait. The daemon's `slow_tier_due` flag (visible in `_tick.events` context) means the daemon will throttle back automatically on the next tick.

**Operator next step** (if needed):
```bash
# Drop to slow-tier; the daemon will respect this once you set the config flag
ssh jeff-ubuntu 'cat ~/.dark-factory/daemon.toml | grep -i slow_tier'
```

## Class B — Branch-key collision

**Symptom**: PR doesn't get dispatched. Daemon posts a bot-comment to the PR with text "Branch-key stealing is not allowed; please use a unique same-repo branch" and then logs `PARKED_HUMAN_HELD`.

**Raw event shape (HUMAN_HELD)**:
```json
{
  "lifecycleState": "HUMAN_HELD",
  "eventType": "PARKED_HUMAN_HELD",
  "reason": "factory PR adoption refused for branch <branch>: already registered to bead <other_bead_id>"
}
```

**Diagnosis trick**: `grep -E "<branch_name>" .beads/issues.jsonl | head -5` will show the bead that already owns the branch. If that bead is closed/missing from `br list --status open`, it's a stale branch-key entry.

**Fix**: Operator decision required. Three options, named in `references/daemon-branch-key-recovery.md` if it exists. Default: re-target the existing open bead (if it exists) to the current PR, or attach a fresh bead via `branch-key-rebind` shell command (operator-only).

This class is the one most commonly mis-diagnosed from PR comments alone — six identical "Branch-key stealing" bot-comments could mean:

- (a) the original cause is branch-key (true if `PARKED_HUMAN_HELD.reason` matches), or
- (b) the most recent cause is something else (rate-limit is common), but the bot keeps re-posting its old comment because the daemon's behavior is comment-on-collision-only-on-new-attempt.

Always read the most recent `daemon.jsonl` event. PR comments are stale.

## Class C — Stale-head /er failure

**Symptom**: PR is dispatched, coder runs, gate assessment fails with `evidence_review.verdict: fail`. `eventType=GATE_ASSESSMENT`.

**Raw event shape:**
```json
{
  "eventType": "GATE_ASSESSMENT",
  "all_green": false,
  "gates": {
    "ci_green": "pass",
    "no_conflicts": "pass",
    "coderabbit": "pass",
    "bugbot": "pass",
    "comments_resolved": "pass",
    "evidence_review": "fail",
    "skeptic": "pass",
    "vacuous_red_green": "unknown"
  },
  "evidence_review": {
    "evidence": ["/er FAIL stale-head gist: PR head a20644e1 mismatches cited evidence SHA e2ffaa62; first Evidence line also missing required (head <sha>) suffix"],
    "verdict": "fail"
  }
}
```

**Fix**: Re-post evidence bundle at the current head. The /er review is exact-head by spec (PR head SHA must match the cited evidence SHA exactly).

**Operator next step**: Refresh the public evidence gist or PR-internal evidence with the current head SHA, then wait for the daemon's next gate-assessment tick (typically within ~10 minutes).

## Class F — Reviewer-gate blocked on vendor quota (NEW 2026-08-18, PR #9092)

**Symptom**: PR is otherwise green — CI passes, no conflicts, CodeRabbit/CursorBot clean, comments resolved. The ONLY failing gate is `evidence_review` or `skeptic`, and the daemon's REROLL session is parked with `reason: re-roll held`. The `daemon.jsonl` shows `GATE_ASSESSMENT` events where `evidence_review.verdict: fail` is repeated attempt after attempt, or the daemon emits `PARKED_HUMAN_HELD` with `reason: re-roll held. Reason: an AO session is already active on adopted branch <branch>`.

**Root cause**: `runner/handler_dispatch.py:_run_gate_once` (lines ~750-870) catches `subprocess.TimeoutExpired`, `FileNotFoundError`, and a generic `Exception`, and marks the result with `metadata["backend_missing"]="true"` ONLY when the binary is missing. When codex returns a 429 / "rate limit exceeded" / "quota exceeded" / "too many requests" response, the `codex` subprocess exits with non-zero AND writes a quota message to stderr, but the runner currently has **no rate-limit detector**. The result is `outcome="error"` — which DOES trigger `_is_gate_infra_failure` to return `True` — but the fallback chain is hardcoded to `["agy", "claude"]` (line 1152-1156) instead of walking the actual `backend_priority` queue. If agy is also rate-limited (as observed in PR #9092), the loop converges on `infra_failure` and the PR is parked.

**Three telltale signals** (require ALL three to distinguish from Class A / D):

1. **`codex --version` succeeds** on the daemon host (binary is installed and responsive). Class A only fails on the `gh` probe, not on the codex probe.
2. **`_run_gate_once` returns `outcome="error"` with stderr matching `/(rate.?limit|quota exceeded|429|too many requests)/i`** but NO `metadata["backend_missing"]="true"` flag. This is the diagnostic — distinguish from "binary was missing" by the absence of the flag and the presence of the stderr pattern.
3. **Fallback chain fails to converge**: the daemon either re-rolls several times and parks with `re-roll held`, or the gate stays at `evidence_review: fail` for >30 minutes.

**Operator-side unblock** (in priority order, pick the one that matches your constraints):

1. **Post `MERGE APPROVED` in the originating Slack thread** if the work is otherwise complete and the gate is the ONLY blocker. The worldarchitect.ai merge policy allows operator `MERGE APPROVED` to bypass the Evidence Gate (see `worldarchitect.ai/AGENTS.md`). Skeptic cron will then merge on the next tick. **Fastest path** — ~30 seconds.
2. **Wait for the vendor quota to reset** (typically daily for codex code-review quota). The re-roll session will eventually time out and the daemon will retry with fresh quota. **Unknown timing** — could be minutes or hours.
3. **Operator-side: hand-merge the PR** if it's a small, low-risk change and you have authority. Bypasses the entire gate chain. **Use sparingly** — the gate exists for a reason.

**Do NOT** (operator-client anti-patterns for Class F):

- ❌ Re-filing the same bead hoping the daemon will pick a different reviewer — the diagram's `backend_priority="codex"` is a single string, not a queue, so the same codex will be picked next time.
- ❌ Cancelling the stuck `wa-NNNN` re-roll session from Mac — that bypasses factory provenance.
- ❌ Editing `runner/handler_dispatch.py` from the Mac operator-client session — this is a `/af` workflow, the canonical fix lives in a separate PR.

**Run-side fix** (separate PR, not the operator's job to dispatch):

```python
# runner/handler_dispatch.py — proposed patch (NOT YET LANDED)
_RATE_LIMIT_RE = re.compile(r"(rate.?limit|quota exceeded|429|too many requests)", re.I)

def _detect_rate_limit(proc: "subprocess.CompletedProcess") -> bool:
    """Return True when the subprocess exited non-zero AND stderr/stdout
    matches a known downstream quota/rate-limit pattern."""
    if proc.returncode == 0:
        return False
    blob = (proc.stdout or "") + (proc.stderr or "")
    return bool(_RATE_LIMIT_RE.search(blob))

# In _run_gate_once, after the existing except clauses:
if _detect_rate_limit(proc):
    result.metadata["rate_limited"] = "true"
    # Also: route to next backend_priority entry instead of hardcoded agy/claude
```

And in `_execute_gate` (line 1152-1156), replace the hardcoded `["agy", "claude"]` fallback chain with: walk the `backend_priority` attribute (or env var `DARK_FACTORY_ADVERSARIAL_PRIORITY`), skipping the failed backend, and only fall back to the full hardcoded chain if the priority queue is exhausted.

Verify the fix in `tests/test_cli_fallbacks.py` (currently 15 tests — all cover missing-binary / timeout, **zero cover rate-limit**). Add 4 tests: codex-429 → next-in-queue, codex-429 → all-fail → `verdict: infra_failure`, codex-429 → `fallback_used: true` + `fallback_from: codex` metadata, parallel-reviewer controller mode preserves original behavior.

**See also**: `references/ddf-PR-9092-outage.md` for the full PR #9092 timeline (originating incident).

## Class D — Vendor-fallback exhausted on REROLL

**Symptom**: PR fails gates, daemon tries REROLL, REROLL is parked because no fallback vendor could spawn a coder session.

**Raw event shape:**
```json
{
  "lifecycleState": "HUMAN_HELD",
  "eventType": "PARKED_HUMAN_HELD",
  "reason": "failed to spawn a remediation coder session on adopted branch <branch>: all 2 fallback vendor(s) failed: antigravity: ao spawn deferred to internal queue: ao spawn --agent antigravity queued instead of spawning (REQUEST=dark-factory-exact-branch-worldarchitect); minimax: ao spawn deferred to internal queue: ao spawn --agent minimax queued instead of spawning (REQUEST=dark-factory-exact-branch-worldarchitect)"
}
```

**Fix**: This is an AO (Agent-Orchestrator) infrastructure issue, not a PR issue. The `ao spawn` calls deferred to internal queues instead of actually spawning workers.

**Operator next step**:

```bash
# Check AO daemon health
ssh jeff-ubuntu 'systemctl --user status agent-orchestrator.service --no-pager -l' 2>&1 | head -10

# Or restart AO if needed
ssh jeff-ubuntu 'systemctl --user restart agent-orchestrator.service'
```

After AO is healthy again, the daemon's next tick's `recover-held` phase will requeue the parked beads. No operator action on the PR itself is needed.

## Class E — Vendor queued (subclass of D)

`ao spawn --agent <vendor> queued instead of spawning (REQUEST=<uuid>)` — AO is alive but deferring spawns to its internal queue. This means AO can't keep up with demand; the daemon's spawn request is parked in AO's queue. Same recovery as Class D; Class E specifically indicates AO is functional but rate-limited.

## Class F — Reviewer-gate blocked on vendor quota

**See the dedicated Class F section above.** This is the pattern where the gate's CHOSEN BACKEND (e.g. codex) hits its quota, the runner doesn't detect that as a reason to walk the priority queue, and the PR is parked. The fix is in `runner/handler_dispatch.py`; the operator-side workaround is `MERGE APPROVED` or wait-for-reset.

## Reading the daemon's tick summary

The daemon logs `_tick` events every ~15s. The relevant fields:

```json
{
  "eventType": "TICK",
  "context": {
    "tick_index": 81,
    "slow_tier_due": false
  },
  "metrics": {
    "beadsCreated": 0,
    "beadsDispatched": 0,
    "beadsRouted": 5,
    "beadsEscalated": 0,
    "beadsParkedHumanHeld": 0,
    "beadsReady": 0,
    "beadsRecoveredFromHeld": 0,
    "gatesAssessed": 3
  }
}
```

`beadsRouted > 0` for the tick — work was routed. Compare against `beadsRouted < expected` to see if your PR was filtered out by intake.

## Health-check command (canonical)

```bash
ssh jeff-ubuntu 'systemctl --user status ai.dark-factory.daemon.service --no-pager -l' 2>&1
```

Look for `Status: "auto-factory daemon tick=N ok consecutive_failures=0"`. If `consecutive_failures > 0`, the daemon is in degraded mode — escalate to operator.

## Anti-patterns when reading daemon.jsonl

- ❌ **Skim the first error** — find the most recent error for the SPECIFIC PR or branch. Earlier events may be from prior attempts and won't reflect the current cause.
- ❌ **Trust PR comments over telemetry** — PR comments are written by the daemon's bots and may reflect older causes. Telemetry is ground truth.
- ❌ **Trust the gate-assessor's evidence field without reading the gate verdict** — the `evidence` field is the gate's proof; the `verdict` field is the verdict. Both are required.
- ❌ **Trigger another manual intake on Class A** — each manual attempt burns more GH quota. Wait for the daemon to retry on its own schedule.

## Sources

- Live daemon telemetry observed 2026-08-13 through 2026-08-18
- `jleechanorg/worldarchitect.ai` PRs #8498, #7886, #8853, #8730, #9092 (sampled)
- jleechanorg/agent-orchestrator — `agent-orchestrator.yaml` `ao spawn` fallback chain documented
- dark-factory repo's `runner/handler_dispatch.py:_execute_gate` (lines 1119-1171) — the current single-fallback-to-claude chain
- dark-factory repo's `tests/test_cli_fallbacks.py` — 15 tests covering missing-binary + timeout, ZERO covering rate-limit/quota
- dark-factory repo's `pipelines/slim/two_node.dot` — `backend_priority="codex"` as a single-entry string, not a chain
- dark-factory repo's `daemon/factory-overlay.sh` (operator-owned, not edited from this skill)
