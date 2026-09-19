---
name: personal-finance-status-check
description: "Status of prior personal-finance work blocks."
when_to_use: "Trigger when the user asks for status on a prior life-admin work block (tax, EDD audit, immigration, insurance). The nextsteps artifact in ~/roadmap/ + bd-* beads + ~/budget/ are the canonical sources; slack DM history is the trap. Use when user asks 'what's the status of my tax / EDD / immigration / personal-finance work', 'check latest my tax stuff', 'is the audit done', 'latest on X personal thing', 'which docs are uploaded'."
version: 1
author: hermes-curator
license: MIT
tags: [personal-finance, status, nextsteps, roadmap, tax, audit, beads]
metadata:
  hermes:
    tags: [personal-finance, status, nextsteps, roadmap, tax, audit, beads]
    related_skills: [roadmap, executive-assistant, vendor-webcheck-first, skillify]
---

# Personal-finance status check — 5-source parallel read

## Class
Status composer for prior life-admin work blocks. **Output:** a one-screen status dispatch with 5 section buckets (On disk / Already done / Risky / Blocked / Next actions) sourced from the canonical artifact ladder, NOT from slack DM history.

## The trap (verified 2026-08-16, this skill's origin)

User asked **"Check on latest my tax stuff slack search the status"** in DM. The agent answered from slack DM history only (parent session `20260718_171003_2ba9ddf7` Jul 18 baseline = 14 PDFs in `~/Downloads/tax 2025/`, "no tax follow-up since Jul 18"). User replied **"Use /browser or aside mcp I thought we got more done check #life"** — the user already knew:

- An Aug 1 audit session ran (`20260805_075845_4c2f3ab8` was the retry, but the canonical audit was earlier)
- A `nextsteps-2026-08-01-taxdome-2025-organizer-audit.md` existed in `~/roadmap/`
- 3 P1 beads (`bd-lj7`, `bd-8vx`, `bd-9g2`) were open in `~/roadmap/.beads/`
- 16 PDFs (not 14) lived in `~/budget/Tax_Documents_2025/`
- Drive folder `1fY36n2fSB1YYv9SVV1Z3RgnKXRZx4NMb` had 20 files including duplicates from a cron race

DM history undercounted the state by ~80%.

## The 5-source parallel read (in execution order)

These sources are **independent**. Hit them in one `execute_code` call so you don't bias yourself toward whatever the DM history shows first.

```python
# Sources 1-3 are local; 4 is gog; 5 is slack MCP
import os, subprocess, sqlite3, json

# 1. Nextsteps doc — THE canonical artifact
ns = subprocess.run(
    ["find", os.path.expanduser("~/roadmap"), "-maxdepth", "2",
     "-name", "nextsteps-*-*.md", "-mtime", "-90"],
    capture_output=True, text=True, timeout=10
).stdout.strip().splitlines()
# Find the doc that matches the topic (tax / EDD / immigration / etc.)

# 2. The actual source files (the "what's on disk" answer)
for d in [os.path.expanduser("~/budget"), os.path.expanduser("~/Downloads"),
          os.path.expanduser("~/Documents")]:
    # pick the relevant subdir for the topic
    pass

# 3. Open P1 beads (the work queue)
beads = subprocess.run(
    ["br", "ready", "--priority", "1"],
    capture_output=True, text=True,
    cwd=os.path.expanduser("~/roadmap"), timeout=10
).stdout

# 4. Drive mirror state (only if the work block has a Drive folder)
# gog drive ls --parent=<folder-id> -a jleechan@gmail.com -p

# 5. Slack #life channel (C0AMM2B4319) — last 30-90 days
# mcp__slack__conversations_history(channel_id="C0AMM2B4319", limit="90d")
```

**Why parallel, not serial:** the trap is reading DM history first and forming a hypothesis, then "looking for the nextsteps doc to confirm." Reading the nextsteps doc first flips the bias — it tells you what evidence matters, then DM history confirms recent user activity.

A reusable script lives at `references/5-source-parallel-read.py` — accepts a topic string and prints a unified 5-bucket report. Read-only; does not mutate state.

## Output shape (the dispatch format)

Reply in 5 sections, color-coded Slack-native, no wide tables:

- **🟢 On disk** — bullet list of files with sizes, sourced from #2
- **🟢 Already done** — bullet list of corrections/completions, sourced from #1
- **🟡 Risky / Open P1 beads** — table with bead-id, title, due-date, dependency, sourced from #3
- **🔴 Blocked by** — explicit user-pause / MFA / evidence blocker, quoted from #1
- **🔵 Next-action menu** — 2-3 numbered options, not a multi-way menu

