---
name: gh-rate-limit-resilience
description: Dual-bucket `gh` scripts that survive quota exhaustion.
version: 1.0.0
triggers:
  - gh pr list fails with API rate limit
  - GraphQL rate limit exceeded
  - script must keep working when GitHub rate-limits
  - operational script hits GitHub
  - daily job PR discovery fails
  - script aborts on first repo failure
  - PR Discovery Failed alert obscures the cause
  - classify gh failure / which bucket ran out
---

# GitHub Rate-Limit Resilience for Operational Scripts

## Core insight (verbatim, 2026-08-06 evidence)

GitHub REST and GraphQL are SEPARATE rate-limit buckets. A user-level 5000/hr
limit on REST does NOT consume the 5000/hr GraphQL quota (and vice versa).
When one bucket is exhausted, the other almost always still has capacity.
Operational scripts that only hit one bucket will fail whenever that bucket
runs dry, regardless of remaining quota elsewhere.

```text
$ gh api rate_limit
{"core":{"limit":5000,"remaining":4758,...},
 "graphql":{"limit":5000,"remaining":0,"reset":1786032358,"used":5000}}
```

If a script only calls `gh pr list` (GraphQL-backed), it stops working the
moment GraphQL hits its cap. If the same script also calls `gh api` (REST)
as a fallback, it keeps working until REST also hits its cap — typically
not until the next hourly reset window, since the two buckets reset
independently.

## Pattern: GraphQL-first → REST fallback

For PR discovery, do this:

```bash
# Primary: gh pr list (GraphQL bucket)
gh pr list --repo "$repo" --state merged --limit 100 \
           --json number,title,url,mergedAt

# Fallback: gh api REST with the same query semantics
gh api -H "Accept: application/vnd.github+json" \
       --paginate \
       "repos/${repo}/pulls?state=closed&sort=updated&direction=desc&per_page=100"
```

Then normalize REST output to GraphQL's field names (`merged_at` → `mergedAt`,
`html_url` → `url`) and run the existing jq filter.

## Worked example: bug-hunt-daily.sh get_merged_prs

**Before** (single bucket, fails whenever GraphQL exhausts):

```bash
if ! gh pr list --repo "$repo" --state merged --limit 100 \
                --json number,title,url,mergedAt > "$gh_out"; then
    rm -f "$gh_out"
    return 1
fi
```

**After** (dual bucket, fails closed only when both buckets exhaust):

```bash
# Try GraphQL first
if gh pr list --repo "$repo" --state merged --limit 100 \
              --json number,title,url,mergedAt > "$gh_out" 2>/dev/null; then
    if jq --arg since "$since_date" --arg repo "$repo" \
          '[.[] | select(.mergedAt >= $since) | . + {repo: $repo}]' "$gh_out" \
          | _merge_merged_pr_streams "$since_date" "$repo"; then
        rm -f "$gh_out"
        return 0
    fi
else
    graphql_rc=1
fi
rm -f "$gh_out"

# Fall back to REST
log_warn "$repo: gh pr list (GraphQL) failed (rc=$graphql_rc) — falling back to gh api (REST)"
local rest_out
if rest_out=$(_rest_list_merged_prs "$repo"); then
    if printf '%s' "$rest_out" | _merge_merged_pr_streams "$since_date" "$repo"; then
        return 0
    fi
fi

# Both exhausted: print minimal stderr marker so the caller's failure block still fires.
echo "GraphQL and REST PR discovery both failed for $repo" >&2
return 1
```

Production commit `1e500c1ae8` on `fix/bug-hunt-rest-fallback` in the
`jleechanorg/jleechanbrain` repo.

## Field-name normalization

GraphQL outputs:
- `mergedAt`, `url`, `number`, `title`

REST outputs:
- `merged_at`, `html_url`, `number`, `title`

A small jq normalizes both into a single canonical shape:

