# Diagnosing GH-API Operational-Script Failures

Quick checklist when a `gh`-calling script fails. Copy this into a worktree
or test runner when investigating.

## Step 1 — Check quota first

Always before debugging the script:

```bash
gh api rate_limit | jq '.resources | {core, graphql, search}'
```

Both buckets:

- `core` (REST, `gh api`) — 5000/hr per user token
- `graphql` (`gh pr list`, `gh issue list --json`, `gh pr create`, etc.) — 5000/hr per user
- `search` (`gh search ...`) — 30/min, separate

If `remaining=0` on a bucket you depend on, that's the bug. If both have
quota, the failure is elsewhere — go to Step 2.

## Step 2 — Reproduce the call directly

```bash
# Replace the script's call with the literal invocation, with stderr captured:
gh pr list --repo "$REPO" --state merged --limit 100 \
           --json number,title,url,mergedAt 2>&1 | head -20
```

If the direct call works but the script fails, the bug is in the script
(stdout/stderr capture, jq filter, error handling).

If the direct call fails, check:

- `gh auth status -t` — auth not expired?
- `gh config list` — custom hosts (`GH_HOST`) may route to GitHub
  Enterprise or a self-hosted instance with different rate-limit policy.
- DNS / network: `curl -sSI https://api.github.com/meta 2>&1 | head -3`.

## Step 3 — Identify which bucket your script hits

| Script uses | Bucket | Fallback target |
|---|---|---|
| `gh pr list`, `gh issue list`, `gh pr create`, `gh pr view` | GraphQL | `gh api repos/.../pulls`, `gh api repos/.../issues` |
| `gh api ...` | REST | (no equivalent GraphQL for arbitrary queries — retry once, then surface error) |
| `gh search ...` | Search | (separate bucket — script probably can't recover, surface error) |

For PR discovery specifically:

```bash
# GraphQL primary
gh pr list --repo "$REPO" --state merged --limit 100 --json number,title,url,mergedAt

# REST fallback
gh api "repos/${REPO}/pulls?state=closed&sort=updated&direction=desc&per_page=100" \
       --jq '.[] | select(.merged_at != null) | {number, title, html_url, merged_at}'
```

The REST endpoint covers anything `gh pr list --state merged` returns, with
field-name normalization (`merged_at` → `mergedAt`, `html_url` → `url`).

## Step 4 — Decide the fix shape

| Symptom | Fix |
|---|---|
| GraphQL exhausted, REST has quota | Add REST fallback in script (this skill) |
| Both buckets exhausted | Increase wait, sleep until reset time, retry once |
| Single-bucket script that has never had a quota failure in production | Add the dual-bucket logic NOW — bucket exhaustion WILL happen on long-lived scripts |
| `gh auth` expired | `gh auth refresh` from human, no script-side fix |
| `gh pr create` fails during high-frequency worker batch | Worker recovers via file-edit + REST POST (see `claude-code-claudem` v1.3.0 pitfall) |

## Step 5 — Verify the fix actually exercises the fallback

Stub `gh` via PATH (see SKILL.md "Test harness pattern: hermetic bash
function testing"):

```bash
TMP=$(mktemp -d)
cat > "$TMP/gh" <<'EOSH'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  echo "GraphQL: API rate limit already exceeded" >&2
  exit 1
fi
exec /opt/homebrew/bin/gh "$@"
EOSH
chmod +x "$TMP/gh"
PATH="$TMP:$PATH" bash scripts/bug-hunt-daily.sh --dry-run 2>&1 | head
```

If the script still fails, the dual-bucket path isn't actually being taken —
check that the GraphQL test fires before the REST fallback and that field
names are normalized.

## Common false diagnoses

- "It's a network issue" — usually wrong. GH API is famously reliable;
  when it goes down, `https://www.githubstatus.com/` shows it. Default to
  quota exhaustion first.
- "The script works on my machine" — both buckets reset hourly. The
  local machine may have just had a fresh reset; the launchd container
  may not have.
- "Just add `--retry`" — `gh` doesn't have a single-shot retry flag that
  handles cross-bucket fallback. Retry-on-the-same-bucket doesn't help if
  that bucket is the one that's exhausted.