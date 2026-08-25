# Skeptic Auto-Merge — Architecture

**Replaces the per-repo `skeptic-cron.yml` GHA workflow with a single launchd-managed
cron in jleechanbrain that drives all `jleechanorg/*` repos.**

User intent (2026-07-13, Slack C0BDEAJH8PK):

> For skeptic cron I dont really wanna install things per repo. Can we have this
> live in jleechanbrain and use the AO golang reviewer that already exists to
> redo skeptic and use the AO worker job template to automatically merge PRs?

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│ launchd                                                             │
│   ai.smartclaw.schedule.skeptic-auto-merge.plist                        │
│       RunAtLoad=false  StartInterval=1200 (20 min)                  │
│       KeepAlive.SuccessfulExit=false  ThrottleInterval=60            │
│       WorkingDirectory=~/repos/jleechanbrain                          │
│       Environment: DARK_FACTORY_HOME=~/repos/jleechanorg/dark-factory │
│                   SKEPTIC_AUTO_MERGE=true   ← operator enables       │
│                   SKEPTIC_REPOS_GLOB=jleechanorg/*                   │
│                   SKEPTIC_DRY_RUN=false                               │
│                                                                      │
│       ↓                                                               │
│   scripts/skeptic_auto_merge.py                                      │
│       │                                                              │
│       ├─▶ Step 1: gh repo list jleechanorg --limit 200               │
│       │   (no hardcoded repo list — fully glob-driven)               │
│       │                                                              │
│       ├─▶ Step 2: for each repo, gh pr list --state open             │
│       │                                                              │
│       ├─▶ Step 3: 6-green gate filter on each PR                     │
│       │   ├── gate 1: CI green (gh api commits/SHA/status)           │
│       │   ├── gate 2: mergeable=true (gh api pulls/N)                │
│       │   ├── gate 3: CR APPROVED (gh api pulls/N/reviews)           │
│       │   ├── gate 4: Bugbot clean (Cursor Bugbot check-run)         │
│       │   ├── gate 5: comments resolved (gh api graphql)            │
│       │   └── gate 6: evidence review (evidence-review-bot OR        │
│       │                Evidence Gate check)                          │
│       │                                                              │
│       ├─▶ Step 4: for each 6-green PR: dispatch skeptic review       │
│       │   └──▶ python3 dark-factory/runner/skeptic_gate_cli.py \     │
│       │        --pr-number N --pr-sha SHA --repo OWNER/REPO          │
│       │   │                                                          │
│       │   │  The dark-factory CLI uses the AO Go reviewer adapter    │
│       │   │  (jleechanorg/agent-orchestrator-golang) to invoke        │
│       │   │  the actual LLM (claudecode/codex/opencode) with the     │
│       │   │  SHA-bound verdict contract. Posts the verdict comment   │
│       │   │  via gh api with idempotent comment markers.             │
│       │   │                                                          │
│       │                                                              │
│       ├─▶ Step 5: poll for VERDICT: PASS comment                     │
│       │   └── require ALL THREE SHA-pinned markers                   │
│       │       • <!-- skeptic-gate-verdict -->                        │
│       │       • <!-- skeptic-cron-trigger-${SHA} -->                 │
│       │       • <!-- skeptic-head-sha-${SHA} -->                     │
│       │   └── require trusted author + PR author ≠ verdict author   │
│       │                                                              │
│       └─▶ Step 6: auto-merge if SKEPTIC_AUTO_MERGE=true              │
│           └──▶ gh pr merge N --squash --admin --delete-branch        │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

## Why this design

| Concern | Why |
|---|---|
| **No per-repo install** | Single Python script + launchd plist in jleechanbrain. Other repos get auto-merge "for free" by being in `jleechanorg/*`. |
| **AO Go reviewer reused** | `dark-factory/runner/skeptic_gate_cli.py` uses the AO reviewer adapter (claudecode/codex/opencode) — already battle-tested. We do NOT reimplement verdict binding. |
| **AO worker job template** | Follows the pattern from PR #766 (jleechanorg/jleechanbrain): launchd-managed RecoverableBatchJob with auto-merge semantics. |
| **No CI check required** | Verdict is a PR comment + SHA-pinned markers. No `skeptic-gate.yml` CI workflow needed (it was already removed in #8217). |
| **Fail-closed everywhere** | Every gate returns a reason-string if not met. Verdict allowlist checks author + SHA + markers + non-self-approval. |
| **DRY_RUN default true** | Operator must explicitly opt in with `SKEPTIC_DRY_RUN=false` to actually dispatch LLM calls. |
| **Auto-merge gated** | `SKEPTIC_AUTO_MERGE=false` (default) means cron evaluates + dispatches but never merges. |
| **Per-PR denylist** | `SKEPTIC_AUTO_MERGE_DENYLIST` excludes specific PRs from auto-merge. |
| **No secret leakage** | `_is_secret_env()` strips `GITHUB_TOKEN`, `GH_TOKEN`, `AO_*`, `HERMES_*`, `SLACK_*`, `OPENCLAW_*`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` before subprocess calls (per `bashrc-profile-xapp-drift-blocks-launchd`). |

## Trust boundaries

The skeptic verdict trust boundary follows the original `skeptic-cron.yml` design:

| Author | Allowed? |
|---|---|
| `github-actions[bot]` | Yes (only if NOT the PR author) |
| `jleechanao` | Yes |
| `jleechan-af` | Yes |
| `<PR author>` | NO (defense against self-approval) |
| Anyone else | NO |

Comment body must contain ALL of:
- `<!-- skeptic-gate-verdict -->`
- `<!-- skeptic-cron-trigger-${PR_SHA} -->`
- `<!-- skeptic-head-sha-${PR_SHA} -->`

These markers are set by `dark-factory/runner/skeptic_gate_cli.py` when it posts a verdict. If the markers are absent or the SHA is stale, the verdict is rejected. This prevents spoofing (an attacker would need to forge a comment from a trusted author containing the SHA-pinned markers).

## File layout

```
scripts/skeptic_auto_merge.py                       # the cron driver (~580 LOC)
tests/test_skeptic_auto_merge.py                    # 21 contract tests
launchd/ai.smartclaw.schedule.skeptic-auto-merge.plist.template  # the launchd plist
docs/skeptic-auto-merge.md                          # this file
```

External dependencies (not vendored here):
- `jleechanorg/dark-factory/runner/skeptic_gate.py` — SHA-bound verdict binding library (PR #281, branch `feat/issue-278`).
- `jleechanorg/dark-factory/runner/skeptic_gate_cli.py` — workflow-facing CLI that orchestrates the review + posts the verdict comment.
- `jleechanorg/agent-orchestrator-golang/backend/internal/adapters/reviewer/` — AO Go reviewer adapter (claudecode/codex/opencode).

## Pin notes

| Component | Pin | Reason |
|---|---|---|
| `skeptic_gate_cli.py` | SHA `7acfde5` (branch `feat/issue-278`) | PR #281 OPEN — pin to a known-good rev. After PR #281 merges to main, bump the pin to the merge SHA. |
| AO reviewer | (no pin — daemon-managed via `ao`) | The AO daemon (PIDs 95787/95769/56469) owns reviewer binary versions. |
| Python | 3.11+ | Dataclass, `Optional[str]`, `subprocess.run(env=)` all require 3.11+. |
| `gh` | CLI ≥ 2.40 | Required for `gh repo list --json nameWithOwner` and `gh api graphql` with `-f`. |

## Verification

```bash
cd ~/repos/jleechanbrain
python3 -m pytest tests/test_skeptic_auto_merge.py -v
# Expected: 21 passed in 0.1s

# Dry run against live gh
unset GITHUB_TOKEN
GH_ACCOUNT=${GITHUB_USER} python3 scripts/skeptic_auto_merge.py --dry-run --verbose --repo jleechanorg/jleechanbrain 2>&1 | head -20
# Expected: enumerates PRs, logs gate failures, never dispatches or merges

# Full integration test (REQUIRES SKEPTIC_AUTO_MERGE=true and SKEPTIC_DRY_RUN=false)
launchctl load ~/Library/LaunchAgents/ai.smartclaw.schedule.skeptic-auto-merge.plist
tail -f ~/.smartclaw/logs/skeptic-auto-merge.log
```

## Failure modes

| Failure | Behavior |
|---|---|
| `gh` CLI not found | Logs error, exit code 1. Cron survives. |
| `GITHUB_TOKEN` not set | `_resolve_gh_token()` falls back to `gh auth token`. If that fails, the script logs the error and skips that PR. |
| `dark-factory` not cloned | `verify_skeptic_cli_present()` returns False. The script logs the error and skips the PR. |
| `skeptic_gate_cli.py` exits non-zero | Logs stderr, doesn't merge. Next 20-min tick re-tries. |
| Verdict never appears | Script retries every 20 min until verdict posts. Stale verdict (different SHA) is rejected — cron re-fetches HEAD and re-dispatches. |
| Network outage / `gh` rate-limit | Subprocess times out, PR skipped. Next 20-min tick re-tries. |
| Cron itself crashes | `launchd` keeps retrying per `KeepAlive.SuccessfulExit=false`. |
| Cron silently fails | Companion watchdog cron (like `babysit_stale_watchdog.py`) reaps silent failures every 30 min. |

## Migration path from PR #777

| Step | Command |
|---|---|
| PR #777 was closed because user redirected to "live in jleechanbrain, use AO reviewer" | (DONE) |
| PR #778 (this branch) replaces it | (in progress) |
| After PR #778 merges: install launchd plist | `cp launchd/ai.smartclaw.schedule.skeptic-auto-merge.plist.template ~/Library/LaunchAgents/ai.smartclaw.schedule.skeptic-auto-merge.plist && sed -i '' "s/@HOME@/$HOME/g; s/@REPO_ROOT@/$PWD/g" ~/Library/LaunchAgents/ai.smartclaw.schedule.skeptic-auto-merge.plist && launchctl load ~/Library/LaunchAgents/ai.smartclaw.schedule.skeptic-auto-merge.plist` |
| After install: enable auto-merge | set `SKEPTIC_AUTO_MERGE=true` and `SKEPTIC_DRY_RUN=false` in the launchd env dict, then `launchctl unload && launchctl load` |

## Out of scope

- This script does NOT replace `skeptic-gate.yml` in dark-factory (PR #281 adds it; that's its own thing — that workflow is `workflow_call` target for in-workflow use).
- This script does NOT auto-resolve Bugbot errors or merge conflicts — that's `drive-pr-to-green`'s job.
- This script does NOT replace `babysit.py` for single-PR observation loops — different tempo, different surface.
- This script does NOT post to Slack (yet). If you want Slack narration per-merge, add a Slack step after Step 6 — out of scope for v1.