```jq
[ .[]
  | ( .mergedAt // .merged_at ) as $merged_at
  | ( .url // .html_url ) as $url
  | select($merged_at != null and $merged_at >= $since)
  | { number: (.number // 0),
      title:  (.title  // ""),
      url:    $url,
      mergedAt: $merged_at,
      repo:   $repo }
]
```

The `//` (alternative) operator picks whichever field name the source
provides, so the same filter works on both GraphQL output and normalized
REST output.

## Failure classification: don't say "rate limit or connection issue"

When a script's PR discovery fails, the alert shouldn't dump a generic
"API rate limit or connection issue" — that hides which failure class
the operator needs to act on. Add a classifier that tags the failure
so the alert can say *what* happened:

```bash
classify_gh_failure() {
    local msg="${1:-$(cat)}"
    case "$msg" in
        *"API rate limit"*|*"rate limit already exceeded"*|*"exceeded the rate limit"*)
            echo "graphql_rate_limit" ;;
        *"Could not resolve host"*|*"Connection refused"*|*"network is unreachable"*|*"connection reset"*|*"connection timed out"*|*"TLS handshake"*)
            echo "connection" ;;
        *"Bad credentials"*|*"401"*|*"authentication"*|*"GH_TOKEN"*|*"GITHUB_TOKEN"*)
            echo "auth" ;;
        *)
            echo "other" ;;
    esac
}
```

Then `classify_gh_failure` becomes the trigger for the fallback decision:

- `graphql_rate_limit` → REST fallback (different bucket, will work)
- `connection` → REST fallback (different transport, may work)
- `auth` → fail closed; REST won't help, page a human
- `other` → fail closed; emit the stderr text so the next run can be diagnosed

The same classifier feeds the Slack alert tagging so the operator sees
"jleechanorg/jleechanbrain → graphql_rate_limit" instead of "API rate limit
or connection issue". Lessons-learned (2026-08-07 bug-hunt incident):
the original alert said "or connection issue" for *days* before anyone
realized it was specifically GraphQL bucket exhaustion at 5000/5000.

## Multi-target loops: continue across repos, don't abort on first failure

The fallback pattern above only matters if the *outer loop* keeps running
when one target fails. A common bug (2026-08-07 bug-hunt-daily.sh) is:

```bash
# ANTI-PATTERN: exits the whole run on the first repo's failure
for REPO in "${REPOS[@]}"; do
    if ! get_merged_prs "$REPO" > "$tmp" 2> "$err"; then
        post_slack_alert "$REPO failed"
        exit 1   # ← kills the loop; repos 2-N never attempted
    fi
done
```

Fix: collect per-target failures, *continue* the loop, then decide the
report shape at the end:

```bash
declare -a REPO_FAIL_REPOS=() REPO_FAIL_CLASSES=() REPO_FAIL_MSGS=()
TOTAL_PRS=0
PRS_JSON="[]"

for REPO in "${REPOS[@]}"; do
    if prs=$(get_merged_prs_with_fallback "$REPO" 2>/dev/null); then
        PRS_JSON=$(jq -n --argjson cur "$PRS_JSON" --argjson new "$prs" '$cur + $new')
        TOTAL_PRS=$((TOTAL_PRS + $(echo "$prs" | jq length)))
    else
        REPO_FAIL_REPOS+=("$REPO")
        REPO_FAIL_CLASSES+=("${GET_PRS_FAIL_CLASS:-other}")
        REPO_FAIL_MSGS+=("${GET_PRS_FAIL_MSG:-unknown}")
    fi
done

# Three report shapes depending on how many failed:
# 1. All repos failed  → dedicated alert, exit 4 ("don't keep retrying silently")
# 2. Partial failure   → success report + `:warning:` block listing which repos
# 3. Partial failure   with zero successes → no-input report + failure summary
REPO_COUNT="${#REPOS[@]}"
FAIL_COUNT="${#REPO_FAIL_REPOS[@]}"
if [ "$TOTAL_PRS" -eq 0 ] && [ "$FAIL_COUNT" -eq "$REPO_COUNT" ]; then
    post_all_failed_alert
    exit 4
elif [ "$FAIL_COUNT" -gt 0 ]; then
    post_summary_with_warning_block
fi
```

