---
name: feedback-to-design-issues
description: "File design issues from flexible-engine feedback."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [GitHub, Issues, Feedback, Design, Generalization]
    related_skills: [github-issues, gh-rate-limit-resilience, harness-postmortem]
---

# Translating Feedback into General-Flexibility Design Issues

When player, customer, or user feedback arrives asking for the engine to be
"more flexible" or explicitly rejects hardcoded systems, the right GitHub
issues are **investigation-shaped**: they enumerate axes of variation and
forbid implementation beads that ship presets. The wrong shape is
**feature-shaped**: a named attribute list, a specific genre's rules, or
the player's example system baked in as default.

This skill is the discipline needed to file the right shape, audit your own
output, and iterate until clean.

## When to Use

- Filing GitHub issues derived from a Slack thread, email, or community post
- The feedback contains phrases like "don't hardcode", "explore in general",
  "any similar system possible", "engine should be neutral", "player-declarable"
- The original request was to "file gh issues for [the feedback]" and rate
  difficulty of each suggestion
- User repeated the same correction a second time — indicates a gap in the
  first pass that needs to be closed for future sessions

## When NOT to Use

- The feedback is a clean bug report or feature spec — file as a single
  standard GitHub issue using the regular `github-issues` skill
- The feedback is about dispatching work, not about issue creation —
  use `agento` or `kanban-orchestrator`

## Workflow

### Step 1 — Detect the framing

Read the feedback once end-to-end before filing anything. Look for these signals:

| Signal in feedback | Right issue shape |
|---|---|
| "I don't wanna hardcode ..." | Investigation beads, axes only |
| "just explore in general" | Investigation beads |
| "any similar system possible" | Investigation beads |
| "engine should be neutral" | Investigation beads |
| "player-declarable" / "author their own" | Investigation beads |
| (none of the above) | Standard feature beads |

If the feedback mixes both, treat the general-flexibility framing as the
dominant one and file all of it as investigation beads. Better to over-fence
than to under-fence.

### Step 2 — File investigation-shaped beads

For each axis the feedback implies, file a separate issue. The shape:

```
Title:
  [design / investigation] <axis-name> flexibility: survey shapes + axes of variation (general, no preset, no example)

Sections:
  ## Goal
  Explore: **how can the engine's <axis> layer be flexible enough to express
  any <axis-shape> a player imagines — without the engine ever assuming one
  canonical shape?**

  ## Investigation plan
  1. Audit — find hardcoded assumptions in <files>
  2. Survey — index 8-12 well-known systems; document each one's shape
     on these axes: <list the actual axes>
  3. Classify axes — minimum engine surface per axis
  4. Recommend — short memo, no specific system named as default

  ## Acceptance Criteria
  - [ ] Memo at roadmap/investigations/<axis>-flexibility/memo.md
  - [ ] Enumerates axes of variation
  - [ ] For each axis: surveyed systems that vary on it + minimum exposure
  - [ ] No specific <attribute-name>, <system>, <band-table> named as default
  - [ ] (Optional follow-up) Implementation beads framed as
        "expose axis X so player can author Y" — never "ship preset Z"

  ## Source
  Paraphrase the user's ask. Cite the Slack thread fingerprint.
  DO NOT quote specific system names verbatim — even when attributing
  the source. The original wording lives in the thread, not the issue body.
```

**Single-issue umbrella:** if the feedback implies 4-5 related axes (e.g.
attributes, initiation, resolution, story-cards), file each as its own
bead *plus* one umbrella bead that links them. The umbrella cross-references
in-flight fixes (open bugs + open PRs) so the bug cluster isn't orphaned.

### Step 3 — Audit each issue for prescriptive leaks

Run the audit pass on every filed body before posting summary.

```python
import re

FORBIDDEN = [
    (r"\bReiatsu\b|\bReistsu\b", "specific attribute name"),
    (r"\bBleach\b|\bCyberpunk\b|\bNaruto\b|\bOne Piece\b|"
     r"\bHunter x Hunter\b", "specific anime/system"),
    (r"\bStar Wars\b|\bEdge of the Empire\b|\bEotE\b", "specific system"),
    (r"\bBurning Wheel\b|\bL5R\b|\bPathfinder\b|\bWorld of Darkness\b|"
     r"\bFATE\b|\bIronsworn\b|\bBelonging\b|\bPolaris\b|\bTraveller\b|"
     r"\bEclipse Phase\b", "specific TTRPG system"),
    (r"\bD&D\b|\bsix-attribute\b|\b6-attribute\b", "D&D / six-attribute default"),
    (r"STR/DEX/CON/INT/WIS/CHA", "specific attribute list"),
    (r"\b1-3\b.*\b4-5\b.*\b6-9\b|\b10-14\b|\b15\+\b", "5-tier band table"),
    (r"\bdefault_engagement\b|\baggressive\b\s+first\b", "prescriptive NPC behavior"),
    (r"\bship preset\b", "language promoting 'ship a preset'"),
]

META_CARRYOVER = re.compile(
    r"never\s+['\"]ship preset"
    r"|would be prescriptive"
    r"|rejects hardcoding"
    r"|explicitly rejected"
    r"|Verbatim quote available"
    r"|intentionally does not reproduce"
    r"|player wants the engine to be flexible"
    r"|is an investigation, not a feature spec",
    re.IGNORECASE,
)

def is_real_hit(line):
    return META_CARRYOVER.search(line) is None

def audit(body):
    hits = []
    for ln_no, line in enumerate(body.split("\n"), 1):
        if not is_real_hit(line):
            continue
        for pat, label in FORBIDDEN:
            if re.search(pat, line, re.IGNORECASE):
                hits.append((label, ln_no, line[:200]))
                break
    return hits
```

