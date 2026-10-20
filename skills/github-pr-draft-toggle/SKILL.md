---
name: github-pr-draft-toggle
description: Toggle PR ready/draft via GraphQL. REST silently no-ops.
version: 1.0.0
---

# GitHub PR Draft Toggle — verified recipes

Single source of truth for the `gh pr ready` / `gh pr ready --undo` operations that always trip on GraphQL rate limits and silent REST no-ops. Every multi-PR draft sweep, every bulk ready-toggle, every "set this to draft" needs these recipes.

## The two-state problem

`gh pr ready` and `gh pr ready --undo` both hit the GitHub GraphQL API under the hood (`markPullRequestReadyForReview` and `convertPullRequestToDraft` mutations). When the **GraphQL rate-limit bucket is `remaining=0`**, neither flag will work, and there is **no REST PATCH body that succeeds**. Both directions silent-no-op (HTTP 200, state unchanged). Verified independently for both transitions: forward on PR #8699 (2026-08-03); reverse on a 325-PR org sweep (2026-08-04).

## Forward: draft → ready for review

```bash
# 1. Get the PR node id (REST works always)
NODE_ID=$(gh api repos/$OWNER/$REPO/pulls/$N --jq .node_id)

# 2. Issue the GraphQL mutation (MUST use --input -; see trap below)
echo "{\"query\":\"mutation(\$prId: ID!) { markPullRequestReadyForReview(input: {pullRequestId: \$prId}) { pullRequest { id isDraft } } }\",\"variables\":{\"prId\":\"$NODE_ID\"}}" \
  | gh api graphql --input -
```

Or via `gh pr ready` / `gh pr ready --undo N` — both wrap the same GraphQL call.

**REST sibling-field unlock** (works when GraphQL is rate-limited):

```bash
gh api -X PATCH repos/$OWNER/$REPO/pulls/$N \
  -f draft=false \
  -f draft_message=ready
```

The sibling field (`draft_message=ready`) appears to make GitHub accept the PATCH as "intentional"; bare `draft=false` alone silently no-ops with HTTP 200. Verify with `gh api repos/$OWNER/$REPO/pulls/$N --jq .draft`.

⚠️ **The `-f prId="$NODE_ID"` form shown in older revisions of this skill is BROKEN.** Same trap as the Reverse direction: `gh api graphql -f/-F` flattens form fields into the body and the server receives `prId` as a string, not as a GraphQL ID. Use `--input -` (see recipe above and the Critical trap below). Confirmed 2026-08-06 — both directions must use the pipe form.

## Reverse: ready → draft (the harder direction)

```bash
NODE_ID=$(gh api repos/$OWNER/$REPO/pulls/$N --jq .node_id)
echo "{\"query\":\"mutation(\$prId: ID!) { convertPullRequestToDraft(input: {pullRequestId: \$prId}) { pullRequest { id isDraft } } }\",\"variables\":{\"prId\":\"$NODE_ID\"}}" \
  | gh api graphql --input -
```

Or shorter: `gh pr ready --undo $N -R $OWNER/$REPO`.

⚠️ **Critical gh CLI trap (2026-08-06):** Do NOT pass `query` and `variables` as separate `-f` fields (`-f query=... -f variables="{...}"`). The string form is rejected with `Variable $prId of type ID! was provided invalid value` — `gh api graphql -f/-F` flattens fields into the form body and the `variables` JSON string doesn't deserialize into the GraphQL variables map on the server. Only `--input -` (or `--input <file.json>`) with a single JSON body works. Use the pipe recipe above.

**There is NO REST sibling-field unlock for the reverse direction.** Verified by trying 5 candidates on `jleechanorg/bp-telemetry-core-fork#9` (all silent-no-op with HTTP 200, draft stays false):

| Attempt | Body | Result |
|---|---|---|
| 1 | `-f draft=true` | no-op |
| 2 | `-f draft=true -f draft_message=back_to_draft` | no-op |
| 3 | `-f draft=true -f draft_message=stale_resume` | no-op |
| 4 | `-f draft=true -f body=test` | no-op |
| 5 | `PATCH /repos/{O}/{R}/issues/{n} -f draft=true` | no-op |