Verify the partial-failure rendering doesn't drop newlines: `${FAIL_REPO_LIST}` is
built with `+=` and embedded real newlines, NOT `\n` literals — `printf '%s'`
preserves them but echo won't. Test this in the test harness, not at runtime.

## Pitfalls

### macOS `date -d` is not GNU

Operational scripts that compute `since_date = "N days ago"` often shell out
to `date`. Three variants exist:

- macOS BSD: `date -v-Nd '+%Y-%m-%d'`
- GNU:      `date -d 'N days ago' '+%Y-%m-%d'`
- gdate (Homebrew coreutils): `gdate -d 'N days ago' '+%Y-%m-%d'`

When none works (CI without coreutils, alpine containers, fresh install), a
2-line Python fallback always works:

```bash
since_date=$(python3 -c "import datetime; print((datetime.datetime.utcnow() - datetime.timedelta(days=N)).strftime('%Y-%m-%d'))")
```

Putting all four into one cascade avoids polluting the stdout JSON stream
with stderr from a failing `date` invocation. Bug-hunt-daily.sh was emitting
`date: illegal option -- d` into the failure path, which polluted test
assertions in the regression suite.

### `gh pr create` is GraphQL-backed (companion pitfall, see claude-code-claudem)

`gh pr create` uses GraphQL even though REST `POST /repos/.../pulls` is fine.
Worker recovery pattern documented in `claude-code-claudem` v1.3.0: edit
file + push via git, then POST REST. This skill complements that pitfall
for read-side scripts (PR discovery, issue listing, branch enumeration).

