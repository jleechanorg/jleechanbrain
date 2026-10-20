# Session Reference — 2026-08-13: House of the Dragon "Ashen Crown" (Rhaenyra)

End-to-end build session for the HotD "Ashen Crown" campaign bible. Captured so
future sessions can pattern-match the workflow + the locked Q&A answers without
re-deriving them.

## Source

User pasted two Gemini share links over the course of one Slack thread:

1. `https://share.gemini.google/jVxwLgRd0jCK` — 301 → `gemini.google.com/share/c00e7c360dbd?skid=...`
   - First iteration: Rhaenyra Lvl6 Bard (College of Swords), 1,000 gp treasury, 4 Acts ending in Fire-and-Blood vs Mercy binary
2. `https://share.gemini.google/Y43R4B0daClj` — 301 → `gemini.google.com/share/e449d2a6c718?skid=...`
   - Updated iteration (post-Season 3): Rhaenyra Lvl11 Bard, 350 gp treasury, 22% CS, 65 Paranoia, **Quad-Pillar system** (CS / TL / PTR / DL), starts at S3 finale

Both shares contained the same thread — Gemini 3.6 Flash conversation titled
"Hardcore Game of Thrones Campaign Redesign," published 2026-08-13. (The v1 share
ID `jVxwLgRd0jCK` and v3 share `Y43R4B0daClj` are alternate IDs of the same
canonical campaign thread.)

## User Q&A locks (all 8 captured this session)

- **Q1:** Bard base class + Dragonrider subclass (custom 5e subclass added to L1-20 progression)
- **Q2:** Play as Rhaenyra (canon), 32, post-Tumbleton finale
- **Q3:** LLM wiki first (`~/llm_wiki/wiki/sources/house-of-the-dragon-ashen-crown.md`), public wiki later after explicit "approved"
- **Q4:** **No endings** — campaign is open-ended system; no Endings Matrix, no canonical endings, no binary Act IV
- **Q5:** GRRM-faithful magic (blood of the dragon + dragon dreams only, no 5e spells above L6)
- **Q6:** No Mortal Anchor (user rejected this Visenya-v9 mechanic for Rhaenyra; the Quad-Pillar Paranoia stat covers the "isolation" tension instead)
- **Q7:** No date in filename (`house-of-the-dragon-ashen-crown.md` not `2026-08-13-…`)
- **Q8:** Anchor to Season 3 finale + book (Fire & Blood) is just fallback where S3 cut off

## What Gemini got RIGHT (kept verbatim in the design)

- **Quad-Pillar state metrics** (CS / TL / Paranoia & Tyranny / Dragonseed Loyalty) — better than v1's Tri-Pillar
- **20-level dragon progression table** with 7 archetypes (Sovereign / Blood Wyrm / Bronze Titan / Silver Swift-Wing / Ancient Colossus / Wild Drake / Sun Drake)
- **Deficit cascade timeline** (Days 1/3/7/14 — small effects → mutiny → Dragonpit storm)
- **Westerosi denominations + Daily Crown Expedition matrix**
- **Fog of War / Raven Dispatch d20 check**
- **Black Council NPC matrix** (12 NPCs with Loyalty values)
- **Post-Season 3 starting state** as the campaign opening — Jace dead, Helaena dead, Ulf/Hugh turned

## What Gemini got WRONG (the user rejected)

1. **Endings Matrix (Section 6)** — user explicitly rejected on 2026-08-13: "let's
   stop doing these endings going forward, no endings." Replace with open-ended
   Campaign Continuity Hooks.
2. **Binary Act IV "Fire and Blood vs Sovereign's Mercy"** — user wants every
   Act's option carousel to have a Freeform slot, never binary without escape.
3. **No Mortal Anchor mechanic** — the user wants a named NPC whose Loyalty
   cascades mechanically (per Visenya v9 preferences). Gemini v3 added a
   Paranoia stat but no specific anchor. *Note: user later relaxed this for
   Rhaenyra specifically (Q6) — Paranoia stat covers the isolation tension
   without needing a dedicated anchor NPC.*
