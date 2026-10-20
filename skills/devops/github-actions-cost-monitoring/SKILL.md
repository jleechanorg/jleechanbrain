---
name: github-actions-cost-monitoring
description: GH Actions cost monitor per-SKU and runner detection.
---

# GitHub Actions Cost Monitoring

A class-level skill for any script that monitors GH Actions spend and alerts on it. The bug class: **flat per-minute rate × total minutes** without classifying runner type. Self-hosted minutes are $0 on GH billing; treating them as billable produces false-positive alerts that invert real cost-savings work (e.g. PR #8285 moved CI to self-hosted to save money; the alert then mis-counted those saved minutes as billable).

## Pricing model — per-SKU, NEVER flat

Use per-SKU rates. Flat `$0.002/min` (or any single rate) is wrong because runner type varies across workflows.

| SKU | USD/min (2025-2026) |
|---|---|
| Linux hosted | $0.008 |
| macOS hosted (3-core) | $0.08 |
| Windows hosted | $0.016 |
| Self-hosted | **$0** |

Verify rates at build time — GitHub can revise. Treat `unknown` runner-type as **$0** (safe default: don't bill when in doubt; over-reporting produces false alerts).

## Runner-type detection — `runs-on:` from workflow YAML, NOT per-run jobs API

The `workflow_runs[]` endpoint does **NOT** expose `runner_name`. Don't loop per run fetching `actions/runs/{id}/jobs` (N+1 calls, slow). Instead:

1. One API call: `gh api repos/<repo>/actions/workflows --paginate -q '.workflows[] | select(.state=="active") | .path'` — get all active workflow paths.
2. Per workflow file, fetch raw YAML (`-H 'Accept: application/vnd.github.raw'`).
3. Extract the FIRST `runs-on:` line via `awk '/^[[:space:]]*runs-on:/{sub(/^[[:space:]]*runs-on:[[:space:]]*/, ""); print; exit}'`.
4. Cache result in a TSV file (one row per workflow): `<path>\t<runner_type>\t<runs_on_raw>`.
5. **Parallelize** the per-workfile fetches via `xargs -I {} -P 8 bash -c '...'` — saves minutes on repos with 20+ workflows.
6. Look up runner-type per run via `awk -F'\t' '$1 == "<wf_path>" {print $2}'`.

### Classifier rules (in priority order)

```
self-hosted*  → self_hosted    (covers self-hosted, self-hosted-macos,
                                self-hosted-linux, self-hosted-mikey,
                                [self-hosted, linux, x64] matrix form)
empty/null    → unknown        (safe default = $0/min)
macos*|mac-*  → hosted_macos   (macos-latest, macos-13, macos-14, mac-14)
windows*|win-* → hosted_windows
ubuntu*|linux|debian|rhel → hosted_linux
otherwise     → unknown        (safe default = $0/min)
```

Always lowercase before matching — `Macos-Latest` and `macos-latest` are the same.

## Hidden bugs in this domain

### Silent 422 on `gh api -f labels='[...]'`
The `-f labels='["a","b"]'` JSON-array form returns HTTP 422 with message like `"\"[\\\"a\\\",\\\"b\\\"]\" is not an array"`. The fix is gh CLI's repeated-flag syntax:

```bash
# WRONG (silent 422):
gh api ... -f labels='["cost-alert","automated"]'

# CORRECT:
gh api ... -f labels[]=cost-alert -f labels[]=automated
```

This fails silently (just an error log line, no exception). Verify with `--include` and grep for `422`, or test the issue-creation call once before relying on it.

### Bash 3.2 / macOS launchd compat
macOS `/bin/bash` is 3.2 (no `declare -A` for associative arrays). Launchd jobs use system bash. Use TSV files + `awk` aggregation instead:

```bash
# BAD (bash 4+ only):
declare -A summary
summary["$key"]="$runs|$min|$cost"

# GOOD (bash 3.2):
printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$wf_path" "1" "$duration" "$cost" "$rtype" >> "$work_dir/summary.tsv"
awk -F'\t' '{key=$1"\t"$2; runs[key]+=$3; min[key]+=$4; cost[key]+=$5} END {for (k in runs) print runs[k], min[k], cost[k]}' "$work_dir/summary.tsv"
```

### `gh api --paginate` with fake/mocked response
If you mock `gh` for testing, beware: `--paginate` follows `Link: rel="next"` headers and stops if absent. Returning the same JSON for every call is fine (no next page = stop after 1), but the `-q '.workflows[] | select(.state=="active") | .path'` jq filter MUST be applied by your mock — `gh` does not pipe JSON through jq automatically; the script does via `-q`.

### Alert payload design — include the per-workflow breakdown
Don't just report total cost. Include a per-workflow breakdown sorted by cost DESC so the receiver immediately sees WHICH workflow is the driver:

```
Top workflows by cost:
  - jleechanorg/worldarchitect.ai :: .github/workflows/worldarchitect-tests.yml :: 260 runs, 2602 min, $20.82 [hosted_linux]
  - jleechanorg/worldarchitect.ai :: .github/workflows/self-hosted-mvp-shard1.yml :: 145 runs, 2030 min, $0.00 [self_hosted]
```

Without the breakdown, alerts become un-actionable.

## Testing checklist (must pass before shipping)

1. **Unit**: classifier table (matrix forms, empty, null, lowercase variants).
2. **Unit**: rate table (`hosted_linux = 0.008`, `self_hosted = 0`, `unknown = 0`).
3. **Cost math**: self-hosted minutes contribute $0 to total; flat-rate repro (e.g. `600 * 0.002 = $1.20`) must NOT be the output for self-hosted.
4. **Threshold**: self-hosted-only scenarios must NOT trigger the alert (regression test for original false alert).
5. **Syntax**: `bash -n script.sh` clean (catches bash 3.2/4.0 incompatibilities).
6. **`--dry-run` mode**: skip Slack/issue side-effects for safe testing.

## Bash 3.2 / launchd gotchas — full list

- No `declare -A` — use TSV + awk.
- No `[[ -v var ]]` — use `[[ -n "${var+x}" ]]`.
- `printf '%s\n'` works; `mapfile` does NOT — use `while read` loop.
- `date -d` is GNU; macOS needs `date -j -f '%Y-%m-%dT%H:%M:%SZ'` or `gdate`.
- Use `xargs -I {}` not `xargs -P` with process substitution; both work in 3.2.

## Process / flow pattern

1. Worktree from `origin/main`: `git worktree add -b fix/<topic> <path> origin/main`.
2. Edit + `bash -n` + unit tests in `tests/test_<name>.sh`.
3. Commit with CLI+model provenance tag in subject (e.g. `claudem/minimax-M3: fix(cost-monitor): ...`).
4. Push branch to origin.
5. Open PR with body explaining the bug class, the fix, and the acceptance test.
6. CI may be blocked by separate infrastructure (rate-limited review bots, offline self-hosted runners) — open a separate bead for that, do NOT silently expand scope to fix the harness.
7. Self-cancel babysit cron when work lands (use `--at 10m` one-shot, NOT `--every 10m` recurring).

## Related skills

- `hermes-deploy-pipeline` — for the actual deploy step after merge.
- `babysit-ao-pr-loop` — for monitoring PR CI to green.
- `finish-the-job` — for the end-to-end "ship it" flow.
- `outbound-secret-gate` — for any Slack message that quotes the alert body.

## Reference files

- `references/pricing-rates-2026.md` — authoritative per-SKU rate table with live billing-API verification notes.