If you find yourself fishing sibling fields, stop. Use the GraphQL mutation. Per-hour budget is 5000 mutations; a 100-PR sweep consumes 1% of it.

## Bulk sweep — handle rate-limit reset

When you have **N > 1** PRs to toggle and the GraphQL budget is the gating factor:

1. Probe rate limit:
   ```bash
   gh api graphql -f 'query={rateLimit{limit remaining resetAt}}'
   ```
2. If `remaining >= N + 5`, run the loop inline.
3. Otherwise, `resetAt` is the target. Queue a one-time `no_agent` cron job (`hermes cron create --at {resetAt + 2m} --no-agent --script <flipper>`), where the flipper script loops the mutation per PR, verifies each via REST, and prints a summary as stdout. Cron delivers the script's stdout back to the originating Slack thread.
4. Reference implementation: `~/.smartclaw/scripts/draft_flipper_v3.py` — reads `/tmp/need_flip.json`, filters already-draft/closed/merged, uses `gh api graphql --input -` with a single piped JSON body per PR (the only known-working invocation), writes per-PR results to `/tmp/draft_flip_v3_results.jsonl`. Earlier v2 used `-f query=... -f variables=...` and silently failed all 322 PRs with `Variable $prId of type ID! was provided invalid value` — use v3. After any sweep that bottoms-out the GraphQL bucket, also keep `~/.smartclaw/scripts/draft_flipper_v3_retry.py` handy — it handles the post-reset retry of failures against `/tmp/need_flip_retry.json`.

## Forward direction also needs --input -

The Forward recipe above already uses `--input -`. If you find yourself copying from older revisions or other guides that show `-f prId=...`, use the pipe form in the recipe above — the `-f` form is broken for the same reason as the Reverse direction (server receives `prId` as a string, not as a GraphQL ID).

## Verification — "no errors" is NOT proof of success

`gh api graphql --input -` exits 0 even when the server rejects the mutation. The only safe completion signal is checking the response body for `data.convertPullRequestToDraft.pullRequest.isDraft == true` (Reverse) or `data.markPullRequestReadyForReview.pullRequest.isDraft == false` (Forward). Just because `parsed["errors"]` is empty does NOT mean the state changed.

A flipper script MUST:
1. Parse the response.
2. Check `parsed.get("errors")` is empty.
3. Check `data.<mutation>.pullRequest.isDraft` is the expected value.
4. After every N flips (or at end), sample-verify 3–5 PRs via REST `gh api repos/{O}/{R}/pulls/{N} --jq .draft` and assert `.draft == true` (Reverse) or `false` (Forward). If samples disagree with the script's notion of success, the script's success detector is wrong — fix it before continuing.

The 2026-08-06 v2 sweep shipped with `ok = not parsed.get("errors")` and missed that all 322 PRs returned errors with non-empty `errors[]` blocks — except that the local JSON-parse failure path returned `parsed == {}` so `not parsed.get("errors")` was True for everything. Always inspect the actual parsed object, not just "did parsing succeed."

## "Cron queued" ≠ "task done"

When the GraphQL bucket is exhausted and you queue a `no_agent` cron to run at `resetAt + N min`, the task is **in flight, not complete**. Do NOT post "task done, N PRs flipped" until the cron fires, returns its summary, AND you've verified the summary numbers match a sample REST check. A queued cron that fires into a still-broken script is the same as the broken script — the user only sees the cron summary, so any fix you made before queuing is what matters. (2026-08-06: queued v2 cron with broken recipe, declared "task in flight, expect results at 22:10 PT" — when the cron fired it reported 0/323 flipped. The user's "well fix the script and keep going, that doesnt count idiot" was a callback to this gap.)

Always verify the script actually works on a single test PR (check `isDraft` flipped) BEFORE queuing the bulk cron.

## Cross-check before flipping — worker activity on stale branches

Before flipping a batch of stale PRs, **cross-check both local and `/linux` worktrees** for any active checkout on the candidate's `headRefName`. If someone is actively rebasing on a branch, flipping its PR to draft breaks their flow.