Run this on each filed body. Note hits per issue. Rewrite bodies that
have real hits. Re-run until CLEAN.

### Step 4 — Source-citation hygiene

The Source section is the leakiest spot in the body, because it's natural
to quote the user's words. Don't.

| Wrong | Right |
|---|---|
| `Player said: "I don't wanna hardcode something like Reiatsu ..."` | `Player feedback (date) via Slack thread <fingerprint>. The ask, distilled: <paraphrase>` |

The paraphrase captures the *axis* the user was getting at, not the
specific instance they used as an example. The verbatim quote lives in
the Slack thread itself; the issue body references it by fingerprint only.

### Step 5 — Summary back to the originating thread

Post the final summary to the same Slack thread / email / channel where
the feedback arrived:

1. List of issue numbers filed, with one-line summaries
2. List of issue numbers closed (with `not_planned`) and why
3. List of issue numbers rewritten and to what
4. Audit verdict (all CLEAN, or which still have open hits)
5. If any axes weren't covered, note the gap and ask whether to file
   more — **do not** multi-option the user, ask one concrete question

## Pitfalls

- **The audit's META_CARRYOVER must keep growing.** Real systems beyond
  D&D / TTRPG will hit the same audit. Add ignore-patterns liberally;
  under-fencing false-positives wastes time; over-fencing misses real
  leaks.

- **"Player wants X" without naming X is incoherent.** When paraphrasing,
  describe the *axis* (e.g. "any attribute-resolution shape") not the
  specific attribute (e.g. "Reiatsu"). The paraphrased Source block must
  still tell a future reader what the feedback asked for.

- **The umbrella-bug-cluster link matters.** When investigation beads
  replace feature beads, the related in-flight fixes (open issues + PRs
  in the same area) must still be cross-referenced in the umbrella bead
  body. Don't strip those refs during rewrite — they keep the work from
  becoming orphaned when the investigation emerges into implementation.

- **Don't fabricate user-quote audits.** The audit regex flags what it
  flags. If a line matches a forbidden pattern but is on the same line
  as a META_CARRYOVER phrase, that's a guardrail, not a violation. Always
  read the offending line in full before rewriting.

- **Investigation beads are not a license to ship anything.** Title prefix
  `[design / investigation]` means *no implementation yet* — the memo
  emerges into 1-2 implementation beads framed per Step 2 acceptance
  criteria, never into a `git push` from the investigation alone.

- **Iterate, don't preach.** If the first audit still finds hits, rewrite
  the body and re-run. Don't argue with the audit or rationalize "this
  one is fine because" — the audit is the gate, not opinion.

## Verification

After every feedback round, run the audit on every filed body:

```bash
# Replace with your repo + issue numbers
for n in 8905 8906 8908 8909 8910; do
  gh api "repos/OWNER/REPO/issues/$n" | jq -r '.body' \
    | python3 -c "
import sys, re
body = sys.stdin.read()
hits = []
for pat, label in [(r'\\bReiatsu\\b','attr'), (r'\\bBleach\\b','sys'),
                   (r'\\bD&D\\b','dnd'), (r'\\b1-3\\b.*\\b4-5\\b','bands')]:
    for m in re.finditer(pat, body, re.I):
        hits.append((label, m.group()))
print(f'#$n: {len(hits)} hits', hits[:5])
"
done
```

If any issue returns nonzero hits and no META_CARRYOVER carve-out, rewrite
that issue before posting the summary.

## Related

- `github-issues` — base CRUD primitives (this skill assumes them loaded)
- `gh-rate-limit-resilience` — REST fallback when GraphQL bucket exhausted
  (which happens reliably during high-volume issue creation)
- `harness-postmortem` — when the user repeats a correction twice, run
  postmortem to confirm whether it's an instance-level lapse or a
  harness gap. If the latter, this skill is the harness fix.
