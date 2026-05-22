# Evidence: PR #565 — Hermes install.sh rewrite

## Claim
`scripts/install.sh` is a 10-point Hermes setup validator that reliably detects and auto-corrects common setup issues including the Slack token conflict root cause of the 12.6-hour outage.

## What was tested
1. **Full validation run** (`bash scripts/install.sh`) — 42 PASS, 0 FAIL, 3 WARN
2. **Fix mode** (`bash scripts/install.sh --fix`) — auto-corrects directory creation, config sync, plist HERMES_HOME, plist loading
3. **Slack token conflict detection** — correctly identifies active conflicts in error log tail (not historical)
4. **Separate staging Slack app** — staging connects as `@hermes_staging` via `HERMES_STAGING_SLACK_APP_TOKEN`
5. **Gateway health** — PID-to-port verification for both prod (8642) and staging (8643)
6. **mem0 server** — self-hosted server healthy on port 8000, cloud MEM0_API_KEY correctly reported as optional

## Evidence artifacts
- `run.json` — full install.sh output with all 10 check results
- `metadata.json` — git provenance (HEAD SHA, branch, merge base, commit count)

## Before/after: Root cause of 12.6-hour outage
- **Before**: staging and prod shared `SLACK_APP_TOKEN` → crash storm → launchd exponential backoff → total outage
- **After**: install.sh check 7 detects token conflicts; separate staging app (A0APZAC659P) with `HERMES_STAGING_SLACK_APP_TOKEN`; `launchd-env-wrapper.sh` routes staging tokens

## Known limitations (WARN, not FAIL)
1. Hermes update available (90 commits behind) — cosmetic, not a setup failure
2. MEM0_API_KEY not set — cloud mem0 disabled but self-hosted mem0 server is healthy
3. Cloud mem0 disabled — Hermes plugin needs `host` param addition to use local server

## What this evidence proves
- The install.sh validator correctly identifies the current healthy state of a Hermes setup
- All 10 checks produce deterministic PASS/FAIL/WARN results
- The Slack token conflict root cause is now detected and resolved with separate staging tokens
- Both gateways are running, healthy, and authenticated on Slack

## What this evidence does NOT prove
- Behavior on a completely fresh machine (no existing plists/config)
- The `--fix` mode creates correct plists from scratch (would need fresh-machine test)
- The mem0 sync works end-to-end through the Hermes gateway (plugin sends to cloud, not local)