```bash
# Local checkouts
for co in ${HOME}/projects/* ${HOME}/projects_other/* \
          ${HOME}/repos/jleechanorg/* ~/.worktrees/*; do
  [ -d "$co/.git" ] || continue
  branch=$(git -C "$co" rev-parse --abbrev-ref HEAD)
  repo=$(git -C "$co" remote get-url origin | sed 's/\.git$//' | awk -F/ '{print $(NF-1)"/"$NF}')
  echo "$repo|$branch|$co"
done

# /linux checkouts — WARNING: ssh jeff-ubuntu lands in /home/jleechan, NOT /home/jeff
ssh -o BatchMode=yes jeff-ubuntu 'bash -s' <<'EOF' > /tmp/linux_checkouts.txt
shopt -s nullglob
for dir in /home/jleechan/*/; do
  [ -d "$dir.git" ] || continue
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  repo=$(git -C "$dir" remote get-url origin 2>/dev/null | sed 's/\.git$//' | awk -F/ '{print $(NF-1)"/"$NF}')
  echo "$repo|$branch|$dir"
done
EOF
```

For each candidate, look up `(repo, headRefName)` in both lookup tables. If found and `git log -1 --format=%cI` is within the cutoff window, exclude from the flip.

## Linked support files

- `~/.smartclaw/scripts/draft_flipper_v3.py` — bulk ready→draft sweep script. Reads `/tmp/need_flip.json`, filters already-draft/closed/merged via REST pre-check, uses `gh api graphql --input -` with a single piped JSON body per PR (the only known-working invocation). Writes per-PR results to `/tmp/draft_flip_v3_results.jsonl`. Sample-verifies success via `data.convertPullRequestToDraft.pullRequest.isDraft == true` AND a post-run REST sample of 3–5 PRs (see "Verification" section above).
- `~/.smartclaw/scripts/draft_flipper_v3_retry.py` — companion retry script for sweeps that bottom out the GraphQL bucket mid-run. Reads `/tmp/need_flip_retry.json` (just the failures from the v3 sweep), runs the same `--input -` mutation loop, posts summary back. Use this whenever v3 reports `Flipped: N/total` with `N < total`.
- Plan + classification files produced during a sweep:
  - `/tmp/stale_pr_v2.json` — raw candidate list from org-wide REST scan
  - `/tmp/stale_pr_classified.json` — same list with mergeable/review metadata, `safe_to_flip` flag
  - `/tmp/draft_plan.json` — subset of classified items where `safe_to_flip: true`, fed to the flipper
  - `/tmp/need_flip.json` — actual flip list (after safe_to_flip filter)
  - `/tmp/need_flip_retry.json` — failure subset from a v3 run, fed to v3_retry
- References:
  - `references/2026-08-04-325-pr-sweep.md` — first production sweep, original script + REST-no-op discovery
  - `references/2026-08-06-v3-debug.md` — debugging session that surfaced the `-f variables=` trap and the verification gap (this session)

## Failure-mode cheat sheet

| Symptom | Cause | Fix |
|---|---|---|
| HTTP 200 but `.draft` unchanged | REST PATCH silent-no-op | Use GraphQL mutation |
| `error: API rate limit already exceeded for user ID N` | GraphQL bucket exhausted | Wait for `resetAt`, queue cron 2 min after |
| `graphql: Variable $prId of type ID! was provided invalid value` for every request | `gh api graphql -f query=... -f variables=...` (variables arrive as string, not JSON object) | Use `--input -` with piped JSON body — see Reverse recipe |
| `gh pr view` returns nothing | Uses GraphQL under the hood | Use REST `gh api repos/{O}/{R}/pulls/{N}` |
| `convertPullRequestToDraft` rejected on fork PR | Cross-fork restriction | Ensure `OWNER/REPO` matches the canonical PR base |
| Slack cron delivery empty | Script stdout empty (silent watchdog) | Print summary line unconditionally before exit |

## Anti-patterns

- ❌ Sibling-field fishing for the reverse direction (it does not exist)
- ❌ Trusting REST PATCH HTTP 200 as proof of state change — verify with a subsequent REST GET
- ❌ Bulk iterating `gh pr view --json` when GraphQL is locked — every call costs 1 mutation; loop REST instead and only call GraphQL for the toggle
- ❌ Searching for the SAME sibling field name across orgs hoping it unlocks somewhere — GitHub's draft toggle is uniform; no per-org override exists
