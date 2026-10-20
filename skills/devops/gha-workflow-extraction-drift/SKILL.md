---
name: gha-workflow-extraction-drift
description: "Fix blank GHA report sections from sed drift."
globs: [".github/workflows/**/*.yml"]
---

# GHA Workflow Extraction Drift

When a GitHub Actions workflow has two steps — one that **produces** a structured text report (writes `/tmp/report.txt` or prints to stdout) and one that **extracts** sections from that text via `sed` / `awk` / `grep` and pipes them into a downstream artifact (email body, Slack message, S3 object) — the two steps can drift out of sync. The symptom is always the same: live report has the data, downstream artifact is blank.

## When to Use

Load this skill when:
- A user reports a GHA-scheduled report (daily/weekly digest email, Slack notification, S3 artifact) has **blank or truncated sections**.
- The producer step's live stdout (`gh run view <id> --log`) shows full content but the downstream step shows blanks.
- A recent PR renamed, reordered, or restyled a section header in the producer script.

Skip this skill for:
- Producer script bugs where the live data is genuinely missing (use producer-side debug).
- Workflow file syntax errors (run `actionlint` instead).

## Trigger pattern

- Email/Slack body shows a section header (e.g. `👥 Top 10 Users (Last Week):`) followed by **blank lines**.
- Live log of the producer step shows full content under the same header.
- A recent PR changed the producer's label, count, or section ordering.

Real case (worldarchitect.ai, 2026-08-22): PR #9248 renamed `Top 10 Users` → `Top 20 Users` in `format_report()`. The producer step (live stdout) was correct. But `.github/workflows/daily-campaign-report.yml` lines 89–90 still had `sed -n '/Top 10 Users (Last Week):/,/.../p'` — the sed matched zero rows, so the email body showed blank Top Users sections while the attached `/tmp/report.txt` had all the data.

## Diagnostic recipe (60 seconds)

1. **Compare producer vs extractor step logs.** `gh run view <id> --log | grep "<Step Name>" | grep -E "<header>"` for both steps. If the producer has lines and the extractor doesn't, the extractor pattern is the bug.

2. **Look for label rename / count change in the producer's git history.** `git log --oneline -G "<old-label>" -- <producer-script>`. If a recent commit renamed the label or expanded the count, the extractor sed pattern is the casualty.

3. **Grep the workflow file for the producer's section header.** `rg -n "<old-label>" .github/workflows/`. Each hit is a sed/awk pattern that needs updating.

## Fix shape

Update the workflow's sed/awk pattern to match the new label. Two-line edit in YAML is typical. **Test by re-running the workflow** (`gh workflow run <name>` or push an empty commit) — do not assume CI is green means fixed; the bug only manifests at the email/Slack-render step.

## Pitfalls

- **Don't blame the producer.** The producer's stdout IS correct (verified by the live step log). Refactoring the producer to "match" the extractor inverts the dependency.
- **Don't add a fallback / sanitization / second regex.** The clean fix is one sed pattern update. Adding alternation (`Top [0-9]+ Users`) just papers over the drift signal — when the next rename lands, the bug returns silently.
- **The email body and the live step stdout are TWO separate streams.** `gh run view --log` shows both side-by-side; don't merge them when grepping. Filter by step name.
- **The drift is invisible until the next scheduled run.** PR #9248 landed and the next scheduled run 24h later exposed it. There's no CI signal that fires between PR merge and next workflow run.
- **Check ALL extraction patterns, not just the failing one.** A label rename typically affects every section header in the workflow file. Grep the file for the old label before shipping the fix.

## Preventive measure (for the producer side)

When renaming a section header in the producer script, **grep the repo for the old label first**:
```
rg -n "Top 10 Users" .github/workflows/ scripts/
```
Same pattern as SOUL.md `## COMMIT: grep-before-constant-change`. Header strings are constants; constant-change rules apply.

## Cross-references

- Related: SOUL.md `## COMMIT: grep-before-constant-change` (header strings count as constants)
- Reference: `references/real-case-2026-08-22.md` (the worldarchitect.ai incident, with full diff)
