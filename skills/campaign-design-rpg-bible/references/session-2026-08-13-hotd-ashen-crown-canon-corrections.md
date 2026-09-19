---
name: HotD Ashen Crown canon-corrections (2026-08-13)
description: |
  Three canon errors Gemini's AI-generated source introduced into the
  HotD Ashen Crown bible that the user caught on live `/repro` test against
  the live worldarchitect.ai wizard. Each error is documented with the
  source line (from /tmp/gemini_full_Y43R4B0daClj.txt), the bible error
  it propagated into, and the corrected line. Use this file as a
  worked example when verifying any AI-source-mediated campaign bible.
provenance:
  session: Slack C0AUXSVFSA2 thread 1786685852.433199 (2026-08-13)
  user_message: "/repro <mvp-site-app-dev-...> — WHy does it say Jace is dead.
    Its been awhile since he died and corlys is not his father. Why addam
    a traitor? In the TV show they didnt do this"
  detection: live `/repro` against the wizard
  bible_then: 50,786 bytes / ~8,500 words
  bible_now: 52,549 bytes / ~8,650 words (after 4 corrections)
---

# HotD Ashen Crown — Canon corrections from 2026-08-13 live playtest

When the user pasted the wizard URL and ran `/repro` against the live
worldarchitect.ai instance, the AI Dungeon Master narrated three
canon errors that originated in the Gemini 3.6 Flash share-source and
propagated into the bible. This file documents each error with its
source, propagation, and fix. Future AI-source-mediated campaign bibles
should run this same canon-verification workflow before publishing.

## Error 1: Jace's death timing

### Source (Gemini v3, line 906 of /tmp/gemini_full_Y43R4B0daClj.txt)

> This campaign starts in the immediate aftermath of the Season 3
> Finale. Jacaerys Velaryon is dead beneath the waves of the Gullet.

### Problem

Gemini undated Jace's death to "Jace is dead" with a fresh-grief tone
throughout. In S3 he died in **S3 E1 "Salt and Sea, Fire and Blood"**
(June 21, 2026) at the Battle of the Gullet, ~60 days before the S3
finale (August 9, 2026). The bible inherited the fresh-grief framing.

### Bible error (before fix)

> **Show anchor:** You begin at the immediate aftermath of House of
> the Dragon Season 3, Episode 8 ... Jace is dead. Ulf and Hugh
> have turned. Helaena has jumped.

And in §5:

> Prince Jacaerys Velaryon (son) — DECEASED. Killed by Triarchy
> bowmen at the Gullet. His body was returned by Baela. You wept
> for three days. His death is the inflection point of your descent.

### Fix

Jace has been dead for **~60 days** (S3 E1). Grief is not fresh; it is
the wound that broke Rhaenyra before Tumbleton finished breaking the
realm. The bible §5 now reads:

> Prince Jacaerys Velaryon (son) — DECEASED at the Battle of the
> Gullet, ~60 days ago (S3 E1). Killed by Triarchy bowmen. His body
> was returned by Baela. You have not stopped grieving.

## Error 2: Corlys–Jace relationship

### Source (Gemini v3, line 1198 of /tmp/gemini_full_Y43R4B0daClj.txt)

> Lord Corlys Velaryon: "My son Jacaerys is food for the crabs.
> Addam of Hull is branded a traitor by your paranoia and has fled
> into the night. Baela sits in your dungeon, locked away like a
> common thief! Now Tumbleton is burned by the gutter-rats you gave
> dragons to! Give me my granddaughter, Rhaenyra, and legitimize Alyn
> as Lord of Driftmark, or I swear by the Drowned God, every
> Velaryon warship leaves the bay before midnight. Let the Greens
> have you."

### Problem

Jace was the son of Rhaenyra + Laenor Velaryon. Laenor's father was
Corlys, making **Corlys Jace's grandfather** — not his father. Corlys
has legal/legitimacy grief over Jace (Jace was the heir to Driftmark)
but cannot claim him as "my son."

### Bible error (before fix)

Same Gemini line, verbatim, in §9 Starting Scene.

### Fix

§9 quote reworded to:

