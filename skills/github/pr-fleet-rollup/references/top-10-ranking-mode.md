# Top-N Ranking Mode — GH issues + Slack threads + PRs

## When to load

When a `/roadmap`-style request asks for a **ranked N-list** ("top 10 bug fixes", "top 10 feature requests", "top 10 unresolved Slack threads") across a time window, NOT the standard cron thread-audit. Trigger phrases:

- "top 10 bug fixes last N days/weeks/months"
- "top 10 feature requests"
- "top 10 unresolved Slack threads"
- "rank the top N …" / "what are the top N …"
- Any `/roadmap`-trigger phrase combined with a ranked-list framing

This is a different shape from the standard `roadmap` skill output (§ A-H report). Here the deliverable is **3 ranked tables** (bugs / features / unresolved) with hyperlinks, not a thread-by-thread audit.

## Source data — multi-source fan-out

Unlike `pr-fleet-rollup` (which is PR-only), this mode joins **3 sources**:

| Source | Pull | Notes |
|---|---|---|
| Open GH issues | `gh issue list --state open --limit 200 --search 'updated:>=YYYY-MM-DD' --json number,title,body,labels,createdAt,updatedAt,comments,author` | Per repo across the fleet; 18 repos for jleechanorg. |
| Slack threads | `mcp__slack__conversations_history(channel_id=X, limit=200)` for each channel in scope | 4 of 14 channels typically `fetched_full`; 5 `not_in_channel` (bot not invited — flag as coverage gap). |
| Merged PRs | Already in `/tmp/gh-prs-14d.json` from the parent skill | Used only for the "what's already shipped" backdrop, NOT for the open-bugs ranking. |

**Run the 3 source pulls in parallel via `delegate_task` fan-out** (1 task per source). Each writes to `/tmp/<source>-14d.json`. Aggregation is a final `execute_code` step on the parent.

## Scoring formula (verified 2026-08-19)

For ranking open issues:

```
score = (recency_weight * 3) + (comment_count * 2) + (priority_label_value if exists else 0)

recency_weight = 5 if age_days < 1
               = 3 if age_days < 4
               = 1 if age_days < 8
               = 0 otherwise

priority_label_value = 10 if "priority/p0" in labels
                     = 5 if "priority/p1"
                     = 3 if "priority/p2"
                     = 1 if "priority/p3"
                     = 0 otherwise
```

For ranking unresolved Slack threads (heuristic; verified 2026-08-19):

```
score = (recency_weight) + (len(key_entities) * 2) + min(reply_count, 5)

recency_weight = 6 if last_reply_or_parent >= 2026-08-18
               = 4 if >= 2026-08-17
               = 2 if >= 2026-08-14
               = 1 if >= 2026-08-10
               = 0 otherwise

# Penalize pure bot-evidence posts (those are PR artifacts, not open work):
if "ai evidence" in title_snippet.lower(): score -= 4
if "ai terminal" in title_snippet.lower(): score -= 4
if "before" in title_snippet.lower() and "after" in title_snippet.lower(): score -= 4
```

## Classification noise filter (CRITICAL)

When using a thread-classifier that tags Slack messages as `BUG_FIX` / `FEATURE_REQUEST` / `UNRESOLVED_SLACK_THREAD` / `OTHER`, **the classifier WILL mis-tag these patterns** (verified 2026-08-19):

| Pattern in `title_snippet` | Wrong tag | Real category |
|---|---|---|
| `Run /af on this PR #NNNN` | `BUG_FIX` | operator dispatch instruction, not a bug |
| `Run /roadmap …` | `BUG_FIX` | operator meta-request, not a bug |
| `AI Evidence PR #NNNN …screenshot` | `UNRESOLVED_SLACK_THREAD` | bot artifact attached to a PR, not open work |
| `AI Terminal: worktree_X :white_check_mark: PR #NNNN …` | `UNRESOLVED_SLACK_THREAD` | bot evidence/summary post, not open work |
| `:camera_with_flash: AI Evidence …` | `UNRESOLVED_SLACK_THREAD` | PNG/MP4 attachment, not a thread awaiting action |

**Apply a filter BEFORE ranking.** Without it, top-10 lists are dominated by operator commands and bot evidence posts.

## Output shape (verified 2026-08-19)

For each of the 3 lists, emit a markdown table:

```markdown
| # | Score | Issue | Age | Comments | Title |
|---|------:|-------|----:|---------:|-------|
| 1 | 36.6 | [worldarchitect.ai#8990](https://github.com/jleechanorg/worldarchitect.ai/issues/8990) | 0.7d | 4 | [factory] PR8864: drive feat(custom-intake-questions) to /ready + screenshots |
```

Followed by a `## Slack-reported <bugs|features|unresolved>` subsection with the top 5 from Slack (if any). Always include a `## Verification` block stating channel coverage + repo coverage + the classification-noise filter applied.

## Pitfalls

- **Skew alarm.** If 7/10 top-bugs and 10/10 top-features come from a single repo, surface it: "X of top-10 are worldarchitect.ai — remaining N repos produced 0 high-scored items in window (dormant or sweep only pulled recent activity)."
- **5-of-N channels `not_in_channel`.** Bot is not invited to `#cmux`, `#mcp-mail`, `#ralph-status`, `#browserclaw`, `#agentf` (verified 2026-08-19). Document the gap in § Verification; do not silently produce a partial sweep.
- **"auto-saved locally" vs "pushed to jleechanorg/roadmap repo".** Cron-mode `/roadmap` pushes to the repo. Ad-hoc operator request like "top 10 bug fixes last 2 weeks" → save locally to `${HOME}/roadmap/<UTC-ts>-roadmap-14d-top-10s.md`, NO repo push (user didn't ask for it).
- **Score formula must be deterministic.** Same input → same rank. Document the formula above verbatim; do NOT improvise.
- **Open vs closed issues.** The default is `state=open`. If the user asks for "top 10 bugs we fixed in the last 2 weeks", switch to `state=closed` and pull closed-in-window issues (closedAt >= window_start).

## Companion

- Parent skill `pr-fleet-rollup` — PR-side data and kind-classification recipe.
- Sister skill `roadmap` (user-owned, not curator-managed) — the cron thread-audit shape. Do NOT modify it from autonomous curator passes; recommend `hermes curator adopt roadmap` if the top-10 ranking mode needs to live there.
- Verification 2026-08-19: applied to operator request "Run /roadmap for last 2 weeks and pick top 10 bug fixes and top 10 feature requests ... and maybe top 10 unresolved slck threads" → produced 3 ranked lists across 105 open issues + 233 Slack threads + 221 merged PRs; report saved to `${HOME}/roadmap/2026-08-19-0322Z-roadmap-14d-top-10s.md`.