**Verified recipe (2026-08-18, PR #827 jleechanorg/jleechanbrain):**

```bash
# 1. Build the PR payload as JSON (multi-line body stays clean via heredoc)
python3 - <<'PY' > /tmp/pr_body.json
import json
body = """## Problem
...multi-line body..."""
print(json.dumps({
  "title": "fix(cron): short title",
  "head":  "feat/branch-name",
  "base":  "main",
  "body":  body,
}))
PY

# 2. POST via REST (different rate-limit bucket from gh pr create's GraphQL)
gh api --method POST repos/<owner>/<repo>/pulls --input /tmp/pr_body.json \
  --jq '.html_url, .number'
```

Symptom that triggers this fallback: `gh pr create ...` returns
`pull request create failed: GraphQL: API rate limit already exceeded for user ID 13840161.`

Pitfall: do NOT immediately retry `gh pr create` against the same bucket —
that burns the same 30-min reset window. Always fall back to REST on the
first `API rate limit` error.

When GraphQL is the better choice: bulk label/assignee mutation,
draft-toggle (REST silently no-ops — use `github-pr-draft-toggle` skill for
that), issue triaging across many repos at once.

When REST is the better choice: single-resource creation (PR, issue,
comment, label), anything that would otherwise hit the GraphQL `user_id`
quota.

### Per-PR GraphQL commands (`gh pr view`, `gh pr checks`) and their REST fallbacks (verified 2026-08-16, dropped-thread spot-check)

Every per-PR query command is GraphQL-backed and 403s the same way when
the bucket is exhausted. The fallbacks below are the **REST equivalents**
the operator can hit when the visual / status / spot-check tools all
return `API rate limit already exceeded`:

| GraphQL command | REST fallback | Notes |
|---|---|---|
| `gh pr view <N> --json ...` | `gh api /repos/<owner>/<repo>/pulls/<N>` | Field names differ — see normalization below. |
| `gh pr checks <N>` (commit status + check runs, one row each) | `gh api /repos/<owner>/<repo>/commits/<sha>/check-runs` (GitHub Actions check runs) **OR** `gh api /repos/<owner>/<repo>/commits/<sha>/status` (legacy commit status) | Get the head SHA via `gh api /repos/<owner>/<repo>/pulls/<N> --jq .head.sha` first. |
| `gh pr view <N> --json comments` | `gh api /repos/<owner>/<repo>/issues/<N>/comments` (PRs use the issues endpoint for inline comments) | Returns `user.login`, `created_at`, `body` — sufficient for triage. |
| `gh pr view <N> --json reviews` | `gh api /repos/<owner>/<repo>/pulls/<N>/reviews` | Review submissions + states. |
| `gh pr view <N> --json files` | `gh api /repos/<owner>/<repo>/pulls/<N>/files` | Paginated, 100 per page. |
| `gh pr view <N> --json commits` | `gh api /repos/<owner>/<repo>/pulls/<N>/commits` | Paginated, 100 per page. |

**Why this matters for spot-checks:** the operator's "spot-check new
PRs as they appear" workflow — exactly what the dropped-thread followup
asks from the agent — runs `gh pr view` and `gh pr checks` per PR. If
3+ spot-checks happen in a row when the GraphQL bucket is at 4990+/5000,
the 4th and onward all 403. The right move is **identify the bucket
exhaustion on the first failure, then batch the rest of the spot-check
on REST**.

**Field-name normalization for `gh pr view` → `gh api /pulls/<N>`:**

The full per-PR field set is wider than the merged-PR list. GraphQL
returns camelCase; REST returns snake_case. The drop-in REST command:

```bash
gh api /repos/<owner>/<repo>/pulls/<N> --jq '{
  number, title, state, draft, merged_at, mergeable,
  additions, deletions, changed_files,
  head_ref: .head.ref,
  head_sha: .head.sha,
  user: .user.login,
  created_at, html_url
}'
```

Verified 2026-08-16 on `jleechanorg/worldarchitect.ai` PRs #8843, #8855,
#8856, #8864 during a dropped-thread spot-check after `gh pr view` 403'd
across all 4 with `GraphQL: API rate limit already exceeded`. The REST
pull returned the same 5 fields needed for the spot-check (state,
mergeable, merged_at, head SHA, additions/deletions/files-changed) plus
the commit list via the secondary call below.

**Pairing for the spot-check workflow:** when the dropped-thread /
babysit / bring-to-green followup needs a multi-PR state read, **lead
with one REST `gh api /pulls/<N>` per PR to get the head SHA**, then
follow with `gh api /commits/<sha>/check-runs` and `gh api /pulls/<N>/commits`
to read the green-gate signal and the commit history. This pattern
stays inside the REST bucket and does not touch the GraphQL bucket at
all — so a single burst of 10+ PRs works even if the GraphQL bucket
is at 0/5000.

**Subtle gotcha — `gh pr view --json mergeable`:** REST returns
`mergeable: null` (not `true`/`false`) when GitHub has not yet computed
the mergeability state. This is **not** a rate-limit artifact — it's the
REST API's lazy-evaluation contract. For a definitive mergeable signal
you must re-fetch after a few seconds; for a spot-check the null is
interpretable as "GitHub hasn't computed yet" and not an error.

### `gh api -f labels=...` 422s on array-typed fields; use `--input <file.json>`

When creating or editing an issue/PR via `gh api` REST (the right path when
GraphQL bucket is exhausted), passing array-typed fields with `-f` does NOT
work — `-f` is the form-string variant and coerces everything to a string.

**Symptom (verified 2026-08-14 in this session):**

```bash
gh api --method POST "repos/jleechanorg/worldarchitect.ai/issues" \
       -f title='[design] x' \
       -f body='...' \
       -f labels='enhancement,game-design'
# → 422: For 'properties/labels', "enhancement,game-design" is not an array.
```

**Fix — pipe a full JSON body via `--input <file>`:**

```bash
# Build payload as JSON, write to a temp file, then --input
python3 -c "
import json
print(json.dumps({
  'title': '[design] x',
  'body': '...',
  'labels': ['enhancement', 'game-design'],
  'assignees': ['${GITHUB_USER}'],
}))
" > /tmp/issue.json

gh api --method POST "repos/jleechanorg/worldarchitect.ai/issues" \
       --input /tmp/issue.json
```

**Why this matters even though `gh issue create --label "a,b"` works:**

`gh issue create --label "a,b"` parses the comma-separated string *as a CLI
flag* and converts to an array internally. `gh api -f labels=...` passes the
value straight to the REST API as a JSON STRING, which fails schema
validation. There is no way to get `gh api` to interpret a comma-separated
list as an array.

**General rule:** for any `gh api` POST/PATCH that takes array fields
(`labels`, `assignees`, custom field collections), use `--input` with a JSON
payload file. `python3 -c 'import json; print(json.dumps(...))'` is a
robust single-shot JSON-builder for scripts. Avoid:
- `-F labels=enhancement -F labels=game-design` (only the LAST value is kept)
- `-F labels[]=enhancement -F labels[]=game-design` (works in `gh` ≥2.40, but
  inconsistent across gh versions; `--input` is the portable path)

Verified 2026-08-14: 6 issues created cleanly with `--input` in one batch
after the `-f labels=...` failure cost one wasted round-trip and a Python
batch retry.

### BOTH buckets can hit "secondary rate limit" simultaneously (verified 2026-08-13)

The dual-bucket pattern above assumes one bucket works while the other is
exhausted. But GitHub also enforces a **secondary rate limit** (abuse
prevention, separate from the per-hour 5000-quota) that applies across
BOTH REST and GraphQL for "creating content too quickly." Symptom:

```text
gh pr create ...         → GraphQL: API rate limit already exceeded
gh api POST /repos/.../pulls → 403 You have exceeded a secondary rate limit
                              and have been temporarily blocked from content
                              creation. Please retry your request again later.
```

When both buckets refuse `gh pr create`, the agent's instinct is to:
- Blind-sleep-retry (wastes turns, may exhaust cron time budget).
- Spawn a worker (compounds the same rate-limit pressure).
- Stop and ask the user (violates `finish-the-job` "drive to conclusion").

The right move is a **one-time cron retry** scheduled for after the rate
limit's `resetAt` window. Verified 2026-08-13:

```bash
# 1. Check the reset window
gh api graphql -f query='query { rateLimit { remaining resetAt } }'
# → {"data":{"rateLimit":{"remaining":0,"resetAt":"2026-08-14T05:18:24Z"}}}

# 2. Schedule a one-time cron for ~5min after resetAt (account for clock skew)
hermes cron create "12m" \
  --name 'retry gh pr create after rate limit reset' \
  --deliver 'slack:<originating-channel>' \
  --prompt '<exact gh pr create command + body-file>'
```

Why a one-time cron and not a sleep loop:
- Sleep loops burn turn budget and the agent has no idea when the reset
  actually happens. The cron fires at the right time without spending
  turns.
- The cron runs in a fresh session with the prompt in context — no risk
  of stale state contaminating the retry.
- If the second attempt also fails (rare), the cron job itself can
  fall back to REST + curl, or report the branch URL so the user can
  open the PR themselves.

The companion pattern: when `gh pr create` fails on a non-trivial session,
the agent's final reply should include the cron job ID AND the branch
URL (`https://github.com/<owner>/<repo>/tree/<branch>`) so the user can
click "Compare & pull request" themselves if the cron also fails.

### `gh pr create --label "<a>,<b>"` aborts the whole command on unknown label (verified 2026-08-25, PR #9365)

`gh pr create` does NOT pre-flight the `--label` list against the repo's
existing labels. If ANY label in the comma-separated list doesn't exist,
`gh pr create` exits non-zero AFTER validating other inputs but BEFORE
the PR object is created. Symptom: a shell-level `exit_code: 0` from
the outer command (because the bash pipe succeeded for `--body` file
write), the command's own stderr ends with
`could not add label: '<missing-label>' not found`, and the operator
sees NO PR URL on the remote. The push succeeded (the branch is on
origin), but no PR was opened. The branch is then stranded until a
follow-up `gh pr create` (without the bad label) is run.

Verified on `jleechanorg/worldarchitect.ai` (2026-08-25, PR #9365): the
`minimax-M3` label had never been created on that repo; `--label
"claude,minimax-M3"` aborted with `could not add label: 'minimax-M3' not
found`. Branch `feat/dashboard-header-right-align-mobile` was on origin
with one commit but no PR — fixed by creating the label via REST, then
running `gh pr create --label "claude"` (single, known label), then
applying the second label via REST post-create:

```bash
# 1. Discover existing labels
gh label list --repo <OWNER>/<REPO> --limit 500 --json name --jq '.[].name'

# 2. Create missing labels BEFORE running gh pr create
gh api repos/<OWNER>/<REPO>/labels -X POST \
  -f name='<label>' -f color='<hex>' -f description='<text>'

# 3. Use only labels you can verify exist
gh pr create --base main --head feat/<slug> \
  --label "<only-known-labels>" \
  --title "..." --body "..."

# 4. Apply missing labels post-create via REST
gh api repos/<OWNER>/<REPO>/issues/<N>/labels -X POST \
  -f labels[]=<label>
```

**Defensive helper for repeated workflows:**

```bash
ensure_label() {
  local repo="$1" name="$2" color="${3:-5319e7}" desc="${4:-authored by $name}"
  gh label list --repo "$repo" --limit 500 --json name -q '.[] | .name' \
    | grep -qxF "$name" \
    || gh api "repos/$repo/labels" -X POST \
         -f name="$name" -f color="$color" -f description="$desc" >/dev/null
}
# Before any gh pr create --label call:
ensure_label <OWNER>/<REPO> claude       1D76DB 'Changes authored with Claude Code'
ensure_label <OWNER>/<REPO> 'minimax-M3' 5319e7 'Code authored by MiniMax M3 via claudem/hermes'
gh pr create --label "claude,minimax-M3" ...
```

**Why this isn't a rate-limit failure:** the error message ("not found")
is a 422 Validation Failed response, not a 429 / 403 rate-limit
response. Don't waste time waiting on bucket resets; the label just
doesn't exist and needs to be created.

### When the workflow has a hard gate that requires the issue: `br create` bead first (verified 2026-08-16, /repro combat-83)

Some workflows (`/repro`, beads-required trackers, sync-from-origin pipelines)
have a **hard gate** that requires the GitHub issue to exist on `origin`
before any other work can proceed. When the secondary rate limit blocks
issue creation, the gate is stuck.

**Why the bead-first workaround exists:** the secondary limit can persist
for 5–60 minutes — much longer than the workflow's session budget. The
**`br create` bead is the durable record on `origin`** via the local
repo's `.beads/issues.jsonl` (committed to git, pushed to origin). The
bead and the eventual GitHub issue carry the same body text, so the
moment the issue lands it cross-links to the existing bead and the bead
de-duplicates — no double-filing.

**Recipe (verified 2026-08-16, 02:54:21 UTC, request_id `C934:D0E24:12C0E93:1634C76:6A81265D`):**

1. Write the issue body to a local file (NOT `/tmp/...` — `execute_code`
   is sandbox-scoped per call): `~/.smartclaw/wa-repro-<slug>/issue-body.md`.
2. Copy the same body to `~/.smartclaw/wa-repro-<slug>/bead-body.md` so the
   bead carries the canonical-state contradiction + scene/turn ref + repro
   recipe, identical to the issue body. Beads and issues stay coupled.
3. `cd <repo-root> && br create "<title>" --type bug --priority 2 \
   --description-file <bead-body>` — produces the bead ID on stdout. The
   default priority is P2 (bug); only override if the user explicitly
   requests otherwise.
4. Continue the diagnostic (copy_campaign.py, replay, etc.) — the workflow
   is **unblocked by the bead existing**, because the bead is the durable
   record on `origin` until the GitHub issue eventually lands.
5. Post the consolidated reply with the bead ID + cron job ID + "issue
   pending retry" status — the user has the durable record immediately,
   the GitHub issue is best-effort.
6. The retry cron fires after the 5–60 min reset window and POSTs the
   same body via REST `urllib.request`. The new issue number is posted
   back to the originating thread.

**Why `br create` doesn't trip the secondary limit:** `br` writes to the
**local `beads_rust` SQLite store + `.beads/issues.jsonl`**, which is a
git commit, not a GitHub API POST. The secondary rate limit is a
GitHub-side abuse-prevention throttle on `POST /repos/.../issues`; it
does not apply to local file writes. The bead is the durable record on
`origin` only after the next commit + push lands on the repo — which
the workflow's normal CI/CD will surface, and the user can see at any
time via `br show <bead-id>` or `git log -p .beads/issues.jsonl`.

**Captured the request_id for forensics:** always echo the `request_id`
from the secondary-limit 403 response in the cron log and the user-facing
status. It's the unique identifier that distinguishes a true secondary
limit from a generic 403 (auth failure, scope issue, etc.) — once you've
seen the 403 body containing "exceeded a secondary rate limit and have
been temporarily blocked from content creation" with the `request_id`,
that is the unambiguous signature.

### Single-bucket scripts are fragile

Any operational script written before the user encountered a real bucket
exhaustion will be single-bucket. The 2026-08-06 incident was the first
time `bug-hunt-daily.sh` had genuinely run out of GraphQL quota — for years
the assumption "gh pr list always works" had held. The fix isn't just "add
a fallback" — it's "treat rate limits as inevitable" in operational
scripts. Apply dual-bucket logic when:

- The script runs on a launchd / cron schedule that fires repeatedly
  (multi-day exposure to bucket exhaustion).
- The script is one-shot but might run after a heavy batch (other workers
  consuming the bucket on the same user token).
- The script publishes a public artifact (Slack message, GitHub issue) —
  failure surfaces to the operator.

### Worker dispatch can die on max-turns without producing edits

`bash -lic 'claudem -p "..." --max-turns N'` may exit with code 1 after
hitting the turn budget without committing a single file. The default
`--max-turns 60` is **too low for a focused PR that touches 5+ files**
(prompt edits + shared prompt + contract test + commit + push + PR create
+ Slack post). Raise to 90-120 for that class of work, or split the dispatch:

```bash
# Phase 1 — apply edits (60 turns usually enough)
claudem -p "Edit files only, no commit, no push" --max-turns 60

# Phase 2 — verify + commit + push + open PR (parent finishes inline)
git -C <worktree> status --short --branch
git -C <worktree> diff --stat origin/main..HEAD
./venv/bin/python -m pytest -q mvp_site/tests/test_*.py
git -C <worktree> add ... && git -C <worktree> commit ...
git -C <worktree> push -u origin HEAD
# open PR via REST if gh hits GraphQL bucket
curl -s -X POST ...
```

The **audit step is critical** before deciding "spawn another worker" vs
"finish inline":

```bash
worktree=${HOME}/wt-<topic>
git -C "$worktree" status --short --branch
git -C "$worktree" log origin/main..HEAD --oneline
# Note: `git status --short` shows M = modified, A = added, ?? = untracked
# `git log origin/main..HEAD --oneline` shows committed work
```

Decision tree when the worker exits with code 1:

| Worktree state | Action |
|---|---|
| Clean, no commits ahead, no untracked | Spawn **fresh** worker on same worktree (max-turns was the ceiling, not the task) |
| Dirty with new files but no commits | **Finish inline** — extend the same worktree, audit each file, commit, push, open PR |
| Dirty with commits but tests failing | Pivot to inline audit; tests are the canonical signal |
| Clean with commits pushed + no PR | Open the PR via REST `POST /repos/.../pulls` — don't re-spawn the worker for push-only work |

The "spawn another worker" path is the **last** option, not the first:
re-spawning compounds max-turns pressure on the same provider bucket and
risks the same failure mode. The audit-then-inline-then-REST-PR pattern
resolves 90% of these incidents in the same session.

## Test harness pattern: hermetic bash function testing

Testing a script that calls `gh` is painful because `gh` is stateful (auth,
rate limits, network). Three techniques make it deterministic:

1. **Stub `gh` via PATH**: place a temp dir at the FRONT of PATH and put a
   `gh` executable there. The stub reads `$GH_STUB_MODE` to decide which
   subcommand fails/succeeds.

2. **Extract just the functions you need** with awk range-pattern matching
   (NOT a function-body `next` — `next` inside an awk function is illegal).

3. **Source in a sub-process with stdout captured separately from stderr**:
   log_warn noise belongs on stderr; assertions inspect the JSON on stdout.

### Non-obvious gotchas (took 4 iterations to get right)

- **`awk 'next' inside a function definition is illegal.** Use range
  patterns (`p==1 && /^}/ { ... p=0 }`) instead of nested `next` calls.
- **`bash -c "..."` heredocs interpolate `$1` at write time**, not run time.
  Use single-quoted heredocs (`<<'EOSH'`) to keep placeholders literal until
  the sub-shell executes.
- **`set -u` boundary matters.** The test wrapper's `$1` is unbound until
  invocation; put `set -u` only at the top of the test wrapper, NOT inside
  the `bash -c "..."` sub-shell that sources the live functions.
- **Capture stderr separately.** If `log_warn` writes to stderr but your
  assertion reads combined stdout+stderr (`2>&1`), the warning text
  contaminates the JSON you tried to parse.
- **`out=$(func)` does NOT propagate globals.** Bash command substitution
  runs in a subshell; any globals set inside `func` (e.g. `GET_PRS_FAIL_CLASS`)
  vanish when the subshell exits. Two consequences for testing:
  - If you want to assert on globals, call the function directly (not in
    `$()`), capture rc via a global like `CALL_RC`, and disable errexit
    around the call: `set +e; func; CALL_RC=$?; set -e`.
  - If you only need the stdout, redirect to a temp file *first* and then
    `cat` the file in the parent — that also preserves the globals.
- **Write shell-stub args via `printf '%q'`, not `$var` heredocs.** Heredocs
  with literal `'...'` interpolation break on embedded single quotes or
  parentheses (e.g. `Bad credentials (HTTP 401)`). `printf '%q' "$var"`
  produces a shell-escaped literal that re-parses correctly inside the
  stub script.

## Reference

- Production fix: `scripts/bug-hunt-daily.sh` in `jleechanorg/jleechanbrain`,
  commit `1e500c1ae8` on `fix/bug-hunt-rest-fallback`.
- Regression test: `scripts/tests/test_bug_hunt_rest_fallback.sh` — three
  cases (T1 GraphQL fail + REST ok, T2 GraphQL fail + REST empty, T3 both
  fail). 138 LOC, no external deps beyond `jq`.
- Companion pitfall in `claude-code-claudem` v1.3.0: "gh pr create is
  GraphQL-backed and fails when that bucket is exhausted even though REST
  is fine" — covers write-side recovery. This skill covers read-side.
- Rule documented in `env-preferences.mdc` ("GitHub CLI — dual rate-limit
  buckets"): "When one is limited, try the same query via the other before
  backing off — in BOTH directions." This skill is the implementation
  pattern for that rule.
- Supporting files:
  - `references/diagnosis-recipe.md` — quick-checklist for diagnosing
    operational-script GH failures
  - `templates/hermetic-gh-stub-test.sh` — boilerplate test harness