> Lord Corlys Velaryon: "My grandson Jacaerys is food for the
> crabs. ...

## Error 3: Addam of Hull as traitor

### Source (same Gemini line 1198, same as Error 2)

> "Addam of Hull is branded a traitor by your paranoia ..."

### Problem

In canon (S3 E3 "Rhaenyra Triumphant"), Addam was legitimized as a
Velaryon and **stayed loyal to the Blacks throughout Season 3**. The
"branded a traitor" framing is a Gemini invention. The bible's NPC
matrix correctly had him at +60 loyalty with status "Fled to prove
loyalty," but the Starting Scene quote contradicted that.

### Bible error (before fix)

Same Gemini line, verbatim, in §9 Starting Scene.

### Fix

§9 quote reworded to:

> "... Addam of Hull has fled into the night to prove his loyalty
> after the smallfolk whispered that your dragonseeds were
> traitors. ..."

And §4 NPC matrix entry updated to:

> Addam of Hull (L8, Paladin / Seasmoke | +60 | Fled to prove
> loyalty; honorable) → corrected to "honorable, legitimized as a
> Velaryon (S3 E3); loyal throughout Season 3. NOT a traitor."

## Bonus fix: Lucerys vs Jace grief

Gemini's source did not distinguish the two deaths' timelines. The
bible §5 now preserves both:

- **Jacaerys** (son) — DECEASED at Gullet (S3 E1, ~60 days ago).
  Killed by Triarchy bowmen. Body returned by Baela. The fresher
  grief; the wound that broke her.
- **Lucerys** (son) — DECEASED (killed by Aemond at Storm's End,
  ~2 years earlier, S1). The original sin; the wound that made the
  war personal.

## What was added to prevent regression

A new **"Show-anchor canon notes (AI DM must honor)"** section in §5
of the long-form source explicitly lists these four corrections so the
AI DM does not regenerate them on a re-roll. The public wiki page also
gets a one-line "Canon-correction" note in the lead paragraph.

## Workflow before publishing any AI-source-mediated campaign bible

For each named character in the AI source, verify against actual canon
(Wikipedia summaries, the show's episode list, or the source novel's
chapters):

1. **Relationships** — parent/grandparent/child/spouse of every named
   character. Cross-check against the show's cast list and the
   novel's character index.
2. **Event timing** — which episode/chapter / in-world year. The AI
   routinely undates events ("Jace is dead") or puts them at the
   wrong finale ("died at the S3 finale" when the death was actually
   in S3 E1, ~60 days earlier).
3. **Faction allegiance** — loyal/rebel/traitor and when it flipped.
   The AI routinely invents betrayals or loyalty flips that never
   happened in canon ("Addam is branded a traitor" when canon shows
   him loyal).
4. **Deaths and survivors** — who died when, who is still alive. The
   AI frequently collapses multiple deaths into one grief event.
5. **Marriage, legitimacy, and succession status** — who is married
   to whom, who is legitimized, who is heir.

Add a "Canon-correction notes" section to the LLM-wiki source so the
AI DM does not regenerate the errors on a re-roll.

## What the user does

The user runs `/repro` against the live wizard as their canon-check.
If they find anything wrong, fix in one push. Do not argue; do not
produce a long explanation of why the AI source seemed plausible; do
not produce more AI text without first verifying against the actual
show / novel / canon source. The user values canon accuracy above
narrative polish.

## Cross-references

- `~/.smartclaw/skills/campaign-design-rpg-bible/SKILL.md` User Preferences
  #12 (the rule this reference file documents)
- `~/.smartclaw/skills/campaign-design-rpg-bible/references/session-2026-08-13-hotd-ashen-crown.md`
  (the full session reference: bible design + cron pattern + verification matrix)
- `/tmp/gemini_full_Y43R4B0daClj.txt` (the 89KB Gemini source capture)
- `~/llm_wiki/wiki/sources/house-of-the-dragon-ashen-crown.md` (the bible
  after corrections; commit `7081b6562` on jleechanorg/llm-wiki main)
- `https://github.com/jleechanorg/worldai_wiki/pull/9` (the public wiki
  PR with the corrected page, head SHA `f8ba368`)