Cite the source numbers (1-5) inline so the user can audit. Always close with `📎 Session: @session:default/<id>` for the most recent related session + `📎 Audit doc: <path>` if a nextsteps doc exists.

## When NOT to use this skill

- **Engineering status** (PRs, CI, agents, cron jobs) — use the `roadmap` skill's 48h slack sweep + `gh pr list` pattern instead. This skill is for life-admin work blocks whose canonical artifact is `nextsteps-*.md`, not slack threads.
- **A fresh task the user just started** — the nextsteps artifact doesn't exist yet. Use the regular todo + `executive-assistant` pattern.
- **An ask that didn't pause via nextsteps** — some life-admin work blocks are quick one-shots (pay a bill, reschedule a flight). No `nextsteps-*.md` will exist. Skip this skill and answer directly from git/file state.

## Pitfalls

- **DM history is the trap, not the source.** (2026-08-16) The DM is the conversation channel, not the artifact store. The nextsteps doc IS the artifact.
- **`/roadmap` 48h sweep is engineering-only.** The `roadmap` SKILL.md works on slack channel history to surface PR/AGENT threads. For personal-finance, the nextsteps doc + `~/budget/` + beads are the analog, not slack.
- **Don't load all 5 sources if the topic is recent.** If the user just asked yesterday and there's a nextsteps doc from this week, sources #4-5 are noise. Read source #1 first.
- **The nextsteps doc's "blocked" section is authoritative.** Quoting it verbatim (not paraphrasing) is the right move — the user wrote it (or co-wrote it) and needs to see the exact blocker language.
- **Beads may have schema-version drift.** (2026-08-16) `br ready --priority=1` returned `Schema version mismatch; run br doctor migrate-schema plan`. The `br` CLI is read-only-safe in this state, but mutations will fail. Capture the schema warning in the dispatch so the user knows the work queue is best-effort.
- **gog drive ls flag is `--parent`, not `--folder-id` or `--folder`.** (2026-08-16) `--help` confirms. Same is true for `gog drive` subcommands that take a folder reference.
- **Don't spam #life from a cron-pinged `taxdome-2025-file-watcher` heartbeat.** If the work block has a cron file watcher that posts cron job responses to #life, those posts are the cron's report, not the user-facing status. Skip them when reading source #5.
- **The user's "check on this" question is usually a defeat-the-trap test.** When the user says "didn't we get more done" / "I thought we had X", that's not a denial — it's a prompt that the answer-from-the-wrong-source happened. Acknowledge the specific gap (e.g., "you were right, more happened — the Aug 1 audit + beads drove most of the progress"), then deliver the corrected state.

## Verified instance — 2026-08-16

- **User ask:** "Check on latest my tax stuff slack search the status" (DM, 2026-08-16 00:06 PT)
- **First reply (wrong):** Based on DM history only. Reported 14 PDFs in `~/Downloads/tax 2025/`, "no tax follow-up since Jul 18."
- **User correction:** "Use /browser or aside mcp I thought we got more done check #life" (DM thread reply)
- **Second reply (corrected):** Parallel-read 5 sources. Found 16 PDFs in `~/budget/Tax_Documents_2025/`, Nextsteps doc `~/roadmap/nextsteps-2026-08-01-taxdome-2025-organizer-audit.md` (96 lines, full audit), 3 P1 beads `bd-lj7/8vx/9g2`, Drive folder `1fY36n2fSB1YYv9SVV1Z3RgnKXRZx4NMb` with 20 files, deadline Oct 15 2026 (extension), 7 vendors still MFA-blocked.
- **Lesson:** The user already knew the answer was richer than my first reply. Reading the canonical artifact (= nextsteps doc) first is mandatory for personal-finance status inquiries.

## Cross-references

- `roadmap` (user-owned, NOT curator-managed) — covers the 48h slack sweep + PR-audit pattern for engineering. Companion, not parent. Patch attempt to add a "Personal-finance status check" subsection was refused 2026-08-16; user can run `hermes curator adopt roadmap` to enable curation.
- `executive-assistant` — for daily morning briefings on calendar + email + action items.
- `vendor-webcheck-first` — when the user names a specific external artifact and the agent suspects it's a typo. Different shape.
- `skillify` — pipeline for turning this lesson into a curator-managed skill once the user runs `hermes curator adopt personal-finance-status-check`.
- `references/5-source-parallel-read.py` — bundled script that walks the 5 sources and prints a 5-bucket report.
