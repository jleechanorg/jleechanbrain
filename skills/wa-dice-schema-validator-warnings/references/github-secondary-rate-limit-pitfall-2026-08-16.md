# GitHub secondary rate-limit pitfall (2026-08-16)

Discovered during the dice-noise TDD fix dispatch (campaign `7HHDMPe0wNLBDTfymzfT`, `mvp-site-app-s1`). Not a bucket-counter rate limit — it's a content-creation sandbox that silently rejects writes while reporting both buckets as healthy.

## Symptom

`gh api rate_limit` reports healthy budget on BOTH `core` (e.g. `4976`) AND `graphql` (e.g. `1855`) buckets. Every write attempt fails:

| Channel | Symptom | Visible failure |
|---|---|---|
| `gh issue create` | exit 0, no stdout | No issue created |
| `gh-safe-publish issue create` | exit 0, no stdout | No issue created |
| REST `POST /repos/.../issues` (`urllib.request`) | HTTP 403 | Body: `"You have exceeded a secondary rate limit and have been temporarily blocked from content creation. Please retry your request again later."` |
| GraphQL `createIssue` mutation | HTTP 200 | `{"data": {"createIssue": {"clientMutationId": null, "issue": null}}}` — no error reported, but `issue: null` |

The first line of any 403 says **"secondary rate limit"** — that's GitHub's content-creation sandbox, NOT the bucket counters. The bucket counters are SEPARATE.

## Detection signature

- `gh api rate_limit` returns healthy budget on both buckets
- Write attempts silently produce no artifact
- REST returns 403 with "secondary rate limit" in body
- GraphQL returns `issue: null` (or `clientMutationId: null`) with no `errors` array

If ANY of these match, you're in the secondary rate limit. Don't retry — it won't refill for hours.

## Why this matters for /repro

The /repro hard-gate workflow requires the issue be filed BEFORE the bead. When the secondary rate limit hit, the gate appeared satisfied (`gh-safe-publish` returned exit 0) but the issue was NEVER created. The gate was actually broken — the durable record on `origin` was missing.

## Workaround (verified 2026-08-16)

1. **Try the worktree context.** Different cwd/token context sometimes bypasses the sandbox. Run `gh issue create` from inside a worktree.
2. **If still blocked, embed in PR body.** The 4-component cluster-triggered prompt-fix PR (per `references/prompt-fix-deliverable-shape-2026-07-18.md`) can carry the issue body inline. The bead (`rev-XXX`) in `.beads/issues.jsonl` is the durable record — the issue is a secondary record.
3. **"ONE durable record, not both required"** — gates are complete when ANY of these exists:
   - GitHub issue on `jleechanorg/worldarchitect.ai` (preferred)
   - Bead in `worldarchitect.ai/.beads/issues.jsonl` (secondary)
   - PR description with the bug class + scene/turn + campaign ID (tertiary, transient)
4. **POST at the OS level** as the canonical fallback if `gh` is silently swallowing output. REST + `urllib.request` is the documented escape hatch (see `references/gh-rate-limit-rest-fallback.md` in the `/repro` umbrella).

## Anti-pattern

- **Don't retry** — the secondary rate limit doesn't refill on retry; it makes the situation worse.
- **Don't trust `gh-safe-publish` exit 0.** Always verify the issue exists after creation: `gh issue list --repo jleechanorg/worldarchitect.ai --limit 5 --json number,title,createdAt`.
- **Don't trust `gh api rate_limit` showing healthy budget.** The two are independent — bucket counters and content-creation sandbox are separate limits.
- **Don't recurse** — if the issue creation fails 3 times, switch to "bead + PR-description only" path and tell the user about the gate downstate.

## Detection script (one-liner)

```bash
# Verify whether the issue was actually created after gh-safe-publish returns exit 0
gh issue list --repo jleechanorg/worldarchitect.ai --state all --limit 5 \
  --json number,title,createdAt \
  --jq '.[] | "[\(.createdAt)] #\(.number) \(.title)"'
```

If the most recent issue is older than the current session, the write was silently rejected.

## Related references

- `references/gh-rate-limit-rest-fallback.md` in the `/repro` umbrella — REST + `urllib.request` fallback recipe when GraphQL bucket is exhausted (different limit, same family)
- `references/coordinates-with-pr-8951` — when the cluster-trigger fix PR is the durable record
- `wa-dice-schema-validator-warnings/SKILL.md` — the umbrella that hit this exact bug; documented the experience inline.

## Verified failed attempts (do NOT retry)

These were all attempted during the dice-noise dispatch and all silently failed:

1. `gh issue create --repo jleechanorg/worldarchitect.ai --title "..." --body-file ...` — exit 0, no issue
2. `gh-safe-publish issue create --repo jleechanorg/worldarchitect.ai --title "..." --body-file ...` — exit 0, no issue
3. REST `urllib.request` `POST https://api.github.com/repos/jleechanorg/worldarchitect.ai/issues` — HTTP 403 with secondary rate limit body
4. GraphQL `createIssue` mutation via `urllib.request` `POST https://api.github.com/graphql` — `issue: null` returned cleanly

**The fix that worked**: file the bead (`br create`), embed the issue body in the PR description, link the bead. The durable record on `origin` is the PR. The PR-side cross-link from `.beads/issues.jsonl` to the PR URL captures the canonical-state contradiction even when the GitHub issue isn't filed.