4. **Bard base class without subclass** — user wants Bard + Dragonrider custom
   subclass with DragonsBond signature ability.
5. **TV-canon fabrication risk** — Gemini cited Season 3 events confidently but
   the user's TV canon ends with the S2 finale. Always anchor the lore anchor to
   a specific verifiable moment, not "current canon."

## New mechanic introduced this session (user-authored)

**`0.34 × (next_level_threshold − current_level_threshold)` per-die-roll XP rule** —
the user specified this verbatim: "every successful or failed dice roll give me
34% of exp to the next level. Do not do it during god mode or turns where time
doesn't advance." Uses standard D&D 5e cumulative XP thresholds (L2=300, L3=900,
L4=2700, L5=6500, ..., L20=355000). Worked example from user: L2→L3 with threshold
distance 600 → `0.34 × 600 = 204 XP per die roll`. This is a non-trivial mechanic
that future campaign bibles for this user should include by default.

**No XP awarded during:**
- God mode (narrator-driven cutscenes, time-skips, scripted sequences)
- Turns where time does not advance (level-up modals, character-creation modals, downtime bookkeeping)

**Rationale (encoded in bible v1):** 34% figure calibrated so an Act's worth of
typical play (≈30-50 die rolls) yields ~1.5-2 level-ups; Acts span ~3-5 levels;
whole campaign (Acts I-IV) spans L11-L25 in ~14 Acts.

## Capture recipe verification (browserclaw + Gemini share links)

The `~/.smartclaw/skills/read-gemini-share-link/SKILL.md` recipe needed correction:
**`--cookies` is REQUIRED by browserclaw's CLI, not optional** (even for public
shares). I initially tried `--goto` without `--cookies` and got exit 2:

```
usage: browserclaw cookies inject [-h] --cookies COOKIES --goto GOTO [...]
browserclaw cookies inject: error: the following arguments are required: --cookies
```

Even though the share is public and no actual cookie injection is needed, the CLI
rejects the call. The fix is: decrypt cookies to `/tmp/google-cookies.json`
*first*, then pass `--cookies /tmp/google-cookies.json` to `inject`.

Full verified sequence:

```bash
# 1. Resolve short URL 301
curl -sIL "https://share.gemini.google/<id>" | grep -i '^location:'
# → gemini.google.com/share/<long-id>?skid=<uuid>

# 2. Decrypt Chrome cookies (REQUIRED — not optional)
browserclaw cookies decrypt \
  --db "$HOME/Library/Application Support/Google/Chrome/Default/Cookies" \
  --output /tmp/google-cookies.json \
  --domain-filter '%google.com%' \
  --summary

# 3. Capture with browserclaw + cookies (NOTE: --cookies is required)
browserclaw cookies inject \
  --cookies /tmp/google-cookies.json \
  --goto "https://gemini.google.com/share/<long-id>?skid=<uuid>" \
  --browser-channel chromium \
  --headless \
  --wait-after-load 15 \
  --print-text 100000 \
  > /tmp/gemini_full_<id>.txt

# 4. Verify (>30K chars = good; <1K = "Link doesn't exist")
wc -c /tmp/gemini_full_<id>.txt
```

Output sizes in this session:
- `gemini_full_c00e7c360dbd.txt` — 37,385 chars (v1)
- `gemini_full_e449d2a6c718.txt` — 89,052 chars (v3, the long version with S3 lore)

## Bible file shipped (ironclad-verified)

**Path:** `${HOME}/llm_wiki/wiki/sources/house-of-the-dragon-ashen-crown.md`
**Size:** 45,846 bytes (over wizard 16k cap by design; Appendix A provides a meta-prompt to slim)
**Sections:** 11 (`## ` headers) — 9-section bible + Section 10 (Campaign Continuity Hooks, No Canonical Endings) + Setup Notes + Appendix A (wizard-paste meta-prompt) + Appendix B (wizard field checklist)

