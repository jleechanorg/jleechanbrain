# Class I — Adopted-PR exact-head drift blocker

**Observed 2026-08-19** during an undo-button `/repro` session. Every labeled PR in the daemon's queue hit `BEAD_DISPATCH_TRANSIENT_ERROR` at `phase: spawn` within the same second, with byte-identical refusal text. Upstream cause: `dark-factory-ik0v` bead (PR `jleechanorg/dark-factory#639`) is still OPEN.

## Raw event shape

```json
{
  "timestamp": "2026-08-19T08:31:23Z",
  "beadId": "dark-factory-nm0n",
  "attemptId": 2,
  "lifecycleState": "DISPATCHING",
  "eventType": "BEAD_DISPATCH_TRANSIENT_ERROR",
  "context": {
    "branch": "fix/auth-browser-preview-poll-decoupling",
    "error": "all 2 fallback vendor(s) failed: antigravity: tool ao spawn --agent antigravity failed (rc=1): [dark-factory AO bridge] AO project worldarchitect adopted-PR branch fix/auth-browser-preview-poll-decoupling origin head is              843bfb4ef4ca820664dc238c382d555227c69dbf, expected validated PR head 36c7ed9dbf9b960da4a91d6f08d402d970dd415c;              refusing to spawn because rebinding defaultBranch would still land AO              at the divergent commit (the exact drift bead dark-factory-ik0v fixes)\n              ; minimax: tool ao spawn --agent minimax failed (rc=1): [dark-factory AO bridge] AO project worldarchitect adopted-PR branch fix/auth-browser-preview-poll-decoupling origin head is              843bfb4ef4ca820664dc238c382d555227c69dbf, expected validated PR head 36c7ed9dbf9b960da4a91d6f08d402d970dd415c;              refusing to spawn because rebinding defaultBranch would still land AO              at the divergent commit (the exact drift bead dark-factory-ik0v fixes)\n              ",
    "phase": "spawn",
    "transient": true
  }
}
```

In this example: `origin/main = 36c7ed9dbf` and the PR head is `843bfb4ef4` — different SHAs. AO refuses to spawn because its workspace-worktree.create defaults `baseRef` to `origin/main` instead of the captured PR-head revision.

## Why it's distinct from D and G

| Class | Refusal source | Spawn event | Worktree created | Both vendors |
|---|---|---|---|---|
| D (vendor-fallback exhausted) | AO daemon queues spawn internally | Real | No | Yes (different messages) |
| G (phantom spawn) | Daemon logged spawn but underlying invocation failed | Real, but process didn't actually start | Sometimes | Varies |
| **I (this class)** | AO bridge fail-closed validation rejects on the spot | Real | Yes (lands at origin/main) | Yes (same message) |

The killer signal: in Class I, BOTH vendors (antigravity + minimax) fail with the SAME byte-identical `dark-factory-ik0v` text. Class D shows different vendor-specific messages; Class G shows the spawn event but no worktree/process.

## Why brand-new branches at origin/main HEAD still trigger Class I

The expected-PR-head SHA is captured during INTAKE (not when the worker starts). For a branch created seconds earlier at `origin/main = 36c7ed9dbf`, the captured expected-PR-head IS `36c7ed9dbf`. AO's pre-validation checks `baseRef = origin/<defaultBranch>` against this captured value. If the worker's `git worktree add` happens to land at the same SHA, validation passes — but if the daemon's intake ran a `git fetch` between bead creation and dispatch, the captured value may not match the live `origin/main`, triggering the refusal anyway.

In practice: **any PR whose head SHA is not byte-identical to `origin/main` at dispatch time will fail.** This is effectively every labeled PR.

## Diagnostic recipe (paste-ready)

```bash
# 1. Confirm Class I signature across multiple in-flight beads:
ssh jeff-ubuntu "tail -800 /home/jleechan/Library/Logs/dark-factory/daemon.jsonl \
  | python3 -c 'import sys,json
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
# Expected: "open"

# 3. Confirm the daemon is healthy otherwise:
ssh jeff-ubuntu 'systemctl --user status ai.dark-factory.daemon.service --no-pager -l 2>&1 | head -10'
# Expected: active (running), consecutive_failures=0
```

## Cross-skill generalization

This pattern generalizes: **when EVERY labeled PR fails with byte-identical text referencing a specific upstream bead, that bead is the canonical upstream-blocker**. Read its status, not the in-flight errors. The diagnostic recipe works for any future "AO bridge fail-closed on upstream bug" — substitute the upstream bead ID.

## Related upstream artifact

- `dark-factory-ik0v` — "fix(daemon): adopted-PR remediation worktrees must start at the PR head"
- External ref: `jleechanorg/dark-factory#639` (PR closed but bead open as of 2026-08-19)
- Required behavior (per bead body): "An adopted same-repo PR remediation spawn must create/reuse the AO worker workspace on the exact captured PR-head revision, while retaining the PR head branch name. Ordinary generated-branch spawns must continue to start from the configured default branch."
