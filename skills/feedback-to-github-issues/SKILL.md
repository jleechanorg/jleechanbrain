---
name: feedback-to-github-issues
description: "File feedback dump as N issues. Use when triaging feedback."
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [GitHub, Issues, Triage, Feedback]
    related_skills: [github-issues, github-auth, gh-rate-limit-resilience]
---

# Feedback → GitHub Issues (batch triage)

## When to Use

- User pastes raw feedback and says "file these as issues", "log these as issues", "triage this", "track these".
- A review or analysis surfaces N distinct action items that should each become a tracked issue.
- A non-coder stakeholder gives feedback that needs to be captured as engineering backlog.

For **single** issue creation, use the `github-issues` skill directly. This skill is for the **batch** case (N ≥ 2).

## Workflow

### Step 1 — Extract discrete items

Read the source text and pull out each distinct suggestion / bug / request. Players often mumble multiple ideas into one paragraph; split them.

Example: a single user message containing a paragraph that mentions "override basic attributes, dice vs dice rolls, AI attribute values, margin of victory, AI aggressive, story cards" splits into **6 separate issues**, not 1.

### Step 2 — Search for duplicates FIRST

Before filing a single issue, search the repo for prior issues covering the same ground. Use both `gh api` and the search API (REST and GraphQL are separate rate-limit buckets — see `gh-rate-limit-resilience`).

```bash
# REST search
gh api "/search/issues?q=<keyword>+repo:OWNER/REPO" | jq '.items[] | {number, state, title}'

# List repo labels so you pick real ones
gh api "/repos/OWNER/REPO/labels?per_page=100" | jq -r '.[] | "\(.name)\t\(.description // "")"'
```

If a duplicate exists, link to the existing issue in your reply instead of creating a new one.

### Step 3 — Rate difficulty

Use this scale in every issue body and in the reply summary. Keeping a single, short scale makes triage portable across sessions.

| Size | Symbol | Rough estimate | Typical scope |
|---|---|---|---|
| **S** | Small | ≤ 1 day | Single file, prompt variable, UI label, small table |
| **M** | Medium | 3–5 days | One subsystem, resolver change, prompt + audit schema |
| **L** | Large | 1–2 weeks | Multi-surface, regression pass, new content tables |
| **XL** | Extra-large | 2+ weeks | New engine / editor / framework with token budget + conflict resolution |

For ambiguous scope, **prefer the larger estimate** — under-promise, never over-promise.

### Step 4 — Pick labels per issue

Use **existing repo labels** (queried in Step 2). Common trios:

- Feature: `enhancement`, `feature`, `game-design` (or whatever domain matches)
- Bug: `bug`, `repro needed`, `game-design` (if game-mechanics-related)
- Investigation: `investigation`, `repro`

Recommend `good first issue` for S-sized features that are non-controversial and high-leverage — it draws new contributors.

### Step 5 — File in one batch

Build the JSON payloads as files on disk, then loop `gh api` to create them. **Do not** use `gh issue create --field` for batches — escaping multi-line bodies becomes unreadable.

```python
# Preferred pattern — write the payload to a file, post via --input
import json, subprocess
for i, issue in enumerate(issues, 1):
    payload_path = f"/tmp/issue_payload_{i}.json"
    with open(payload_path, "w") as f:
        json.dump({"title": issue["title"], "body": issue["body"], "labels": issue["labels"]}, f)
    result = subprocess.run(
        ["gh", "api", "-H", "Accept: application/vnd.github+json",
         "-X", "POST", "/repos/OWNER/REPO/issues", "--input", payload_path],
        capture_output=True, text=True,
    )
    # capture issue number + html_url from the response
```

For **public** repos that may carry credentials in the body, use `~/.smartclaw/scripts/gh-safe-publish` (see `outbound-secret-publication-gate` in SOUL). For private repos with clean text bodies, `gh api` is fine.

### Step 6 — Reply with a coverage table

Post the **issue number + URL + difficulty** for every filed issue, in a single table. Operator should never have to click through to find what was filed. Per the pr-hyperlink rule, every `#NNNN` in the reply must be a full markdown URL.

## Issue body templates

The body is the durable artifact. Use a consistent shape so future readers can scan the backlog.