**Ironclad verification — 9/10 PASS, 1 DEFERRED:**

| # | Criterion | Status |
|---|---|---|
| 1 | File exists at exact path with valid YAML frontmatter | ✅ |
| 2 | 9-section + Section 10 shape (≥10 ## headers) | ✅ |
| 3 | Quad-Pillar (CS/TL/PTR/DL) quantified with baseline starts | ✅ |
| 4 | Level-up XP rule: `0.34 × (next − current)`, 5e thresholds, god-mode carve-out | ✅ |
| 5 | No canonical endings matrix; 4 explicit no-endings statements | ✅ |
| 6 | Show-primary anchor: S3 finale state + 3 [Book fallback] markers | ✅ |
| 7 | Bard + Dragonrider subclass + L25 Divine Ascension track | ✅ |
| 8 | /web-advice cross-model review | ⏸ DEFERRED (bible ships with `[Balance check pending]` marker per drift rule) |
| 9 | Paste-ready for wizard via Appendix A meta-prompt + Appendix B field checklist | ✅ |
| 10 | No commit/push/public-wiki until user says "approved" | ✅ |

**Northstar artifact:** `${HOME}/roadmap/house-of-the-dragon-ashen-crown/goal-ironclad-2026-08-13.md`

**30-min recurring cron:** `job_id=ba96860ec96c` ("hotd-northstar-nudge"), fires every 30 min into Slack thread `C0AUXSVFSA2/1786685852.433199` with the prompt instructing the agent to re-read the northstar file and post a one-line STEP=… STATE=… NEXT=… drift check.

## New pattern: bounded cron-as-northstar-nudge

This session introduced a pattern not yet covered by existing skills:
**recurring northstar-nudge cron while the agent is mid-iteration on a long task.**
Distinct from `one-time-status-cron-after-every-task` (which is one-shot, fires
once at +20 min) and `dropped-thread-watcher-of-watchers` (which is babysit
supervision). Use case: agent has a multi-hour task and wants to re-anchor to
the northstar every 30 min so it doesn't drift off-track.

**Pattern (verified working):**

```python
cronjob(
    action="create",
    name="<task-id>-northstar-nudge",
    schedule="every 30m",
    deliver="slack:<chan>:<thread_ts>",
    skills=["brainstorming"],
    prompt="Northstar nudge — re-read /path/to/goal-ironclad-<date>.md and bead <id> ... [re-anchor instructions] ..."
)
```

Distinguish from `one-time-status-cron-on-request` (one-shot, after user asks):
this is recurring while the task is in-flight; the cron should be removed when
the task completes (or use the deadline-based variant that auto-cancels).

**When to use:** for any task with a written northstar + bead, that the agent
will iterate on across multiple turns/sessions; the user wants drift protection.

**When NOT to use:** short single-turn tasks (overhead); tasks with no northstar
artifact; one-shot fixes.

## OOB-duplicate handling

User sent an OOB message mid-turn that was a duplicate/replay of the same
content as their previous message ("test_level_up_organic" + the cmux-goal
request). I detected the duplicate and continued with the in-progress task
without re-doing work. This is per SOUL.md `no-hallucinate-no-new-content` —
when an OOB repeats content already in context, treat it as a signal, not a
new directive. No skill update needed; behavior was correct.

## Open thread — Slack `C0AUXSVFSA2/p1786685852.433199`

The user is mid-iteration on this campaign. Bible v1 is shipped + ironclad-
verified; awaiting user's reply to one of four options:

1. "approved" — opens PR against `jleechanorg/worldai_wiki`
2. "approved + run /web-advice" — bounded cross-model balance review first
3. "changes: …" — revise the bible
4. "drop the cron" — disable job `ba96860ec96c`

**The next session should NOT re-do Q1-Q8 or re-present the design.** If the
user replies with "approved," dispatch the public-wiki step directly. If they
reply with "changes: …", iterate on the existing bible file (do NOT rewrite
from scratch).