# 3-Place Sync from a Canonical Google Doc

## When this workflow applies

The user edits a Google Doc by hand (removes a section, rewrites canon, customizes
content) and says something like:

- "see how I did it in the google doc and update the other two places"
- "the google doc is the source of truth, propagate to the wiki + LLM wiki"
- "I edited the doc, sync everything else"

For **House of the Dragon Ashen Crown (Rhaenyra)** specifically, the canonical
artifact lives in 3-4 places:

1. **Google Doc** — `gog docs cat <doc_id> --plain` — user's manual edits, always canonical
2. **Public wiki** — `~/projects/<org>/<wiki>/queries/<name>.md` — under a PR branch
3. **LLM wiki long-form source** — `~/llm_wiki/wiki/sources/<name>.md` (and TV/book subfolders)
4. **AI DM sim template** — `/tmp/<slug>_sim_<v>.py` (the in-process claudem harness)

The agent's own auto-generated copy is **NEVER canonical**. The user's manual Google
Doc edits always win. This is locked 2026-08-19.

## The 5-step workflow

### Step 1: Fetch the Google Doc as the source of truth

```bash
gog docs cat "<docId>" --plain > /tmp/<slug>_gdoc_current.md
wc -wc /tmp/<slug>_gdoc_current.md
grep -E "^SECTION|^## " /tmp/<slug>_gdoc_current.md  # see what sections exist
```

Inspect the diff between the doc and your last-known local copy. Look for:

- Sections the user **removed** (e.g. deleted Section 8 = "Starting Scene")
- Sections the user **renamed** (e.g. "Section 7" → "Dragons, Combat & XP")
- Content the user **rewrote** (e.g. L6 features reformatted as bullets, not paragraph)
- New **SETUP NOTES** or **v3 HARDNESS** blocks the user added at the end

### Step 2: Identify all the places that need updating

For each place, locate the file path and current state. The 3 places for Ashen Crown:

| Place | Path |
|---|---|
| Google Doc | `1vpTfAgIP9mf04MJ9X8t-Wjv5-MW3eVBGtxPyuMSebKg` (already canonical, no edit needed) |
| Public wiki | `~/projects/worldai_wiki/queries/house-of-the-dragon-ashen-crown-rhaenyra.md` (PR #9 branch) |
| LLM wiki | `~/llm_wiki/wiki/sources/house-of-the-dragon-ashen-crown.md` |
| AI DM sim | `/tmp/hotd_sim_v3_L6_noSS.py` (regenerate with the new bible) |

### Step 3: Propagate verbatim to each place

For the **public wiki**, the bible is embedded inside a ` ```text ` fence in the page
body. Use a Python `re.sub` to swap the fence content:

```python
import re
from pathlib import Path

# Read Google Doc (the canonical content)
bible = Path("/tmp/hotd_gdoc_current.md").read_text()
# Strip the leading H1 title (the wiki page has its own H1)
bible = re.sub(r"^House of the Dragon.*?\n", "", bible, count=1)

# Read the wiki page and swap the ```text ... ``` fence
page = Path("/tmp/hotd_wiki_full.md").read_text()
new_page = re.sub(
    r"```text\n.*?```",
    "```text\n" + bible + "\n```",
    page,
    count=1,
    flags=re.DOTALL,
)
Path("/tmp/hotd_wiki_full.md").write_text(new_page)
```

Then update the wiki page's surrounding framing (Quick Setup, "What to expect",
Troubleshooting) to note the changes the user made. The framing prose is your
explanation of the bible's current shape — keep it in sync with the bible.

For the **LLM wiki long-form source**, the bible is the body of the file (after
frontmatter). Use regex to locate the start of the bible and replace the body.

For the **AI DM sim**, the bible is read inline in the sim prompt. Just `cp` the
canonical content over the existing sim's bible reference.

### Step 4: Verify all 3 places match

```bash
# All three should have the same section headers
grep -E "^SECTION " /tmp/hotd_gdoc_current.md | sort -u
grep -E "^SECTION " queries/house-of-the-dragon-ashen-crown-rhaenyra.md | sort -u
grep -E "^SECTION " ~/llm_wiki/wiki/sources/house-of-the-dragon-ashen-crown.md | sort -u

# All three should have the same word count ±50 words
gog docs cat <docId> --plain | wc -wc
wc -wc queries/house-of-the-dragon-ashen-crown-rhaenyra.md
wc -wc ~/llm_wiki/wiki/sources/house-of-the-dragon-ashen-crown.md

# All three should have ZERO references to removed sections
# (e.g. after removing Section 8, none should reference "OPTION 1.*Dragon's Roar")
grep -cE "OPTION 1.*Dragon's Roar" /tmp/hotd_gdoc_current.md
grep -cE "OPTION 1.*Dragon's Roar" queries/house-of-the-dragon-ashen-crown-rhaenyra.md
grep -cE "OPTION 1.*Dragon's Roar" ~/llm_wiki/wiki/sources/house-of-the-dragon-ashen-crown.md
```

### Step 5: Re-run the AI DM sim to confirm propagation works

The sim is the most important verification — it confirms the bible is still
usable by the AI DM after the propagation. If the sim produces canon errors or
content the user removed, your propagation was wrong somewhere.

```python
# /tmp/hotd_sim_<v>_<changes>.py — read the canonical bible, prompt the AI DM
# via claudem, run a regex detector for canon/level/structural checks
python3 /tmp/hotd_sim_<v>_<changes>.py
```

The detector must include:

- **Canon checks** — character relationships (parent/grandparent), event timing,
  alive/dead status, loyal/traitor framing
- **Level checks** — class level, HP, spell DC, dragon stats
- **Structural checks** — sections present, no pre-baked carousel if user removed
  starting scene, freeform prompt at the end
- **Word/char count** — within 16k wizard cap (original-world) or 3k word cap
  (IP-anchored)

## What NEVER happens in this workflow

- ❌ Promoting the agent's auto-generated copy to canonical (the user's doc wins)
- ❌ Carrying forward removed sections "in case the user changes their mind"
- ❌ Synthesizing a "best of both" version that ignores the user's manual edits
- ❌ Asking "do you want me to also sync X?" — the user already said "the other two
  places" — just do it

## Verified working example

**2026-08-19, Ashen Crown v3 no-starting-scene sync.** User manually deleted Section 8
(Starting Scene) from the Google Doc and asked: *"remove the starting scene from the
campaign, see how i did it in the google doc and update the other two places"*.

The propagation:

- Google Doc (`1vpTfAgIP9mf04MJ9X8t-Wjv5-MW3eVBGtxPyuMSebKg`): 2,103 words / 13,158 chars, sections 1-7 + 9 (no 8)
- Public wiki (PR #9 commit `1ad5858`): 21,807 chars / 3,461 words / 181 lines, same sections
- LLM wiki (commit `208053770`): 15,389 chars / 2,349 words, same sections
- AI DM sim attempt 1: 1,985 words / 10,933 chars, 0 canon errors, 8 positives, DM ends with "**What does Rhaenyra do?**" (no pre-baked carousel)

All 4 places verified matching within 5 minutes. 0 user follow-up corrections needed.

## Common pitfalls

- **Drift in surrounding framing.** The wiki page's "What to expect on your first
  session" section describes the bible — if you change the bible (e.g. remove
  starting scene) the framing must mention the change, otherwise players will
  be confused why there's no OPTION carousel.
- **Stale sim templates.** If you update the bible but the AI DM sim still uses
  the old bible reference, the sim will produce content the user removed.
  Always re-run the sim after propagation.
- **Frontmatter version marker drift.** The LLM wiki source's `version: "v3 ..."`
  field needs updating to reflect the new state (e.g. add
  `+ NO-STARTING-SCENE`). Future agents loading the wiki rely on the version
  string to understand what's currently canonical.
- **The "fled into the night" trap.** If your OLD auto-generated bible contained
  the v3-invented "fled into the night to prove his loyalty" canon error and
  the user's manual Google Doc also had it (and you didn't realize the user's
  edit removed it), your propagation will be wrong. Always `grep` for known
  errors before and after.