### Feature request
```
## Source
<who said it, when, where — file/line or message ts>

## Feature Description
<one-paragraph summary of the request>

## Motivation
<why it matters; what pain it solves>

## Proposed Solution
<concrete sketch, with code/YAML where it helps>

## Alternatives Considered
<1–2 alternatives and why they were rejected>

## Difficulty Rating
S/M/L/XL — <one-line rationale>

## Labels
<comma-separated list>
```

### Bug
```
## Source
<who reported it, when, where>

## Bug Description
<one-paragraph summary>

## Expected Behavior
<what should happen>

## Actual Behavior
<what actually happens>

## Investigation Steps
<numbered repro>

## Proposed Fix
<sketch>

## Difficulty Rating
S/M/L/XL — <one-line rationale>

## Labels
<comma-separated list>
```

## Pitfalls

- **Don't file a single mega-issue.** If a paragraph contains N distinct requests, split them. Operators triage better with 6 small issues than 1 large one.
- **Don't skip the dedup search.** Existing issues may already cover the topic. Link to them instead.
- **Don't invent labels.** Always query the repo's existing labels first and pick from the catalog. New labels require repo-owner approval.
- **Don't bury the difficulty rating.** Put it in the body AND in the reply table. New triage sessions will rely on it.
- **Don't use `gh issue create --field body` for multi-paragraph bodies.** Use the `--input <file>` file pattern instead.
- **Don't conflate "player feedback" with "bug report".** A player asking for a new feature is `enhancement`; a player reporting something broken is `bug`. Mislabeling breaks filters.
- **Don't post completion without a numbers table.** Operator needs to verify each issue URL without leaving the chat.

## Verification

After filing, confirm:

1. **All `gh api` calls returned 201 Created** — check each stdout for `html_url` and `number`.
2. **Labels applied** — fetch one issue and confirm `labels[]` contains what you set. Mislabeling silently breaks filters.
3. **Bodies rendered** — open one issue in the browser (or `gh issue view <n>`) and confirm code blocks, headers, and bullets preserved.
4. **Reply shows the full coverage table** — every issue number, URL, title (truncated), and difficulty.

## Cross-references

- `github-issues` — single-issue creation, labeling, closing, bulk ops
- `github-auth` — `gh auth status` setup and token bucket rotation
- `gh-rate-limit-resilience` — REST vs GraphQL bucket failover
- `outbound-secret-publication-gate` (SOUL) — when to use `gh-safe-publish` over plain `gh`
- `pr-hyperlink` rule — every `#NNNN` in the reply must be a full markdown URL
- `references/all-users-download-recipe.md` — inline download script + parallel-scan pattern for cross-user validation

## Cross-user validation pattern (added 2026-08-17)

When a single user's feedback might be "personal preference" vs "system-wide bug", don't file N issues blind. Validate generality first:

1. **Identify the dimensions in the feedback** (e.g. readability, onboarding quiz, loop patterns, friction, win condition).
2. **Score other real users** on the same dimensions by downloading + reading their campaigns. See `download-campaign/SKILL.md` § "Quick all-users download" for the working pattern (~3 min for 37 campaigns).
3. **Dispatch parallel subagents** (3 max concurrent per `delegation.max_concurrent_children=3`) to score each subset. Batch into the `tasks[]` array form if >3.
4. **Aggregate**: produce a distribution table like `5/6 onboarding=0, 1/6=1, 0/6=2` — anything where the "broken" bucket has >30% of the population is system-wide; <10% is user-specific.
5. **Adjust priorities** based on the distribution. A user-specific complaint with 1/8 hits is P3 even if it's emotionally loud; a 5/6 hit is P1 even if the user said it casually.
6. **Cite the distribution in every filed issue body** — operators reading the backlog need to know "this affects 38% of campaigns" not "one user said this".

Concrete worked example: kevin feedback 2026-08-17 — 6 distinct complaints from one Discord screenshot. After scanning 26 real-user campaigns:
- onboarding quiz: 24/26=1, 0/26=2 → **P1** (system-wide)
- friction: 5/26=0 → **P2** (24% — meaningful subset)
- loops: 10/26=mild-or-worse → **P2** (38%)
- readability: 10/26=wall-of-text → **P3** (38%, but cosmetic)
- CC wizard 11-turn trap: 13/26=StandardDND → **P1** (50% hit it, max 73 turns)

The cross-user step changes the priority order substantially. Without it, all 6 would have been P2 "user said it"; with it, the quiz and CC trap bubble to P1.
