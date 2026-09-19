---
name: feedback-cross-validation
description: "Cross-validate user feedback via other users' data."
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [feedback, cross-validation, worldarchitect, firestore, triage, prioritization, parallel-subagents]
    related_skills: [feedback-to-github-issues, repro, download-campaign, wa-prod-data-query, dogfood]
when_to_use: "Use when: user pastes product feedback AND asks for cross-user validation, generality scoring, or priority assignment grounded in real data. Do NOT use for: bug-repro flows (use `repro`), single-feedback dump triage without cross-validation (use `feedback-to-github-issues`), browser UI dogfooding (use `dogfood`). Triggers: 'review this feedback', 'file gh issues/beads with priority', 'review the other campaigns', 'is this user-specific or system-wide'."
allowed-tools: terminal, file
---

# feedback-cross-validation — single-user feedback → cross-user evidence → prioritized issues

Class-level workflow for turning a single user's product feedback into grounded, prioritized issue/bead filings. The key differentiator from `feedback-to-github-issues`: **cross-validation against live production data** (other users' actual records) BEFORE assigning priority. A complaint is rated P1 only if the pattern repeats across multiple users' data; P2/P3 if it's user-specific or template-specific.

## When to use vs not

| Workflow | Use this skill? | Why |
|---|---|---|
| User pastes feedback, asks "file these with priority grounded in real data" | YES | Cross-validation is the value-add |
| User pastes feedback, asks "just file these" with no cross-validation request | NO | Use `feedback-to-github-issues` |
| User reports a campaign-state bug with live URL | NO | Use `repro` (canonical-state repro workflow) |
| Operator wants to know if user X's complaint is a system-wide pattern | YES | Core class — validate via other users' records |

## The 5-phase workflow

### Phase 1 — Extract discrete items from the feedback

Players usually bundle multiple suggestions into one message. Split before scoring.

**Heuristic — split when ANY of:**
- Different aspect of the product (UX vs content vs engine vs prompt instruction)
- Different actor responsible (frontend vs prompt vs backend vs game-design)
- User explicitly numbers or separates ("1...", "2...", "another thing...")
- Sentiment is materially different ("fun but..." vs "broken and...")

**Output:** numbered list of N items, each with the user's exact quote + your one-line paraphrase.

### Phase 2 — Quick context check on the reporting user

Before cross-validating, anchor the feedback in the user's actual session. Pull 1-2 of their campaigns (largest, or the one matching the feedback topic).

**Anchors to extract:**
- Campaign title(s) + entry counts (filter by `> 20 entries` if available — those are the "invested" users)
- First 3 user actions verbatim (reveals if feedback is reproducible from session data)
- Any system warnings on those entries (`system_warnings` array on each story entry)
- Whether their campaign matches their stated template (spicy / StandardDND / etc.)

**Tools:** direct Firestore reads via in-process Python (NEVER subprocess download_campaign.py — gRPC FD inheritance bug fires). See `download-campaign/SKILL.md` Pitfall #1.

### Phase 3 — Dispatch parallel cross-validation subagents

For each feedback item that warrants validation (typically 3-6 items per session — skip items the user can self-confirm like "this CSS is ugly"), dispatch **parallel subagents** to scan OTHER users' records.

**Subagent prompt must include:**
- Specific pattern to score (NOT "review other campaigns" — name the exact metric)
- Firestore path conventions (use `users/{uid}/campaigns/{cid}/story/` — NOT root `campaigns`)
- Test user exclusion patterns: `test`, `anon`, `dev-runner`, `example.com`, `jleechantest`
- Exclude jleechan uid `vnLp2G3m21PJL6kxcuAqmWSOtm73` unless user explicitly says otherwise
- Output schema (JSON per user + a SUMMARY.json)
- Evidence requirement: quote actual text, not paraphrase

**Critical coordination pattern:** each subagent must write to a UNIQUE filename prefix (`onboarding_<user>.json`, `loops_<user>.json`, etc.). Do NOT share `/tmp/scan_*.json` outputs across subagents — one subagent's `rm -f *.json` will wipe another's results mid-run. Verified 2026-08-17: readability subagent's cleanup deleted loops subagent's files.

**Sample size:** 5-8 users per pattern is usually enough. Below 5, statistical signal is weak. Above 10, diminishing returns (most patterns saturate).

### Phase 4 — Score each feedback's generality

Aggregate subagent results into a verdict per feedback item:

| Verdict | Signal | Priority |
|---|---|---|
| **System-wide** | Pattern appears in ≥70% of scanned users | **P1** (high-impact, broad reach) |
| **Template-specific** | Pattern appears only in 1-2 templates (e.g. spicy/Exotic/StandardDND) | **P2** (fix the template, not the engine) |
| **User-specific** | Pattern only in the reporting user | **P3** or close as not_planned |
| **Saturated** | Pattern appears in ≤30% of users | **P3** (low impact, low priority) |

**Always cite the cross-user evidence in the issue body.** Example:
```
Cross-user validation (6 campaigns, 2026-08-17):
- 5/6 had onboarding_score=0 (no quiz at all)
- 1/6 had onboarding_score=1
- 0/6 had onboarding_score=2 (explicit quiz)
→ System-wide missing feature, P1.
```

### Phase 5 — File issues + beads with priority

For each feedback item, file a **paired** gh issue + bead. Use `feedback-to-github-issues` for the gh-side mechanics (label dedup, rate-limit handling, body template). Use `br create --priority N` for the bead.

**Priority assignment is the value of this skill** — use the verdict from Phase 4 directly:
- System-wide → priority 1 (P1)
- Template-specific → priority 2 (P2)
- User-specific or saturated → priority 3 (P3) or close

**Pair the records:** bead body MUST carry the same canonical evidence + cross-user numbers as the issue body. See `repro` skill §"Single-turn Gate 1 + Gate 2 flow" for the file-then-`-description-file` pattern that keeps them coupled.

**Reply shape:** post a single coverage table with issue number + URL + priority + verdict for every item. Operator should see the full triage without clicking through.

## Anti-patterns (this section IS the skill)

1. **Filing without cross-validation** — if user asks "how important is his feedback in general" and you file 6 issues without reading other users' data, you've done the easy half. The cross-user scan is what makes the priority grounded.
2. **Treating the reporting user's data as gospel** — the user's evidence is necessary but NOT sufficient. A complaint can be user-specific (e.g. he picked the only template without first-action gating) even when 5/6 other users say it's fine. Use cross-validation to demote false-flags.
3. **Skipping the entry-count filter** — always filter to users with `> 20 entries` (or some "invested" threshold). Casual users (1-5 entries) often bounce off any product and don't represent a real signal.
4. **Sharing `/tmp/scan_*.json` outputs across parallel subagents** — verified 2026-08-17 wipe-out incident. Use distinct prefixes per subagent.
5. **Firing subagents at the same user pool** — if 3 subagents all pick the same 5 users, you get 3 noisy estimates of the same signal. Split the user pool across subagents.
6. **Quoting user-reported numbers without re-verifying** — if user references a number (e.g. "11 turns on char creation"), re-derive it from raw data. The screenshot may have meant something different. Verified 2026-08-17: "11 turns" was the CC ability_scores StandardDND path, not total session length.

## WA-specific guards

For WorldArchitect.AI feedback review, these paths and exclusions are mandatory:

- **Story subcollection is `story`**, not `story_entries` (`story_entries` returns 0)
- **Real-user data is at `users/{uid}/campaigns/{cid}/story/`**, not the root `campaigns` collection (root has only test fixtures as of 2026-06-23)
- **Test email patterns to exclude:** `test`, `anon`, `dev-runner`, `example.com`, `jleechantest`
- **jleechan uid:** `vnLp2G3m21PJL6kxcuAqmWSOtm73` (default exclude unless user says otherwise)
- **Project ID for Firestore client:** `worldarchitecture-ai` (with `-ture-`), NOT `worldarchitect-ai`
- **In-process Python only** for Firestore reads — subprocess `download_campaign.py` fails with `ev_poll_posix.cc:593 FD from fork parent still in poll list`

## Worked example (2026-08-17)

User `kevin@kevinphan.com` posted 6 feedback items in Discord. Operator asked for "review the feedback, file gh issues/beads, and think about priority".

**Phase 1 — extracted 6 items:** readability, loops, onboarding quiz, initial friction, no win condition, quiz depth.

**Phase 2 — pulled kevin's biggest campaign** (`uNVwTUuO`, "Harry potter meets the book of enoch and pornhub", 44 entries). Found: user typed "throw an orgy" as 3rd action (validates friction complaint); 2 consecutive "deepen the encounter / go wild" actions (validates loop complaint); user-invented goal at turn 4 "we're gonna take over the world" (validates no-win-condition complaint).

**Phase 3 — dispatched 3 parallel subagents** with distinct filename prefixes (`onboarding_*`, `loops_*`, `readability_*`):
- onboarding subagent scanned 6 users → 5/6 = no quiz, 1/6 = subtle hint
- loops subagent scanned 8 users → 7/8 = no loops, 1/8 = mild (same action 3× — likely dup-submit bug)
- readability subagent scanned 6 users → avg 1,489 chars/p90 2,374/avg 24 lines per response

**Phase 4 — verdicts:**
- Onboarding quiz: **system-wide P1** (5/6 = score 0)
- Friction: **kevin-specific P2** (5/6 other users HAVE friction)
- Win condition: **kevin-specific P2** (5/6 other users HAVE a goal)
- Loops: **mostly kevin-specific P2** (7/8 = none) + a separate dup-submit bug
- Readability: **partial P3** (avg OK, p90 outliers hurt)

**Phase 5 — filed 6 issues + 6 beads** with priorities matching verdicts. Wrote wiki source at `~/llm_wiki/wiki/sources/2026-08-17-kevin-feedback-review.md` consolidating evidence.

## Tests

- `tests/test_feedback_split.py` — heuristic for splitting bundled feedback into discrete items
- `tests/test_priority_assignment.py` — verdict → priority mapping (system-wide→P1, template→P2, user→P3)
- `tests/test_subagent_filename_isolation.py` — verify two subagents using `/tmp/scan_*.json` don't clobber each other (regression for the 2026-08-17 wipe-out)

## Cross-references

- `feedback-to-github-issues` — gh-side mechanics (label dedup, body templates, rate-limit handling)
- `repro` — single-issue hard-gate workflow for campaign-state bugs (paired gh issue + br bead)
- `download-campaign` — Firestore read mechanics, gRPC FD pitfall, clock-skew patch
- `wa-prod-data-query` — real-user Firestore query patterns + test-user exclusion
- `dogfood` — browser-based UI testing (NOT a substitute for cross-user data reads)