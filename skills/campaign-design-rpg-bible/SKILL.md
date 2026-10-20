---
name: campaign-design-rpg-bible
version: 1.7.2
description: "Design paste-ready RPG bibles for WorldArchitect.AI."
author: hermes-agent
license: MIT
metadata:
  hermes:
    tags:
      - rpg
      - worldarchitect
      - campaign-design
      - 5e
      - solo-rpg
    related_skills:
      - brainstorming
      - read-gemini-share-link
triggers:
  - "design a campaign"
  - "campaign template / bible"
  - "campaign for WorldArchitect.AI"
  - "campaign for [IP / character / era]"
  - "look at all my campaigns"
  - "design a hybrid campaign"
  - "best aspects of my bibles"
  - "isekai / reincarnation / grimdark campaign"
  - "rank table for warriors / mages / nobles"
  - "interesting starts / opening scene menu"
  - "no endings / open-ended campaign"
  - "remove mortal anchor"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
context: inline
---

## When to Use

Use this skill when the user asks to:

- **Design a campaign** for any IP / character / era (e.g., "design a campaign for House of the Dragon", "design a Visenya v10 campaign", "design a D&D campaign set in [world]")
- **Make a campaign template** (paste-ready bible for WorldArchitect.AI or similar 5e-based solo-RPG systems)
- **Build a campaign from a Gemini share-link source** (user pastes `share.gemini.google/<id>` containing their draft campaign)
- **Iterate an existing campaign bible** (Bounded path — user asks to "adjust", "modify", "add X mechanic", "swap Y")
- **Convert an LLM-conversation draft into a campaign bible** (the Gemini-shares are usually the user's first-draft generation; this skill captures the second-pass pattern)
- **Sync a campaign bible across multiple places** when the user manually edits the canonical Google Doc and asks to propagate (see `references/3-place-sync-from-google-doc.md`)
- **Synthesize a hybrid from existing bibles** ("look at all my campaigns and design X with the best aspects", "isekai world with grimdark tone + noble ranks + interesting starts") — see *Synthesis-from-Existing-Bibles Workflow* below
- **Design rank tables** ("ranks for warriors / mages / nobles — landed knight, baron, duke, world emperor") — see *Rank Table Pattern* below

Do NOT use this skill for:

- Generic RPG worldbuilding without a target system (use brainstorming)
- One-shot TTRPG sessions (use TTRPG-specific skills)
- Pure creative writing or novel drafting (different domain)

---

## v1.7.0 — Counter-Mechanics + Day-N deadline hook + gog_pageless env-var override (added 2026-08-22)

Three additions from the Demon-Emperor-Reincarnated session's follow-up turn, verified by a user OOB correction ("Consider this too — Typical ways isekai stories keep tension when the protagonist is OP" with the 8-device taxonomy):

- **Counter-Mechanics subsection (§8.5)** — wires Device 5 ("Introduce Counters and Specific Weaknesses") from the isekai tension taxonomy into the bible skeleton. The v1.6.0 Cheat Inventory makes the protagonist OP; this subsection makes the world *answer* the OP. For each of the protagonist's named cheats (Veil/Foresight/Bonus-Action/etc.), the bible MUST name 1-2 world elements that specifically counter it. Verified working set from Demon-Emperor-Reincarnated: **(1) Veilwarden's Sight** (named L18+ witnesses who can see through the Veil — counter to Foresight+Veil), **(2) the Quiet Field** (sealed-domain magic that suppresses Bonus-Action casting in its radius — counter to Bonus-Action Any Spell, used by Academy Headmaster + Imperial Inquisitors), **(3) the Chamberlain's Knife** (named obsidian weapon forged to disrupt magical perception — counter to Permanent Foresight, personal/intimate). The "At low stakes the protagonist is godlike; against prepared enemies, they're merely excellent" line belongs in this subsection so the AI DM uses the compression deliberately. Anti-pattern: do NOT make the counters the same NPC repeated three ways (Veilwarden, Quiet Field, Knife should each be a different *kind* of threat — passive observer, environmental rule, personal weapon).
- **Day-N deadline Continuity Hook (§10 pattern)** — wires Device 8 ("Time Pressure and Irreversible Consequences") from the isekai tension taxonomy. When the bible includes an OP protagonist AND a "background" external event (Demon Court succession, demon lord war, academy tournament, etc.), that event MUST have a fixed calendar deadline expressed as a number of in-world days, AND that deadline must close a window on at least one named NPC. Verified working shape from Demon-Emperor-Reincarnated: a 90-day Demon Court succession summit that pulls the Quiet Brother (child-spy) out of the Academy on **Day 87**, with the summit itself happening on Day 90 regardless of player action. The "Day-87" sub-deadline is what makes this work — it gives the player a specific NPC-loss event they can choose to prevent, intercept, or accept. Generic ("the summit happens eventually") does NOT satisfy Device 8. The bible's AI DM footer must NOT auto-resolve the deadline — the player decides whether to engage.
- **`gog_doc_pageless.py` env-var override** — patch the script's hard-coded `CREDENTIALS_PATH` to honor `$GOG_PAGELESS_CREDS`. Verified 2026-08-22: when the user has multiple gog accounts (e.g., `jleechan@worldarchitect.ai` service account + `jleechan@gmail.com` OAuth) and the runtime script reads `~/Library/Application Support/gogcli/credentials.json` (which is whichever account was last configured), a pageless call against the *other* account's doc fails with `KeyError: 'refresh_token'` (SA JSON has no refresh_token) or `insufficient authentication scopes` (old OAuth token missing the docs scope). Fix: import `os.environ.get("GOG_PAGELESS_CREDS", str(CREDENTIALS_PATH))` and use that path. Recipe with env override:
    ```bash
    GOG_PAGELESS_CREDS=/tmp/jleechan-gmail-creds.json \
      python3 ~/.smartclaw/skills/campaign-design-rpg-bible/scripts/gog_doc_pageless.py "<doc_id>"
    GOG_PAGELESS_CREDS=/tmp/jleechan-gmail-creds.json \
      python3 ~/.smartclaw/skills/campaign-design-rpg-bible/scripts/gog_doc_pageless.py --dry-run "<doc_id>"
    ```
    The credentials file must contain `client_id`, `client_secret`, AND `refresh_token` (compose from keychain `security find-generic-password -s gogcli -a jleechan@gmail.com -w` + the canonical client_id from `credentials.json`). Clean up the file with `shred -u` after the pageless call returns — it contains a live refresh token.

## v1.7.2 — Aside-first WA auth pattern + WA IndexedDB-not-cookies pitfall (added 2026-08-22)

Two corrections from the Isekai Demon Emperor live-test session, both verified 2026-08-22 against the live wizard:

- **Aside is the primary workaround for Firebase Auth in headless Chrome (verified 2026-08-22, user correction).** The prior v1.4.0 / v1.7.0 default of "headless Firebase popup is blocked → fall back to in-process AI DM simulation" is the WRONG path for live verification. **Aside has the user's actual Chrome session + real CDP** — the Google account chooser renders correctly, and the OAuth popup round-trip completes without COOP blocking. The user explicitly redirected me on this: *"Why are you blocked? aside mcp should be able to handle auth"*. Updated rule: when the user asks for live WA wizard verification, the **first try is Aside** (`aside "<natural language instruction>"` for multi-step flows, `aside repl` for scripted steps), NOT `browserclaw cookies inject`. Only fall back to in-process AI DM simulation when Aside is genuinely unavailable. The 6-step live-verification recipe in `references/wa-live-test-recipe.md` already correctly uses Aside — this changelog entry brings the Skill-MD rule text + Pitfall into alignment. **Concrete Aside-driven shape that worked (2026-08-22):**
    1. `aside "Open https://worldarchitect.ai/new-campaign"` — opens new tab
    2. `aside "Click 'Continue with Google'. When the account chooser appears, click <email>. If a password prompt appears, STOP and report."` — picks the right account via the visible chooser
    3. After sign-in: `aside "Fill Campaign Title / Character / Setting / Description fields with these values: ..."` — one focused step per Aside call (180s timeout means batching too much causes the call to time out mid-fill; small steps + screenshots between)
    4. `aside "Click Next, then 'Enter the World', take a screenshot of the campaign game view. Report first 1500 chars of body text."`
    5. Capture evidence: `aside "Open the dashboard, list the first 10 campaigns with title + character name + last-played timestamp."`
    
    **Aside path quirks** (verified 2026-08-22): (a) aside `listBrowserTabs()` returns AsyncFunction — must be awaited via `(async () => { ... })()` wrapper. (b) console.log output is not directly captured; use file writes via `await fs.writeFile(...)` instead — but `fs` is sandboxed in some sessions. (c) `aside repl` raw script returns "[ok | <Nms>]"; for richer output use the NL agent. (d) Aside session tmp dirs are at `~/.aside/u/0/sessions/<session-id>/tmp/` — files written there survive only as long as the session is alive; copy evidence files to `/tmp/...` for durability. (e) Aside's `--account u0` is `jleechan@gmail.com` by default; `--account u1` is `jleechan@worldarchitect.ai`. There is no `--account u2` for jleechantest@gmail.com without first adding the profile via Aside GUI.

- **WA Firebase Auth state lives in IndexedDB, NOT cookies (verified 2026-08-22).** When the user says "I signed in to Chrome with <account>, there should be cookies to /browserclaw", do NOT assume Chrome has the WA session. **WA's auth state is `firebaseLocalStorageDb` IndexedDB** at `~/Library/Application Support/Google/Chrome/Default/IndexedDB/https_worldarchitect.ai_0.indexeddb.leveldb`. `browserclaw cookies decrypt` only reads the SQLite cookie DB — the IndexedDB is invisible to it. Verified failure mode: Chrome was signed in to Google as `jleechantest@gmail.com` but had **zero** WA IndexedDB entries (the user hadn't actually visited worldarchitect.ai in Chrome with that account). Cookie injection + Playwright launch + `launch_persistent_context` with Chrome profile symlink all failed to inherit the WA session because the IndexedDB wasn't transferred. Symptom: Playwright sees the sign-in screen even though Chrome's Google session is "authenticated." **Pre-flight check before any cookie-inject / Playwright-with-profile-symlink path:**
    ```bash
    ls -la "$HOME/Library/Application Support/Google/Chrome/Default/IndexedDB/" | grep -iE "worldarchitect|mvp-site"
    # If no `https_worldarchitect.ai_0.indexeddb.leveldb`, Chrome has NOT visited WA under this account
    ```
    If the IndexedDB is missing, the user must visit WA in their real Chrome first to populate the Firebase session — then browserclaw can copy the WA cookie set (which WILL exist after that visit). If the IndexedDB exists, `browserclaw cookies decrypt --db "$HOME/Library/Application Support/Google/Chrome/Default/Cookies" --output /tmp/wa-cookies.json --domain-filter '%worldarchitect%'` will return ≥1 row. **The IndexedDB check is the gate** — don't waste a Playwright launch cycle on a profile that has no WA session.

The v1.7.2 Pitfall update (replaces the "fall back to in-process AI DM simulation" wording in User Preferences #15 and the corresponding Pitfall):

Two additions from the Quiet War bible live-test session:

- **Sister-skill pointer: `~/.smartclaw/skills/campaign-creation/`** produces *paste-ready LLM prompts* (different artifact from this skill's rich drafting docs). When the user's ask is "design a campaign from scratch, paste-ready" (vs "iterate my existing bible"), route to that sibling skill — NOT this one. The Self-Contained rule and Phase 3 audit checklist live there. See `references/self-contained-prompt-rule.md` for the full rule. *If the campaign-creation sibling does not exist yet, do not create it from this skill — it must be authored as its own class-level umbrella by the operator's request.* This skill is the designer's tool; campaign-creation is the LLM-prompt tool.

- **Live-verification recipe for WorldArchitect.AI test campaigns.** When the user asks to verify the bible works in the live WA wizard (typical phrasing: `test creation using /browser for <email> / yttesting`), follow the 6-step recipe at `references/wa-live-test-recipe.md`. Confirmed working 2026-08-22 against `pGfqzk2mjPcn8Zsnag9U` (Quiet War under `jleechantest@gmail.com`). The recipe covers: clean worktree from `origin/main`, `TESTING_AUTH_BYPASS=true` background boot, the correct `character` (string, not dict) + `god_mode_data` + `description` payload shape, post-creation verification via `curl /api/campaigns/$CID`, then `/browser` capture via Aside with explicit absolute path under `~/.aside/u/0/sessions/` (not `/tmp/...` — Aside silently redirects there). Includes the SIGTERM-after-kill pitfall: don't `kill -9 <PID>` on the worktree WA server's parent shell; use `pkill -f "<unique-worktree-path>/local.sh"` to avoid dropping the daemon process that the user reaped mid-session.

## v1.6.0 — OP-protagonist cheats + Character-Creation-as-Opening + Personality-Borrow rules (added 2026-08-22)

Four additions from the Demon-Emperor-Reincarnated session (`C0AUXSVFSA2/1786951500.855119`), verified by a user OOB correction ("Consider these elements too and don't forget other asks"):

- **OP-Protagonist Cheat Inventory subsection** (new §3 sub-block). When the user asks for a Jobless-Reincarnation-style magic genius at age 12 who is the strongest being alive, the bible MUST enumerate **4 overlapping cheats** explicitly rather than naming one — the combination is what makes them OP, not any single trait. The "Strongest in the Room" 6-device framework lives at `references/op-protagonist-tension-devices.md`. Pattern: **(1) Lived Experience** (the Demon Emperor saw 40 years of war — modern battles are trivia), **(2) Adult Mind in Child Body** (reasons two steps ahead of every peer), **(3) Magic Knowledge** (spells the modern world forgot, including the L17 Emperor's Memory unlock), **(4) Veil + Guilt Lock** (Veil keeps them anonymous; moral cost of power keeps the campaign interesting). The bible must include an explicit "remove any one — still powerful; remove all four — a prodigy, which is not this campaign" sentence so future sessions see the design intent.
- **Character-Creation-as-Opening** (new §9 pattern). When the user explicitly asks for character creation to BE the first in-world moment, **supersedes** the v1.5.0 no-pre-baked-starting-scene rule (User Pref #22) for that campaign only. The AI DM narrates: *"You stand at the Academy's entrance gate. One last quiet moment before the doors close. What do you do?"* — then a 3-option carousel that IS character creation in-world (walk in carrying only the rapier / carrying everything / pause and read the arch names) + Freeform. The Pronouns & Sibling-Gender Toggle table belongs in §9 itself, not in a separate appendix. Trap: do NOT default to a numbered option set that the user can't interpret — each opening choice should reveal a different facet of the protagonist's *posture* (hiding / revealing / studying), not a different mechanical effect. **Anti-pattern:** do NOT use this pattern unless the user explicitly says "character creation as the first scene" or "I want to redesign the character at the start" — default remains User Pref #22's freeform "What does Rhaenyra do?" open prompt.
- **Personality-Borrow with Anti-X-Guarantees** (new §2 pitfall). When the user says "default personality like Y from show Z, don't copy his plot," the bible must include an explicit **Anti-Y-Guarantees** subsection: 3-4 bullets naming which iconic plot beats are explicitly NOT being used. Verified example — "default personality like Itachi from Naruto but don't copy his plot" produced: "No genocide in the past life. No brother-murder, no village-treason arc. The Demon Emperor lost the war on purpose after becoming guilty — they are not the *good-guy version* of an evil past, they are a *recovering* evil past. The campaign ends open, not in self-sacrifice." Without these guarantees, AI DMs default to copying the iconic plot beats because the personality IS the iconic personality's. Generalize: personality-borrow = always pair with explicit anti-X-guarantees list.
- **Isekai 7-element coverage audit** (new pre-publish checklist item). When the user's ask involves isekai / reincarnation / hidden-power / magic-school, run a 7-element coverage audit before claiming the bible is complete: (1) Death + Rebirth, (2) Retained Memories & Personality, (3) Fantasy World with Rules, (4) Advantage / "Cheat" (must be 4+ overlapping, not one — see Cheat Inventory), (5) Second Chance Theme, (6) Adaptation Arc, (7) Power Progression + Agency. Each element maps to a specific section in the bible: Death+Rebirth = §1; Retained Memories = §2 + the death ledger / 4,873-name count etc.; World with Rules = §7; Cheat = §3 Cheat Inventory; Second Chance = §1 Core Promise + §2 True Self; Adaptation Arc = §1 explicit subsection; Power Progression = §3 gestalt progression + §8 Quad-Pillar. Verified missing this audit caused a 2026-08-22 user OOB correction — Cheat Inventory and Adaptation Arc were both added late as a result.

### OP-Protagonist Cheat Inventory — single-file exception to Male/Female Mirror pattern (added 2026-08-22)

The v1.5.1 Male/Female Mirror pattern explicitly says "do NOT write one bible with a 'choose your protagonist' option" because Ash/Aldric have mechanically-distinct classes + inverted Quad-Pillars. **For mechanically-identical mirrors** (verified example: Demon-Emperor-Reincarnated 2026-08-22, where the only difference is the protagonist's gender + sibling gender + 2 small NPC gender flips — same class, same mechanics, same world, same antagonist, same continuity hooks), ship **one bible + one Pronouns & Sibling-Gender Toggle table** in §9. Default is female protagonist; the player flips by swapping the table rows. This avoids the maintenance cost of two near-identical bibles while preserving the player's gender choice. **Anti-pattern:** do NOT use single-file mode if the mirrors have inverted mechanics, inverted Quad-Pillars, or different faction angles on the same cold war — that case still needs two bibles (or one doc with both stacked under tab dividers).

## v1.5.1 — Slim-to-1k-2k ceiling + mid-task redirect handling + gog drive search (added 2026-08-22)

Three additions from the Demon-Queen-Reincarnated v2 trim session:

- **Slim-to-1k-2k-word ceiling subsection** added to the slim-pass iteration playbook. Verified 15,977 → 12,079 chars (2,885 → 2,013 words) across 6 targeted patches without rewriting any section. Includes the 6-step path (timeline compression / NPC parenthetical drop / family-table compression / spell-list one-liner / AI-DM-Setup dense sentence / rank-table conjunction strip) and the `awk` word-estimate command. Stop condition: ≤2,000 words OR hitting the hard-never-cut floor (XP literal / MBTI annotation / Continuity Hooks header / CANON-PRIORITY / Quad-Pillar names).
- **Mid-task user redirect pitfall** added to the Pitfalls section. When the user asks a clarifying / summarizing question mid-tool-execution ("Summarize what we decided for the world here" delivered while a `patch` loop was running), deliver the asked-for answer in the SAME turn and queue the rest of the work as "Next (background)" rather than blocking. Verified 2026-08-22: the redirect was NOT a cancellation — the user still wanted the doc updated and /web-advice retried; they just wanted a read-out first.
- **`gog drive search` search-then-create recipe** added to User Pref #21. `name contains '<keyword>'` is substring-exact; verified 2026-08-22 that 4 keyword variants (demon / aetheria / astheria / ash) all returned empty for the new bible — search loop covers protagonist name / world name / IP name / "campaign <slug>" / "<slug> bible" before any `gog docs create`. Existing campaign docs (HotD / Visenya / Sariel / Nocturne) reliably find via "campaign" / "vN" / character-name substrings.

Session reference: `references/session-2026-08-22-demon-queen-reincarnated-v2-trim.md`.

## v1.5.0 — No pre-baked starting scene + 3-place sync from canonical Google Doc (added 2026-08-19)

Two new HARD RULES, both from the HotD Ashen Crown session:

- **No pre-baked starting scene** (User Pref #22). The bible's Section 8 (Starting Scene / 4-option carousel) is REMOVED. AI DM narrates the opening situation from the bible's starting state and asks "What does Rhaenyra do?" freeform. The player issues a decree in their own words or invokes any of the v3 fiscal levers. Agents that default to a numbered option set on Turn 1 are over-railroading.
- **3-place sync from canonical Google Doc** (User Pref #23). When the user manually edits a Google Doc and asks to propagate, the doc is the source of truth and the agent's auto-generated copy is NEVER canonical. The 5-step workflow (fetch → identify places → propagate verbatim → verify all match → re-run AI DM sim) lives in `references/3-place-sync-from-google-doc.md`.

## v1.4.0 — Pageless Google Doc HARD RULE (added 2026-08-19)

All campaign Google Docs (created or updated) MUST be pageless. The `gog` CLI does
not default to pageless — most docs come out in PAGES mode with page-break artifacts
and "Page X of Y" footers every ~3K chars. After every `gog docs create` or
`gog docs update` call, run the helper script
`~/.smartclaw/skills/campaign-design-rpg-bible/scripts/gog_doc_pageless.py <doc_id>` to
set `documentStyle.documentFormat.documentMode = "PAGELESS"`. Full recipe + verified
end-to-end PAGES→PAGELESS conversion in User Preferences #21 below.

## v1.3.0 — `/document-standards` pre-publish audit pattern (added 2026-08-18)

When the user invokes `/document-standards`, run the 13-check audit against the
wiki page BEFORE opening the PR. Recipe + verifier live in
`worldai-wiki-publishing` at `references/document-standards-checklist.md`.

## v1.2.0 — TV-vs-book wiki-ingest subfolder split (added 2026-08-18)

For IP-anchored campaign bibles, mirror the source-medium split in
`~/llm_wiki/wiki/sources/<ip>-tv-show/` + `~/llm_wiki/wiki/sources/<ip>-books/`.
Verified working example: HotD 8-episode ingest in commit `ac658db56`.

## v1.1.0 — User-Locked Overrides Applied 2026-08-17

These overrides apply to every bible produced under v1.1.0+ and are non-negotiable defaults unless the user explicitly overrides them in a session:

1. **No Mortal Anchor concept by default.** The Mortal Anchor cascade-threshold NPC mechanic is **removed** from the bible skeleton. Replace with Quad-Pillar *Paranoia* / Hidden Apex / Loom stats (see HotD Ashen Crown convention) for isolation tension. The Rhaenyra HotD override (2026-08-13, "we dont need mortal anchor") confirmed this works as a default. **Always confirm with the user** before adding a Mortal Anchor in v1.1.0+ — they may want it explicitly per-campaign.

2. **No Endings Matrix, Canonical Ending, or Final Verdict — period.** Every bible replaces this with **Continuity Hooks** (§10). The user explicitly stated on 2026-08-17 ("no and remove endings from the skill"): there is no path where the bible ships with an ending-shaped section. The user's hot-lock from HotD Ashen Crown (2026-08-13, "let's stop doing these endings going forward, no endings") is now the **skill default**, not an override. Refuse to write an endings section unless the user explicitly contradicts this in a future session.

3. **No WA wizard push by default.** Slimmed ≤16k paste-ready versions may be embedded in the wiki page, but **do not push** to the worldarchitect.ai Custom Campaign wizard unless the user explicitly says so. Default is staging-only.

---

# Designing RPG Campaign Bibles for WorldArchitect.AI

A campaign bible is **the system the AI DM runs**, not the story the player reads.
It is a paste-ready text the user drops into the WorldArchitect.AI Custom Campaign
wizard's "Campaign description prompt" field. The AI DM plays it; the player drives
the story; **the bible never pre-decides outcomes**.

## User Preferences (Jeffrey — locked)

These apply to every campaign bible for this user. Encode them so future sessions
start already aligned.

1. **No endings (HARD RULE, locked 2026-08-17).** The bible ships as an *open-ended system*, not a *story with a destination*. Never include an "Ending Determinator" matrix, a "Canonical Ending" section, a "Final Verdict" binary, a "What ending do you unlock?" UI, or any **pre-decided outcome section**. Replace any ending-shaped content with **"Campaign Continuity Hooks"** — 3+ unresolved threads the AI DM can pick up between Acts so the campaign never closes. The user explicitly stated on 2026-08-17 ("no and remove endings from the skill"): there is no path where the bible ships with an ending-shaped section. This is the **skill default**, not an override — refuse to write an endings section unless the user explicitly contradicts this in a future session. (See Pitfall: no-endings.)
2. **Player agency over railroading.** Every Act ends with a 3-option carousel plus a
   **Freeform** slot. Never force the player into "Option A vs Option B" without an
   escape hatch.
3. **Hidden Apex + (Mortal Anchor: OPTIONAL, not default) + Ascension Track** (for protagonist characters with hero arcs). Translate these as:
   - **Hidden Apex:** an unfair-by-design advantage that scales with player state
     (not raw power). Mathematically outclasses without being louder/faster.
   - **Mortal Anchor (ditchbond): OPTIONAL — not part of the default bible skeleton.** A named NPC whose Loyalty stat, if it drops below a threshold, cascades mechanically (CS crash, Paranoia spike, etc.). The anchor is the "smallfolk tying her down" — prevents pure villain-fantasy. **As of 2026-08-17 the user has hard-removed this from the default bible skeleton** ("no and remove mortal anchor"). The Quad-Pillar Paranoia stat now carries the isolation tension without a dedicated anchor NPC. **Confirm with the user explicitly before adding a Mortal Anchor in v1.1.1+** — they may want it per-campaign (the Visenya Divine line still uses one), but it must be confirmed per-session, not assumed from skill defaults. (See Pitfall: no-mortal-anchor.)
   - **Ascension Track (NOT death clock):** Reputation / recognized-sovereignty
     tiers that grant perks *and* burdens. For non-divine characters, stop at
     "Rightful Queen" / "Recognized Sovereign." Divine-rank is reserved for the
     dedicated Visenya divine-lineage line. **Rhaenyra-specific override
     (2026-08-13, "we can do divine ascension at level 25 if they get that
     far"):** the campaign may include a **L25 Divine Ascension Track** as an
     *optional* end-game content path the player can choose to pursue or ignore.
     It's gated behind reaching L25 in a campaign that's designed to top out at
     L20-L25, not a default unlock.
4. **Lore anchor: show-primary, book-fallback.** When designing for a TV adaptation
   (e.g., House of the Dragon), anchor the starting state to a *specific canonical
   moment* in the show's most recent finale (e.g., post-Season-3 Helaena death,
   Aegon alive on Dragonstone). Where the TV cut off or diverges from source
   material (e.g., GRRM's *Fire & Blood*), note "[Book fallback]" inline with the
   GRRM canonical option for the AI DM to consider. **Never invent TV canon that
   doesn't exist**; this user calls out AI fabrications. **User default for HotD
   (locked 2026-08-13, "Q8: anchor to season 3 and book is just fallback"):**
   start at Season 3 finale state (Helaena-dead, Aegon-alive-on-Dragonstone,
   Jace-dead-at-Gullet, Tumbleton-burned); book (Fire & Blood, 2018) only where
   S3 cut off or diverged.
5. **Naming matters.** Mechanically named traits get cool names ("DragonsBond",
   "Blood Dragon", "First Song", "Apex Stalker", "Maimed Miracle"). Avoid generic
   "Fire Resistance +2" phrasing for signature abilities.
6. **Vivid sensory prose over generic fantasy.** Setting descriptions open with
   smell, weather, light, sound — not "this is a tavern."
7. **9-section bible shape** (paste-ready into WorldArchitect.AI wizard):
   1. Campaign Intro (power-fantasy hook + lore anchor)
   2. Character Personality (MBTI hinge + 3 inner-monologue seeds)
   3. Class & Subclass (base 5e class + custom subclass with signature ability)
   4. Assets & Retinue (starting gold + signature items + 3 starting NPCs)
   5. Family / Viper's Nest (named NPCs with Loyalty matrix)
   6. Factions (10 houses with Loyalty matrix)
   7. World Lore (timeline + magic system)
   8. Gazetteer & Mechanics (dragon classes, fog-of-war, deficit cascade, ascension track)
   9. Starting Scene (canonical opening dilemma, 3-option carousel + Freeform slot)
   10. **Campaign Continuity Hooks** (replaces the "Endings" section — open-ended threads)
8. **Per-die-roll XP rule (user-authored, locked 2026-08-13).** Default to:
   `XP = 0.34 × (next_level_threshold − current_level_threshold)` awarded per
   successful or failed die roll (attack roll, save, ability check, skill check)
   using standard D&D 5e cumulative XP thresholds (L2=300, L3=900, L4=2700,
   L5=6500, ..., L20=355000). NO XP during god mode (narrator-driven cutscenes,
   time-skips, scripted sequences) or turns where time does not advance
   (level-up modals, character-creation modals, downtime bookkeeping). Bonus
   damage rolls do not separately award XP — only the to-hit/save/ability-check
   roll that determined the outcome. Worked example (user's, slightly corrected
   for threshold 900 not 700): L2→L3 distance 600 → `0.34 × 600 = 204 XP per die`.
   Rationale: ~30-50 die rolls per Act yield 1.5-2 level-ups; Acts span ~3-5
   levels; the whole campaign (Acts I-IV) spans L11-L25 in ~14 Acts. If the
   user gives a different XP formula, use their formula and note it in the
   bible with a `[Balance check pending]` marker until cross-model review
   confirms.
9. **File naming convention (locked 2026-08-13, "Q7: no date"):** omit date prefix
   from the LLM wiki filename. Use `house-of-the-dragon-ashen-crown.md`, not
   `2026-08-13-house-of-the-dragon-ashen-crown.md`. The earlier date-prefixed
   Visenya/HotD templates (`2026-08-04-house-of-the-dragon-campaign-template.md`)
   are grandfathered but new bibles should follow the no-date convention.
10. **Appendix A + B pattern for wizard-paste handoff** (proven in 2026-08-13
    session): because the LLM-wiki source bible is intentionally longer than the
    worldarchitect.ai Custom Campaign wizard accepts (≥16k char hard cap), include
    in the bible:
    - **Appendix A:** a meta-prompt the user pastes into any LLM chat to slim
      the bible to ≤16k chars while preserving the 9-section + Section 10 shape,
      Quad-Pillar mechanics, XP rule, class features, NPC dramatis personae,
      dragon archetypes, starting scene, and no-endings rule. The meta-prompt
      lists explicitly what to preserve vs. cut.
    - **Appendix B:** the wizard field checklist verified against the live
      worldarchitect.ai wizard (verified 2026-08-05: `Use Default Fantasy World`
      is unchecked by default, no action; `Mechanics (Jeff's Mechanical
      Precision)` is unchecked by default — **must check** for custom 5e
      mechanics to be honored).
    This pair lets the LLM-wiki source bible be a rich drafting document AND
    produces a paste-ready slimmed version without forcing the user to write
    the slimmed bible themselves.
11. **No hardcoded engine presets — propose primitives, declare rules.**
    This is the engine-layer generalization of rule #1 ("no endings"). When
    filing GH issues against `jleechanorg/worldarchitect.ai` for player
    feedback, NEVER propose hardcoded attribute lists / outcome-tier band
    tables / story-card types as the deliverable, even when the player
    proposed concrete examples in their feedback (Bleach preset, 5-tier
    margin table, "Tone/Recap/Phobia" card types). The user explicitly
    rejected this framing on 2026-08-14: *"I dont want this hardcoded, i
    want the engine to be good enough to let a player declare these
    rules."* The right architecture is the engine exposing primitives
    (schema lookup, contested-roll, card injection) and the *campaign*
    declaring the rules. The canonical proof is issues #8901–#8906 filed
    2026-08-14: each one reframes a player suggestion as "engine exposes
    primitive + player-campaign declares the rule" rather than
    "engine ships a preset." Same principle when writing prompt content
    directly into a campaign bible: ship the rule *system* (how the
    player declares the rule), not the rule itself.
12. **Cross-check canon before publishing** (locked 2026-08-13, after
    live-playtest feedback via `/repro` against the live worldarchitect.ai
    wizard). AI-generated source text — Gemini share outputs, LLM campaign
    drafts, even careful ones — **routinely invents plausible-sounding but
    wrong canon**. Verified failure modes from 2026-08-13 HotD Ashen Crown
    capture (see `references/session-2026-08-13-hotd-ashen-crown.md` §
    "Canon-corrections from live playtest"):
    - **Parent vs grandparent:** Gemini's v3 source had Corlys saying "My son
      Jacaerys" — but Jace was the son of Rhaenyra + Laenor Velaryon;
      Corlys is Jace's **grandfather**. The bible inherited the error in
      the Starting Scene quote. Fix: reword to "my grandson."
    - **Loyal vs traitor:** Gemini's source said "Addam of Hull is branded a
      traitor by your paranoia" — in canon Addam was **legitimized as a
      Velaryon in S3 E3 and stayed loyal throughout Season 3**. The bible
      propagated the traitor framing into the Starting Scene quote. Fix:
      reword to "fled into the night to prove his loyalty after the
      smallfolk whispered that your dragonseeds were traitors."
    - **Event timing:** Gemini's source undated Jace's death to "Jace is
      dead" with fresh-grief tone. In S3 he died in **S3 E1 "Salt and Sea,
      Fire and Blood"** at the Battle of the Gullet, ~60 days before the
      S3 finale. The bible inherited the fresh-grief framing. Fix: date
      the death explicitly; frame grief as ~60 days old, not fresh.
    **Workflow before publishing any AI-source-mediated campaign bible:**
    (a) named character relationships — parent/grandparent/child/spouse;
    (b) event timing — which episode/chapter / in-world year;
    (c) faction allegiance — loyal/rebel/traitor and when it flipped;
    (d) deaths and survivors — who died when, who is still alive;
    (e) marriage, legitimacy, and succession status. Cross-check each
    against actual canon (Wikipedia summaries, the show's episode list, or
    the source novel's chapters). Add a "Canon-correction notes" section
    to the LLM-wiki source so the AI DM does not regenerate the errors on
    a re-roll.

    **The user's canon-check trigger is launching the bible in the live
    worldarchitect.ai wizard and reading what the AI DM narrates.** If
    they ask "how large is it?" followed by "show me the gh url" they
    are about to launch and read; pre-empt by running the canon-check
    pass on your own before they find the error. The user runs `/repro`
    against the live wizard as their canon-check — if they find anything
    wrong, fix in one push, do not argue.

13. **Slim-down-to-paste threshold: ~16,000 chars default, but **no hard cap for IP-anchored bibles with canonical detail** (verified 2026-08-18, HotD Ashen Crown v4: 16,694 chars / 2,596 words shipped successfully — the user's verbatim OOB "there really is no cap, so dont worry, use whatver words you need" overrode the prior 16k cap for this campaign).** The worldarchitect.ai Custom Campaign wizard's "Campaign description prompt" field has a default guidance range of ~16k chars for **original-world bibles** (verified 2026-08-14, 21,008-char attempt resulted in `SLIMMED_BIBLE_LEN=21008` over-limit, wizard test failure). For **IP-anchored bibles** (HotD, BG3, Naruto, etc.) where the AI DM needs canonical detail (character arcs, episode-by-episode anchors, faction tables) the user has relaxed this limit — **verify the user's preference per-campaign before committing to a slim pass**.

    **Word-count ceiling for show-anchored bibles: 3,000 words max** (user default 2026-08-18, "ok lets target 3k words thats fine"). The prior 1k-2k target was relaxed mid-session to accommodate the canonical-detail load (S3 episode anchor, Things-TV-has-NOT-established list, hardened starting state). The 3k word ceiling is for the **paste-block inside the `BEGIN_COPY_PASTE_BIBLE ... END_COPY_PASTE_BIBLE` fence**; the full wiki page with framing/setup-notes/source-meta can exceed this.

    After you write the canonical full-form bible to `~/llm_wiki/wiki/sources/<name>.md` (target 25-50K bytes), produce a **paste-ready slim version** sized to the user's preference (default: 3k words / ~16k chars for original-world, 3k words / no hard cap for IP-anchored). The slim lives in:
    - `~/projects/worldai_wiki/queries/<name>.md` (public wiki, requires PR)
    - Google Doc (`gog docs create "<title>" --file /tmp/<slug>_gdoc.md`)
    - Both copies must match bit-for-bit (paste-block contents identical)

    Slimming rules (preserved across iterations):

    - **Preserve:** all hard mechanics (Quad-Pillar numbers, XP rule,
      class features, NPC dramatis personae names + loyalty scores,
      dragon archetypes, starting scene, no-endings rule, canon-priority
      prompt).
    - **Cut:** redundant prose, redundant field descriptions, full
      spell lists (replace with "standard 5e prepared, max L6 per
      GRRM-faithful magic cap" or equivalent one-liner), per-house
      detail in faction lists (collapse middle-tier houses to "see
      LLM wiki for full list"), full dragon-progression table (keep
      L11/L12/L16/L20 anchors only), full deficit-cascade timeline
      (compress to one line per day), full reputation-tier
      descriptions (collapse to one line per tier), multi-paragraph
      starting-scene prose (tighten to 1-2 sentences per speech).
    - **Always include:** the CANON-PRIORITY prompt (TV show > older TV
      > book — see rule #14 below) in both the slimmed AND the full
      LLM-wiki bibles. AI DM instructions may compress to 4-7 bullet
      points in the slimmed version.
    - **Never include:** the Endings Matrix (per rule #1).

    Slimming loops: write the slimmed version, count chars with
    `wc -c`, iterate cuts if over 16k. Goal = 14k-15.5k chars
    (headroom for AI-DM additives). See
    `references/session-2026-08-14-hotd-slimming-w16k.md` for the
    2026-08-14 HotD Ashen Crown slimming pass (21,008 → 15,837 chars
    across 23 cuts; final bible PASSED the simulated AI DM on
    attempt 1).

### Slim-pass iteration playbook (added 2026-08-19)

Verified on the Demon-Queen-Reincarnated bible: 17,001 → 15,977 chars across 4
passes. Each pass was a single targeted `patch` call, not a rewrite. Use this
section-priority order when cutting — the heaviest prose lives in the same
places every time:

1. **Starting-scene prose first** — Section 9 typically holds 1.5–2.5K chars of
   read-aloud dialogue. Cut adjectives, drop second occurrences of stage
   directions, compress each character's first spoken line to ≤8 words. Each
   pass: ~300-500 char savings.
2. **AI DM Setup block at the end** — the bulleted "no endings / MBTI DM-only
   / demons sentient / etc." list compresses to a single dense sentence with
   semicolons. ~400-600 char savings.
3. **NPC dramatis personae descriptions** — trim parenthetical backstory clauses
   ("she has suspected since week two and has chosen to say nothing" → "she has
   suspected since week two and chosen to say nothing"). ~50-150 chars each.
4. **Rank tables** — when the table has 8-11 rows with prose descriptions per
   row, convert to "Rank → next Rank (perk)" arrow chains. The user's HotD
   rank table is the canonical compact form. ~400-800 char savings.
5. **Frontmatter YAML + headers** — the `## Section N — Title` lines compress
   to single `#` headers or inline-bold section breaks. ~50-200 char savings.
6. **Last resort: cut Quad-Pillar rows** — only if every other section is
   already minimal. Don't cut the 4 pillars themselves; only cut the floor/ceiling
   effect descriptions.

### Slim-to-1k-2k-word ceiling (added 2026-08-22, Demon-Queen-Reincarnated v2)

**Male/Female Mirror pattern (added 2026-08-22, verified on Ash + Aldric).** When the user asks for "a male and female version of the campaign as different tabs / different wiki entries" (verified ask pattern from 2026-08-22 thread `C0AUXSVFSA2/1786951500.855119`), build TWO bibles that share the world, family tree, Academy, and 3-way cold war — but each protagonist is the **antagonist of the other's previous-life**. Mechanics are **inverted mirrors**: Ash's Veil ↔ Aldric's Oath; Aether Escalation (earn VP by *lying successfully*) ↔ Pact Escalation (earn PP by *telling truth successfully*); Ash-Crowned Memory (necromancy *rebuilds what was destroyed*) ↔ Hero's Memory (abjuration *holds a single person alive past their death*). Family tree gets mirror rows: Ash has 5 sisters + a brother, Aldric has 5 brothers + a sister, sharing Margrave Voss as father — *in the same campaign, Ash and Aldric are siblings in this life*. **Cross-link hooks:** the Ash-Crown and the Hero's Blade live in the SAME reliquary vault, both protagonists can feel them from 3 floors away, both Veil/Oath drop simultaneously if both owners look. In a two-player campaign the hooks collide and the demon spies (Liriel for Ash, Quiet Brother for Aldric) report to the same demon emperor — *who does each spy tell first* becomes a live player-driven fork. Ship both slims as separate LLM wiki files (`demon-queen-reincarnated-slim.md` + `hero-reborn-aldric-slim.md`), each trimmed to the 2,000-word ceiling independently. **Anti-pattern:** do NOT write one bible with a "choose your protagonist" option — the two have mechanically distinct class features (gestalt Wizard/Sorcerer vs Paladin/Warlock), inverted Quad-Pillars (Paranoia/Guilt/Witnesses vs Righteousness/Doubt/Witnesses), and different faction angles on the same cold war; cramming both into one bible breaks the paste-ready format. **Google Doc shape for mirrors:** offer the user a choice — one doc with both bibles stacked under `▼ TAB 1 — Ash ▼` / `▼ TAB 2 — Aldric ▼` dividers (4k words combined, easier to read together) OR two separate docs (one per bible, easier to paste per campaign). Default is two separate docs unless the user explicitly asks for tabs.

User override on the 3k-word default: for original-world bibles where the user
asks for "max 1000-2000 words" (or a 1.5k-2k mid-range), the slim target is
**2,000 words / ~12,000 chars** at 6 chars/word. Verified path
(15,977 → 12,079 chars / 2,013 words across 6 targeted patches, no rewrite):

1. **Aggressive Section 7 timeline compression** — turn bullet entries with
   verb phrases into a single inline paragraph with bold year anchors.
   -300 chars.
2. **NPC parenthetical backstory** — drop the second qualifying clause
   ("bright, lonely", "earnest, awkward") when the function line already names
   the role. -50-100 chars each.
3. **Family table** — compress "Eldest sister, married to a duke" →
   "Eldest, married to a duke"; drop "second/third" when ordinal is clear.
   -50-100 chars.
4. **Spell-list bullets → one-liner** — "starting spells: cantrips (...) + L1
   (...)" → "starting spells: standard 5e prepared, max L6 per old-magic cap."
   -150 chars.
5. **AI DM Setup footer** — turn the bulleted "no endings / MBTI = DM notes
   only / demons sentient / old magic > modern / etc." list into one dense
   sentence with semicolons. -300 chars.
6. **Rank table → arrow chains** — already compact; one more pass on the three
   tables drops conjunction words ("but", "and also"). -50 chars total.

**Per-pass verification:**
`awk 'BEGIN{total=0}{total+=length($0)+1}END{print total/6.0}' <slim_file>` —
report the word estimate inline. Continue until the estimate is ≤2,000.

**Stop when:**
- Word count ≤2,000 at 6 chars/word
- OR you've cut every safe section and are about to touch Quad-Pillar rows or
  the 5 hard-never-cut items (XP literal, MBTI annotation, Continuity Hooks
  header, CANON-PRIORITY block, Quad-Pillar names+floor/ceiling numbers).
  At that point tell the user the floor was hit and ask whether to relax the
  ceiling or live with the slimmed-but-slightly-over result.

**What NEVER cuts** (same list as the 16k slim-pass playbook):
- The XP rule literal (User Pref #8 — user-authored formula)
- MBTI annotation as "(DM notes only)" (User Pref #4 — never-quote-in-prose rule)
- No-Endings / Continuity Hooks header (User Pref #1 — hard rule)
- CANON-PRIORITY block (User Pref #14 — hard rule when applicable)
- The four Quad-Pillar names + floor/ceiling numbers

**Per-pass verification (both 16k and 1k-2k passes):** after each `patch`, run
`awk 'BEGIN{total=0}{total+=length($0)+1}END{print total}' <slim_file>` (NOT
`wc -c` — `wc -c` counts bytes which over-reports on multi-byte UTF-8 like
em-dashes and curly quotes, which appear in every bible). Continue until
the awk count is under 16,000. Goal range 14k-15.5k.

14. **CANON-PRIORITY hard rule (locked 2026-08-13, expanded 2026-08-18, "follow the TV show. Maybe just ignore the book then we should say").** For ANY IP-anchored campaign bible — TV show, book, game, film, comic — both the LLM-wiki source AND the slimmed wiki page MUST contain an explicit CANON-PRIORITY block in §1 (or front matter) that names the **single authoritative source medium** and rules out silent substitution from alternate media. Canonical template:

    > The *House of the Dragon* TV show (S1–S3, 2022–2026) is the **primary and authoritative source** for all lore, character fates, dialogue, and political events. **Book fallback:** GRRM's *Fire & Blood* (2018) is a last-resort fallback ONLY where the TV show has not covered an event. If a fact exists in the TV show, the TV-show version supersedes any book version — even if the book is older or more detailed. **Do not invent TV canon. Do not silently substitute book canon.** When in doubt, prefer the most recent TV-show episode over both older TV-show episodes and the book. **TV show > book, full stop.**

    And the Setup Notes / AI DM rules section must restate the rule. Without this prompt, AI DMs will silently substitute alternate-medium canon (book for TV show, earlier seasons for later seasons, manga for anime, novelization for film). Verified failures from this user: (a) 2026-08-13 — AI DM narrated "Corlys is Jace's father" until the priority prompt was added; (b) 2026-08-18 — bible inherited a v3-invented "Addam has fled into the night to prove his loyalty" framing that I copied from a Gemini source but that doesn't exist in the show; (c) 2026-08-18 — bible had Aegon at Dragonstone + Ormund marching north + Aemond recovering at Harrenhal, all wrong per the actual show finale (Aegon at Rook's Rest, Ormund dead at Tumbleton E8, Aemond wounded but alive). The CANON-PRIORITY block must explicitly forbid invention, not just prefer TV show over book.

15. **Iterate-to-conformance pattern (locked 2026-08-14, expanded 2026-08-22 v1.7.2).** When the user asks to
    iterate up to N attempts against the live worldarchitect.ai
    wizard (typical phrasing: "iterate until it conforms or max N
    attempts," "test creation using our campaign prompt and see if
    the created campaign conforms," "test campaign creation using /browser for <email> / yttesting"), the canonical workflow is:

    **a. Try Aside first** — see v1.7.2 changelog for the Aside-driven shape. Aside has the user's real Chrome session, handles the Google account chooser + Firebase OAuth popup correctly, and works for live verification. **This is the default path**, not a fallback. Verified 2026-08-22: Aside + signed-in `jleechan@gmail.com` completed the full WA wizard → campaign creation → game-state capture flow in ~3 minutes.

    **b. Try headless auth only if Aside is unavailable** via `browserclaw cookies decrypt` + `browserclaw cookies inject --headless --browser-channel chromium`. **Pre-flight check (v1.7.2):** verify Chrome has the WA IndexedDB before launching (`ls "$HOME/Library/Application Support/Google/Chrome/Default/IndexedDB/" | grep -iE "worldarchitect|mvp-site"`). The Firebase Auth popup round-trip is blocked by `Cross-Origin-Opener-Policy` in headless Chromium (verified 2026-08-14 + 2026-08-22; workarounds tried: `--disable-features=CrossOriginOpenerPolicy`, `--disable-web-security`, switching to WebKit — all failed). Symptom: popup opens, console reports `Cross-Origin-Opener-Policy policy would block the window.closed call` AND the page text never changes from the unauthenticated landing.

    **c. Last resort: in-process AI DM simulation** using the
    `claudem` bashrc wrapper (`bash -lic 'claudem -p "..."'
    --max-turns 2`). Feed the slimmed bible **inline** (not as a
    file-read, which burns the only turn) + a WA-AI-DM-style
    instruction + the canon-priority prompt. Worker produces an
    opening scene in plain prose; detector (regex against the known
    canon-errors from rule #12) checks for parent/grandparent,
    event timing, loyal/traitor, dead/alive. PASS on attempt 1 is
    the ideal outcome. Use this when the user wants *conformance verification*, not *live verification* — i.e., they want to know the bible is canon-clean without launching it in the wizard.

    **c. Iterate bible revisions** between attempts. Each attempt:
    detect errors in the AI DM output, patch the bible, re-run.
    Limit to ≤10 attempts (user-stated). Conformance is met when
    detector reports 0 canon errors AND ≥80% structural checks
    (Quad-Pillar references, named NPCs, option carousel, show
    anchor phrasing).

    **d. Ship-state for live verification.** Once simulated
    conformance passes, the slimmed bible is ready for the user's
    `/repro` test in their real Chrome session. The user runs
    `/repro` against the live wizard as their final canon-check;
    treat any user `/repro` finding as a hard fail and fix in one
    push. Do not argue; do not produce more AI text without
    reverifying canon against actual show/novel source.

    See `references/session-2026-08-14-hotd-slimming-w16k.md` for
    the 2026-08-14 HotD Ashen Crown iteration: PASS on attempt 1,
    21,008 → 15,837 char slim, simulation harness at
    `/tmp/wa_sim_v2.py`, response at
    `/tmp/wa_sim_responses/attempt1_response.txt`.

16. **Anchor against the source-medium episode list, NOT the LLM's recall (locked 2026-08-18, "TV show may not be in gemini 3 flash training data for latest season").** When designing an IP-anchored campaign bible for a TV show / book / game / film that has *recent* canonical content (e.g., HotD S3 aired Jun 21 – Aug 9, 2026), the LLM generating the bible (Gemini 3 Flash, GPT-4, Claude Sonnet, etc.) **may have a knowledge cutoff that misses the most recent canon**. The LLM will silently invent "plausible-sounding" canon that sounds right but isn't in the source.

    **Mandatory source-of-truth for recent IP canon: the show's episode list / the novel's chapter list / the game's patch notes — not the LLM's recall.** Concretely:

    - Pull the IP's Wikipedia episode list via `curl -fsSL -A "Mozilla/5.0" "https://en.wikipedia.org/wiki/<IP>_season_N" | grep -E -iE "<title>|<h2|<h3|>Episode.*<|no.overall|no. inseason|originalairdate|<episode-title-keyword-1>|<episode-title-keyword-2>"` and parse the table manually.
    - Cross-check the bible's starting-state claims against each episode's plot summary.
    - For each starting-state fact in the bible, the bible should cite the **episode and air date** where the fact is established (e.g., "Sunfyre's status ambiguous — found dead in S3 E4, reanimated in S3 E7").
    - When the source-medium has NOT established a fact (e.g., Addam's exact location after S3 E3, Aemond's fate after S3 E7), the bible MUST say "do not invent" rather than guess. Include an explicit **"Things the TV show has NOT established"** list with 3-5 such items.

    Verified failure (2026-08-18, HotD Ashen Crown v3 → v4): the v3 bible's "Addam fled into the night to prove his loyalty" was generated by an LLM that did not have the S3 E3 episode in its training data; the bible inherited this invention through 3 commits (commits `f8ba368`, `cd8c9f3`, `f4002dc`). The user's 2026-08-18 directive ("follow the TV show. Maybe just ignore the book then we should say") was the catch — the fix was to anchor against Wikipedia's S3 episode list (verified 2026-08-18) and rebuild every sentence against the actual show, with explicit "do not invent" exclusions for facts the show has not established.

17. **Wiki-ingest source-medium canon into a TV-vs-book subfolder split (locked 2026-08-18, "there should be like a subfolder for house dragon tv vs books").** When the campaign bible is anchored to a TV show, book, game, or other IP, the LLM-wiki staging area should mirror the IP's source-medium split. Concretely:

    ```
    ~/llm_wiki/wiki/sources/
    ├── <ip>-tv-show/                           # TV show canon (primary)
    │   ├── README.md                            # Season index
    │   ├── season-N-episode-1-<slug>.md
    │   ├── season-N-episode-2-<slug>.md
    │   └── ...                                  # One page per episode
    ├── <ip>-books/                             # Book canon (fallback only)
    │   └── README.md                            # Placeholder + "TV show > book" rule
    └── <campaign-bible>.md                     # The campaign bible (cross-links both)
    ```

    Each episode page includes: air date, director, writer, viewer count, plot summary, canon-state changes vs prior episode, cross-references to character entities and sibling episodes, sources. The README is the season index with a table of all episodes. The campaign bible's frontmatter includes `tv_show_canon: "[[<ip>-tv-show/README.md]]"` and `book_canon_fallback: "[[<ip>-books/README.md]]"`.

    This split enforces the bible's CANON-PRIORITY rule (TV show > book) structurally — agents loading the bible can immediately see the source-medium hierarchy in the frontmatter. The split also gives the AI DM a per-episode working-memory map when it loads the bible.

    Verified working example: 2026-08-18 HotD Ashen Crown v4 — 8 episode pages + 1 index + 1 book placeholder, all pushed in one commit (`ac658db56` on `jleechanorg/llm-wiki` main). The PR diff was +11 pages / ~25K bytes; the AI DM sim's compliance with the CANON-PRIORITY rule (no invented Addam subplot, correct Aegon-at-Rook's-Rest, correct Ormund-dead) improved from v3's 3 errors to v4's 0 errors.

18. **Update an existing Google Doc in place with `gog docs update` (added 2026-08-18).** When the user asks to "update the Google Doc" (not "create a new one"), use `gog docs update <docId> --content-file <path> --format markdown` to overwrite the doc content with the new markdown. This was the user's verbatim ask on 2026-08-18 ("also update the google doc https://docs.google.com/document/d/1vpTfAgIP9mf04MJ9X8t-Wjv5-MW3eVBGtxPyuMSebKg"). The doc ID is the 44-char hash in the URL between `/d/` and `/edit`. Recipe:

    ```bash
    gog docs update "<docId>" --content-file /tmp/<slug>_update.md --format markdown
    ```

    After update, verify with `gog docs cat "<docId>" --plain | head -3` (should show the new title) and `gog docs cat "<docId>" --plain | grep -E "<old-canon-error>"` (should return 0 matches — the v3-invented errors should be gone). Verified 2026-08-18: replaced the v3-HARD doc content (which had "fled into the night", "Aegon at Dragonstone", "60 days", "Ormund marching north") with the v3-TV-CANON+HARD content (Rook's Rest, wounded S3 E7, seven weeks, Ormund dead) in one `gog docs update` call. Use `--append` to append instead of replace. The default behavior replaces all content with the file's contents.

19. **Public wiki page title carries NO version label (locked 2026-08-18, "just call it v3 and in the public worldai wki dont give it a ersion").** The bible CONTENT may carry an internal version label ("[v3 TV-CANON + HARD]" inside the ` ```text ` fence as a marker for the AI DM); the public wiki page TITLE (`title:` in frontmatter + the first `# H1`) does NOT carry a version. Players see one canonical campaign name, not "v3 vs v4." Git commit messages can carry the version for traceability. Pair with `worldai-wiki-publishing` Phase 6.7 for the full convention.

20. **`/document-standards` pre-publish audit pattern (locked 2026-08-18, "lets run /document-standards on it in the worldai wiki").** When the user invokes `/document-standards`, run a 13-check audit against the wiki page BEFORE opening the PR. The audit catches issues the wikilink linter alone misses (invalid tags, fence-decoration violations, page-length cap, self-containment). The 13 checks live in `worldai-wiki-publishing` at `references/document-standards-checklist.md` (full recipe + inline Python verifier + common fixes per failing check). Run the audit inline, fix any failures, re-run, then commit. The "13/13 checks passed" summary should appear in the Slack thread reply right before the PR commit.

21. **All campaign Google Docs must be pageless — HARD RULE (locked 2026-08-18, "always make google doc pageless").** Every Google Doc created or updated by this skill (canonical HotD bible + any custom-campaign design + every shared variant) must have `documentStyle.documentFormat.documentMode = "PAGELESS"`. Pageless = continuous scroll, no page breaks, no pagination artifacts, no "Page X of Y" footer. Verified 2026-08-19 against `gog docs create <title> --file ...`: the `gog` CLI does NOT default to pageless (most docs come out in `PAGES` mode). You MUST call `python3 ~/.smartclaw/skills/campaign-design-rpg-bible/scripts/gog_doc_pageless.py <doc_id>` (or pass `--recent N` / `--all`) after every `gog docs create` to enforce this rule. The script is a small Python helper that uses the gog OAuth refresh token (no new credentials required) to call `docs.documents.batchUpdate` with `updateDocumentStyle` setting `documentMode = "PAGELESS"`. Verified working 2026-08-19 on doc `1KfgdlubyKfG_XnOaN2v6htlJahstqWpynk1L4EjV75M` (PAGES -> PAGELESS verified end-to-end via the same script's `--dry-run` mode).

    **Before creating a new doc — search for an existing one first (added 2026-08-22).** The user's campaign Google Doc inventory has ~50+ entries by mid-2026 and docs get named inconsistently ("campaign X v3", "X — campaign", "Campaign X", "X bible", "X — paste-ready", etc.). `gog drive search "name contains '<one-keyword>'"` is **substring-exact** and only matches if the keyword is contiguous in the filename. Verified 2026-08-22 (Demon-Queen-Reincarnated): searching for "demon", "aetheria", "astheria", and "ash" each returned **zero** matches because the user hadn't created one yet — but the same search against existing campaign docs (e.g. "campaign nocturne bg3 v7", "campaign visenya v9") reliably finds them via the "campaign" / "vN" / character-name substring. The canonical recipe before any `gog docs create` for a new bible:

    ```bash
    # Try 4-6 keyword variants in parallel — substring must be contiguous
    for kw in "<campaign-slug>" "<protagonist-name-lowercase>" "<world-name>" "<ip-name>" "campaign <slug>" "<slug> bible"; do
        gog drive search "name contains '$kw'" --max 10
    done
    # If any returns rows, use `gog docs update <docId>` (rule #18), not create.
    # If all return empty, create new.
    ```

    Symptom of forgetting this step: a new "Ash of Aetheria" doc gets created alongside an existing untitled or differently-named doc the user already maintains — the user has to manually delete one and reconcile. Always search-then-create.

    **Recipe (paste this after every `gog docs create`):**
    ```bash
    # After creating a doc:
    DOC_ID=$(gog docs create "<title>" --file /tmp/<slug>_gdoc.md --json | jq -r .id)
    python3 ~/.smartclaw/skills/campaign-design-rpg-bible/scripts/gog_doc_pageless.py "$DOC_ID"
    # Verify:
    python3 ~/.smartclaw/skills/campaign-design-rpg-bible/scripts/gog_doc_pageless.py --dry-run "$DOC_ID"
    ```

    **For `gog docs update` calls (in-place overwrite):**
    ```bash
    gog docs update "<docId>" --content-file /tmp/<slug>_update.md --format markdown
    python3 ~/.smartclaw/skills/campaign-design-rpg-bible/scripts/gog_doc_pageless.py "<docId>"  # re-assert pageless after overwrite
    ```

    **Bulk operations:**
    - `python3 gog_doc_pageless.py --recent 10` — last 10 docs
    - `python3 gog_doc_pageless.py --all` — all docs in the user's Drive
    - `python3 gog_doc_pageless.py --query "name contains 'Campaign Bible'"` — filtered
    - `python3 gog_doc_pageless.py --dry-run --query "name contains 'HotD'"` — audit without changes

    **Why pageless:** campaign bibles are long continuous prose (15K-25K chars). The default PAGES mode inserts page breaks at ~3000 chars (1 page) and a "Page X of Y" footer at every page. This makes the bible hard to read in a browser (you scroll past multiple "Page 1 of 8" footers), impossible to copy as one block, and visually noisy. Pageless gives the reader one continuous scroll. Verified difference: opening the same doc in PAGELESS vs PAGES shows ~6 page breaks + 6 "Page X of Y" footers in PAGES mode; 0 page breaks + 0 footers in PAGELESS mode.

    **What NEVER breaks this rule:** the user may opt back into PAGES for a specific doc if they explicitly say so ("use pages mode for this one"); otherwise pageless is the default. The 4-mission HotD v3 + v4 campaign bibles are both pageless (verified 2026-08-19).

22. **No pre-baked starting scene in campaign bibles — HARD RULE (locked 2026-08-19, "remove the starting scene from the campaign, see how i did it in the google doc").** The bible does NOT include a fixed 4-option carousel (Dragon's Roar / Hand's Appeasement / Blood Tithe / Freeform). The AI DM narrates the opening situation from the bible's starting state and asks "What does Rhaenyra do?" freeform — the player issues a decree in their own words, or invokes any of the v3 fiscal levers (Temple Tithe / Iron Hearth Tax / Noble Scavage / Currency Debase). Verified 2026-08-19: the HotD v3 bible's Section 8 (Starting Scene) was deleted by the user, propagated to public wiki + LLM wiki + AI DM sim template; sim attempt 1 ended with **"What does Rhaenyra do?"** freeform prompt (no OPTION 1-4 carousel), 0 canon errors, 8 positives. **Trap:** agents that default to presenting a numbered option set on Turn 1 are over-railroading. The bible's starting state (CS 18%, Treasury 280 gp, PTR 75, Day 1 cascade) is the pressure that forces the player to act — the DM does NOT pre-bake the options for them. The 9-section shape's old Section 9 ("Starting Scene") is replaced with whatever the bible needs that is NOT a 4-option carousel — for HotD v3, the user's manual Google Doc used SETUP NOTES + v3 HARDNESS as the closing blocks.

23. **3-place sync from canonical Google Doc — HARD RULE (locked 2026-08-19, "see how i did it in the google doc and update the other two places").** When the user edits a Google Doc by hand and asks to propagate, the Google Doc is the source of truth — the agent's auto-generated copy is NEVER canonical. The 3 (sometimes 4) places for HotD bibles: (1) Google Doc, (2) public wiki page, (3) LLM wiki long-form source, (4) AI DM sim template. Full 5-step workflow + verified example + common pitfalls in `references/3-place-sync-from-google-doc.md`. The reference covers: fetch the doc as canonical, identify all places, propagate verbatim (using `re.sub` to swap the ` ```text ... ``` ` fence content in the wiki page), verify all places match (section headers, word counts, no leftover references to removed sections), and re-run the AI DM sim to confirm propagation works. **Trap:** if your OLD auto-generated bible contained canon errors the user removed (e.g. the v3 "fled into the night" invention), the propagation must catch and remove them — always `grep` for known errors before AND after.

## Synthesis-from-Existing-Bibles Workflow (added 2026-08-17)

When the user says "look at all my campaigns", "design X with the best aspects of my bibles", "make me an isekai / grimdark / hybrid of my existing campaigns", do NOT enumerate every file exhaustively. The user has 1000+ campaign bibles in `~/llm_wiki/wiki/sources/` and wants **synthesis**, not survey.

**Sample-then-synthesize (canonical 4-step):**

1. **List the named-character bibles** with `ls ~/llm_wiki/wiki/sources/ | grep -E 'campaign-' | sed -E 's/^[0-9-]+-//;s/-[a-f0-9]{8}\.md$/.md/' | sort -u`. Filter to "named-character / named-world" bibles (e.g. `veleria-iseki-reborn`, `aurelius-caesar-v3`, `sariel-valyria`, `aizen-bg3-v2`, `bumpkin-swordsman`, `nocturne-*`, `sariel-valyria`, `gaia-julia-*`, `alixiel-*`). Skip entry-per-NN logs, test fixtures, and documentation files.
2. **Sample 5–8 distinct bibles** that span different archetypes (isekai-prodigy, political-prince, grimdark-monk, masked-bastard, hidden-power-sorcerer). Read only the first 60–80 lines of each — the intro / setting / hook sections. Look for: the *best aspect* in each (the one paragraph that makes it shine).
3. **Extract the 5–7 best-aspect rows** into a small markdown table with columns `Best Aspect | Source`. This becomes the **visible synthesis anchor** in the brainstorming pitch.
4. **Pitch the hybrid** with: (a) the source-aspect table, (b) the new setting's hook in 1 sentence, (c) the protagonist concept with hidden-apex / mortal-anchor / ascension mechanics (per User Preferences #3), (d) the 3-way faction cold war (mirrors `bumpkin-swordsman` secrecy deadlock — works for grimdark), (e) **rank tables** if requested, (f) 3–5 alternative starting scenes for the user to pick, (g) 3–5 Q&A asks per the brainstorming HARD-GATE.

**Pitfall — don't:**

- ❌ Enumerate every file. The user wants the **distilled best**, not a survey.
- ❌ Read whole bibles. The first 60–80 lines have everything you need for synthesis.
- ❌ Skip the source-aspect table. It's the proof you actually looked, and it makes the user's mental model visible ("oh yes, the Veleria hidden-apex IS what I wanted").
- ❌ Ask "which bible is most important?" That's the user's call to make — your job is to present a synthesis and let them approve or redirect.
- ❌ Invent a single starting scene. The user almost always wants to **choose** the opener; offer 3–5 alternatives with one-line pros/cons.

**Verified working example (2026-08-17):**

> User ask: "Look at all my campaigns in LLM wiki and let's design an isekai world with all the best aspects. Ranks for warriors and mage types and noble ranks like landed knight / baron / count / marquis / duke / archduke / king / emperor / world emperor. Interesting starts. Fantasy and grimdark."

The pitch (presented in Slack thread `C0AUXSVFSA2/1786951500.855119`) returned a synthesis table, the hook in 30 words, a 3-way faction deadlock, full 10-rank Imperial Nobility table + Martial table + Mage table, 5 alternative starting scenes, and 5 Q&A asks. No bible file was written because the brainstorming HARD-GATE blocked it pending user Q&A answers. **This is the right shape** — present the design, wait for the user to confirm or adjust, then write.

### Companion trope source: canon isekai (added 2026-08-19)

When the user's ask involves isekai / reincarnation / hidden-power / magic-school specifically, **also sample `references/trope-bank-popular-isekai.md`** alongside the user's named-character bibles. The synthesis table gets TWO source columns: (1) "best aspect from your existing bibles" (per the workflow above) AND (2) "trope from canon isekai" with citation. The 2026-08-19 Demon-Queen-Reincarnated bible proved this is high-leverage — applying tropes #3 (Frieren melancholy), #9 (names as contracts), #11 (companions as clinic), #12 (antagonist is previous-life self) lifted the bible above a pure synthesis of the user's own prior art. Use both sources for isekai-class work; only the user's own bibles for non-isekai synthesis (e.g., grimdark political-thriller).

## Rank Table Pattern (added 2026-08-17)

When the user asks for "ranks for X, Y, Z" (warriors, mages, nobles, divine casters, thieves, assassins, etc.), design them as **parallel tracks** that overlap at the top:

| Pattern | Purpose |
|---|---|
| **3 parallel tables** (Nobility + Martial + Mage in one deliverable) | Lets the user mix & match — a landed knight who is also a Magister is mechanically legal and meaningful |
| **10–12 ranks per table** | Enough headroom for "landed knight → baron → ... → world emperor" progressions without becoming a codex |
| **Per-rank columns:** Rank title + Holding/Recognition + Distinctive Power + Capstone | Capstone = what changes at THAT rank (e.g., "may declare border skirmish without imperial warrant" for Count) |
| **Mythic / Empty apex tiers** | Last 1–2 ranks are gated behind player actions, not birth — "World Emperor" / "Veilwarden" / "Archmage of the Hidden Tower" |
| **Overlapping-but-distinct top tiers** | "King" in martial ≠ "King" in noble ≠ "Archmagus" in mage. Don't collapse them. |

**Concrete shape (worked example, 2026-08-17 hybrid isekai):**

> **Imperial Nobility:** Landed Knight → Baron → Viscount → Count → Marquis → Duke → Archduke → King (historical, none alive) → Emperor (reigning Empress Cassia XI) → World Emperor (mythic, last one 800 years ago)
> **Martial:** Squire → Knight-Errant → Knight of the Realm → Knight Commander → Paladin → High Paladin → Holy Marshal
> **Mage:** Apprentice → Adept → Magister → Archmagister → High Magus → Imperial Magus → Veilwarden (mythic, 3 alive)

The user can place a character at any rung in any table, and the tables can be combined (a Paladin-Archduke is a legal and rare combination).

## Multiple-Alternative-Starts Pattern (added 2026-08-17)

When designing an isekai / reincarnation / hidden-power campaign, offer **3–5 alternative starting scenes** for the user to choose from. Each one needs:

1. **A one-line title** ("The Heir in the Attic", "The Wrong Funeral", "The Bargain at the Crossroads", "The Summoning Wasn't For You", "The Game Designer Died at Her Desk")
2. **A 2–3 sentence scenario** (what the player wakes up to)
3. **The tone/implication** (intrigue thriller / grim / fish-out-of-water / race-against-time / meta)
4. **The implied protagonist self-knowledge** (do they remember their past life? Are they in danger? Is anyone hunting them already?)

**Verified starting-scene set (2026-08-17 hybrid isekai):** see *interesting starts* in the brainstorming pitch. Each one pivots on a different *first ten minutes* of the campaign — which determines the whole opening act's tone. The user picks one and the bible's Section 9 gets anchored to that opening.

**Anti-patterns:**

- ❌ Single starting scene with no alternatives. The user wants to **own the opening**.
- ❌ 7+ alternatives with no clear differentiation. Three is the floor, five is the ceiling.
- ❌ Alternative starts that imply different mechanics (e.g., one that secretly requires a different class). The hidden apex / mortal anchor should be the SAME across all starts; only the surface scenario differs.

## Workflow (mandatory order — brainstorming skill HARD-GATE applies)

**STOP — Read `~/.smartclaw/plugins/superpowers/skills/brainstorming/SKILL.md` BEFORE
any campaign work.** The brainstorming skill mandates that you present the design
in chat and get user approval BEFORE writing any code, wiki file, or campaign
bible content. This is not optional. The user has corrected agents who tried to
"design the campaign and ship it" without approval gates.

### HARD-GATE exception — "keep going" after timeouts / repeated nudges (added 2026-08-19)

If the session has produced 2+ provider timeouts OR the user has said "keep
going" / "continue" twice on the same thread, the HARD-GATE relaxes to
**default-lock mode**: pick the most-likely-correct default for each unanswered
Q&A (using the user's explicit thread-direction as the source), announce the
locks in chat, and proceed to write the bible. The user can rename anything
later — the file is staged at `~/llm_wiki/wiki/sources/`, not published. Do NOT
post another clarification menu after the user has already nudged twice.

**Verified 2026-08-19 (Demon-Queen-Reincarnated, Slack thread
`C0AUXSVFSA2/1786951500.855119`):** after 240s × 3 + 752s provider timeouts and
two "keep going" messages, re-asking blocked the work. Default-locking the
protagonist name, starting scene, age, and arc directions from the user's stated
direction (Mushoku Tensei cadence + magic school + reincarnated Demon Queen +
bladesinger/aberrant-mind + demons-as-sentient + old-magic-stronger) shipped a
working bible in one turn. The user can still rename anything — the file is
LLM-wiki staged, not committed, not pushed.

1. **Classify the request:** Architectural (new campaign bible, new IP), Bounded
   (edit existing bible), or Spike (quick feasibility check).
2. **Present the design in chat** with: class pivot, character pivot, target repo,
   endings shape, lore anchor, plus 3-5 Q&A asks the user must answer before
   implementation. Do NOT write the bible until the user approves the design.
   *(Skip this step under the HARD-GATE exception above.)*
3. **Once approved:** write the bible to the user's preferred staging path
   (default: `~/llm_wiki/wiki/sources/<date-or-name>.md` per the user's
   preference for LLM-wiki-first). No commit, no push, no public wiki edit until
   the user reviews the staged file and says "approved for public wiki."
4. **Public wiki step:** copy to `~/projects/worldai_wiki/queries/<name>.md`
   (or in-tree dev doc `wiki/campaigns/<Name>.md`), open a PR, post Slack thread
   update. NEVER skip the user-review gate.

## What Goes in the LLM-Wiki Staging File (NOT in the public wiki file)

The LLM wiki staging file at `~/llm_wiki/wiki/sources/<name>.md` is the **rich
draft** the user can paste into any AI chat to edit/customize before pasting into
WorldArchitect.AI. Include in it:

- The full 9-section bible (paste-ready)
- A **meta-prompt** at the top: "You are an expert narrative designer. The
  following is a campaign bible for WorldArchitect.AI. Edit as follows: [user
  changes]. Preserve everything else verbatim. Return the full edited bible,
  ready to paste into the 'Campaign description prompt' field."
- A **setup walkthrough** verified against the live worldarchitect.ai wizard
  (Step 1, Step 2, every checkbox, every field label — user-facing labels not
  static `#id` selectors)
- A **known-bugs-avoided** section: bugs the live wizard has that earlier docs
  would have hit (e.g., wizard uses `#wizard-campaign-title` not `#campaign-title`;
  `Use Default Fantasy World` is unchecked by default; `Mechanics (Jeff's
  Mechanical Precision)` must be checked for custom 5e mechanics to honor
  signature abilities like DragonsBond).

The public wiki file at `worldai_wiki/queries/<name>.md` should link to the LLM
wiki source for the long-form bible and include the meta-prompt + walkthrough
inline.

## Gemini Share-Link Sources (campaign drafts come from the user's Gemini sessions)

When the user pastes a `share.gemini.google/<id>` or `gemini.google.com/share/<id>`
URL as the source material, capture it with `~/.smartclaw/skills/read-gemini-share-link/SKILL.md`
(verified recipe as of 2026-08-13):

1. **Resolve short-URL 301 first:** `curl -sIL "https://share.gemini.google/<id>"`
   returns `location: https://gemini.google.com/share/<long-id>?skid=<uuid>`.
   Use the long URL with `?skid=...` in the browserclaw `--goto`.
2. **Decrypt Chrome cookies to `/tmp/google-cookies.json`** before capture.
   **The `--cookies` flag is REQUIRED by browserclaw's `cookies inject` CLI,
   not optional** (verified 2026-08-13 — calling `inject --goto ...` without
   `--cookies` exits with `error: the following arguments are required: --cookies`,
   even though the share is public and no actual cookie injection is needed).
   Recipe:
   `browserclaw cookies decrypt --db "$HOME/Library/Application Support/Google/Chrome/Default/Cookies" --output /tmp/google-cookies.json --domain-filter '%google.com%' --summary`
3. **Capture:** `browserclaw cookies inject --cookies /tmp/google-cookies.json --goto "<long-url>" --browser-channel chromium --headless --wait-after-load 15 --print-text 100000 > /tmp/gemini_full_<id>.txt`
4. **Verify capture:** `wc -c /tmp/gemini_full_<id>.txt` should be >30K chars for a
   multi-turn Gemini conversation. < 1K = "Link doesn't exist" (404 after 301).

## Long-Task Autonomous Mode (for multi-iter campaign builds)

When the user invokes `/cmux-goal` + `/ironclad` on a campaign-design task ("give yourself a really long northstar goal so you dont go off track and make sure it fires every 30 min"), or asks for a recurring northstar nudge, the durable-artifact pattern is:

1. **Bead** — `br create "GOAL: <task>" --type task --priority 1 --description "<ironclad summary>"` then `br update <id> --status in_progress`. Lock the work item to a discoverable ID.
2. **~/roadmap northstar** — write the full ironclad goal spec to `~/roadmap/<project-slug>/<mission>-goal-ironclad-<date>.md`. Mandatory contents: literal goal (the floor), 6-10 ironclad criteria with check command + external anchor + independent verifier, drift-warning section (concrete ways THIS session could drift), status table updated as work proceeds. See `references/session-2026-08-13-hotd-ashen-crown.md` for the 2026-08-13 HotD Ashen Crown example (10 criteria, all PASS except 1 deferred for cross-model review).
3. **Recurring nudge cron — use the `cronjob` tool, NOT `hermes cron create`.** The `cronjob(action='create', schedule='every 30m', name='<task>-northstar-nudge', deliver='slack:<chan>:<thread>', skills=['brainstorming'], prompt='<nudge prompt>')` is the right call. **`hermes cron create --prompt ...` exits with `unrecognized arguments: --prompt`** (verified 2026-08-13); the `--prompt` flag does not exist on that subcommand.
4. **Cron prompt shape** — re-read the goal file, post one-line `STEP=<X> STATE=<in-progress|done|blocked> NEXT=<action>` update. Do NOT re-do work; verify drift (on-disk state matches recorded state) and post the line.
5. **30-min cadence is the user default** — verified 2026-08-13 ("fires every 30 min"). Do not use 10m (too noisy, notification spam) or 60m (drift accumulates over a 6-hour work session).

**Anti-patterns:**
- ❌ Use `hermes cron create` CLI for new cron jobs — wrong tool for Hermes; use `cronjob(action='create')`. `hermes cron create --prompt` is a real failure mode.
- ❌ Skip the bead + ~/roadmap — the cron fires in fresh sessions with no context; without the durable artifact, the nudge is meaningless and the agent will redo work.
- ❌ Set the cron for "every 10m" or shorter — fires too often; 30m is the user's preferred cadence.
- ❌ Re-paste the full ironclad goal in the cron prompt — link to the goal file path; a 5KB prompt is fine but a 50KB prompt is not (cron token budget).
- ❌ Use `cmux send` to set the goal in another Claude session's composer — the goal-setting must happen in *this* session's runtime. `cmux-goal` skill is for Claude Code sessions inside cmux; this Hermes Slack session IS the runtime.

**When to use:** user explicitly invokes `/cmux-goal`, `/ironclad`, or says "give yourself a northstar goal", "fires every 30 min", "don't go off track", "hands-off mode", "finish the job". Also applies to any task the user describes as "long", "multi-step", or "multi-hour" where the agent could lose focus across many turns.

**When NOT to use:** small bounded tasks ("fix this typo", "rename this variable"). The cron overhead is not worth it.

## Pitfalls

- **Don't publish a campaign bible based on AI-generated source text
  without canon-verification.** Gemini share outputs and LLM drafts
  routinely invent plausible-sounding relationships, dates, and faction
  allegiances that the user will catch on live `/repro` test. The fix is
  a canon-check pass against actual Wikipedia summaries, the show's
  episode list, or the source novel's chapters — focused on parent/
  grandparent/child relationships, episode/chapter timing of deaths,
  loyalty flips, and marriage/legitimacy status. See User Preferences
  #12 for the full workflow and the verified HotD Ashen Crown failure
  modes (Corlys/Jace, Addam, Jace's death timing).
- **Don't write the bible without approval.** The brainstorming skill's HARD-GATE
  applies. Even "it's just a 9-section markdown file" — get the design approved in
  chat first. **Exception:** the *Workflow* section's HARD-GATE exception
  ("keep going" / "continue" after 2+ timeouts with on-record design direction
  already in the thread) applies — in that case lock defaults from the user's
  stated direction and ship the staged file. The file is staged at
  `~/llm_wiki/wiki/sources/`, not published; the user can rename anything.
- **Don't include an Endings Matrix, Canonical Ending, Final Verdict, or any pre-decided outcome section — period.** User explicitly stated on 2026-08-17 ("no and remove endings from the skill"): this is the skill default, not an override. The Rhaenyra HotD lock-in (2026-08-13, "let's stop doing these endings going forward, no endings") is now hard-coded — refuse to write an endings section unless the user explicitly contradicts this in a future session.
- **Don't date-prefix new LLM-wiki bible filenames** (user explicit 2026-08-13,
  "Q7: no date"). Use bare kebab-case names; grandfather the existing
  date-prefixed ones.
- **Don't pre-decide canon outcomes** (e.g., "Rhaenyra dies on Dragonstone"). The
  bible is a system; the player chooses the outcome. The starting state can be
  canonical (post-Season-3 finale) but the future is open.
- **Don't invent TV canon** that doesn't exist. The user corrects fabrications.
- **Don't use static `#id` selectors** in setup walkthroughs — wizard uses
  generated IDs (`#wizard-campaign-title`). Use user-facing labels.
- **Don't auto-merge to public wiki.** Even after LLM-wiki approval, the user
  reviews the public wiki file separately.
- **Don't forget the Freeform slot** in every Act's option carousel. Railroading
  is the #1 thing this user rejects.
- **Don't run browserclaw `cookies inject` without `--cookies`** even for public
  Gemini shares. The CLI rejects the call with `the following arguments are
  required: --cookies` (verified 2026-08-13). Decrypt cookies to
  `/tmp/google-cookies.json` first, even if the cookies bundle turns out to be
  unneeded.
- **Don't push an over-16k-char slimmed bible for an original-world campaign.** The worldarchitect.ai Custom Campaign wizard silently truncates or rejects bible prompts over ~16K characters for *original-world* bibles (verified 2026-08-14, 21,008-char attempt resulted in `SLIMMED_BIBLE_LEN=21008` over-limit, wizard test failure). Slim iteratively with `awk 'BEGIN{total=0}{total+=length($0)+1}END{print total}'` (CHAR count, NOT `wc -c` byte count) after each edit until under 16K. Goal range 14k-15.5K for original-world. **For IP-anchored bibles (HotD, BG3, Naruto, etc.) the user has explicitly relaxed this limit** (2026-08-18, "there really is no cap, so dont worry, use whatver words you need"); the working ceiling is 3,000 words for the paste-block per User Pref #13. See User Preferences #13 + the slim-pass iteration playbook in the User Preferences section.
- **Don't fall back to "headless Firebase Auth popup blocked" before trying Aside first (added 2026-08-22).** Aside has the user's real Chrome session + working CDP, so the Google account chooser + OAuth popup round-trip complete normally — verified 2026-08-22 for the full WA wizard → campaign creation → game-state capture flow. Per v1.7.2 changelog: Aside is the *primary* path for live verification, not a fallback. Reserve in-process AI DM simulation (claudem) for *conformance verification* (canon-clean without launching the wizard), not *live verification*.
- **Don't expect WA Firebase Auth state in cookies (added 2026-08-22).** WA's auth lives in IndexedDB (`firebaseLocalStorageDb`), not cookies. `browserclaw cookies decrypt` only reads the SQLite cookie DB. Pre-flight check before any cookie-inject path: `ls "$HOME/Library/Application Support/Google/Chrome/Default/IndexedDB/" | grep -iE "worldarchitect|mvp-site"` — if no `https_worldarchitect.ai_0.indexeddb.leveldb`, the user has NOT visited WA under that Chrome account yet. Don't waste a Playwright launch cycle on a profile with no WA IndexedDB; the user must visit WA in their real Chrome first to populate the Firebase session.
- **Don't omit the CANON-PRIORITY prompt** in TV-show-anchored bibles.
  Without the explicit "TV show > older TV > book" directive, AI DMs
  silently substitute book canon (e.g., GRRM's *Fire & Blood*) for TV
  canon even when the bible elsewhere says "show-anchor." Verified
  failure: AI DM narrated "Corlys is Jace's father" until the priority
  prompt was added. See User Preferences #14.
- **Don't pre-bake a fixed 4-option starting scene in the bible** (User Pref #22, locked 2026-08-19). The AI DM narrates the opening and asks freeform "What does Rhaenyra do?" — agents that default to numbered option sets are over-railroading.
- **Don't promote the agent's auto-generated copy to canonical when the user edited a Google Doc** (User Pref #23, locked 2026-08-19). The Google Doc is the source of truth; the other 2-3 places (public wiki + LLM wiki + AI DM sim) are derived. Always fetch the doc first, then propagate verbatim. Full 5-step workflow in `references/3-place-sync-from-google-doc.md`.
- **Don't block on a mid-task user redirect — answer + queue (added 2026-08-22).** When the user issues a clarifying / summarizing question mid-tool-execution (e.g., "Summarize what we decided for the world here" delivered while a `patch` or `terminal` call is in flight), the right response is to **finish the current tool batch, deliver the asked-for answer in the SAME turn, and queue the rest of the work as "Next (background)" rather than blocking on it.** Verified 2026-08-22 (Demon-Queen-Reincarnated v2 trim): user asked "Summarize what we decided for the world here" while the slim-trim patch loop was running. Pattern that worked: complete the in-flight trim → deliver a Slack-native concise world summary (3-way cold war table + starting NPCs + rank tables + canon priorities + 5 hooks + Act III requirement) → label the unfinished Google-Doc-create + /web-advice-retry as "Next (background)" in the same reply → continue those in the next turn. Pattern that fails: stopping the trim to answer, then re-asking "what else should I do?" — the user already told you ("update the google doc and the llm wiki entry"); they just want to see the world summary first. The "summarize" redirect is **not** a cancellation of the queued work; treat it as a read-out request.

## No-Endings PITFALL (2026-08-17 hard rule)

The default bible does **not** include: Ending Determinator, Canonical Ending, Final Verdict, "What ending do you unlock?" UI, or any pre-decided outcome section. The skill default for any new bible is to ship **§10 = Campaign Continuity Hooks only** — 3+ unresolved threads the AI DM picks up between Acts.

If you catch yourself about to write one of these sections, STOP and remove it. The user confirmed the override on 2026-08-17 ("no and remove endings from the skill") after previously relaxing it for Rhaenyra HotD on 2026-08-13 — the 2026-08-17 statement promotes the override to the skill default across all new bibles.

Exception (rare, requires user-confirmation in the session): a bible may include an ending-shaped section if the user explicitly types "include the ending" or equivalent. Do not infer this from absence; do not assume it from prior session patterns.

## No-Mortal-Anchor PITFALL (2026-08-17 hard rule)

The default bible does **not** include: a Mortal Anchor NPC, a Loyalty cascade mechanic, a Loyalty matrix on a single named anchor NPC, or any "ditchbond" mechanic.

The skill default for any new bible is to ship **Quad-Pillar Paranoia** as the only isolation-tension carrier (see User Preferences #3 below and the HotD Ashen Crown pattern). The 2026-08-13 Rhaenyra HotD override ("we dont need mortal anchor") was used in that campaign and is now skill default across all new bibles.

Exception (rare, requires user-confirmation in the session): a bible may include a Mortal Anchor if the user explicitly types "add the mortal anchor" or equivalent, AND the bible is for a character line where the anchor pattern fits (Visenya divine line, deep-grimdark-with-protégé setup, etc.). Do not infer this from absence; do not assume it from prior session patterns. **The Visenya divine line still uses a Mortal Anchor** as a deliberate exception — keep the override, but make it explicit per-campaign.

Side effect of this rule: the Verification Checklist "Mortal Anchor mechanic explicitly named with cascade threshold" line is **replaced** by the conditional "If Mortal Anchor mechanic is included (user-confirmed per-session), it is named with cascade threshold; otherwise Quad-Pillar Paranoia stat is the only isolation-tension carrier." If you find yourself writing a Mortality-Cascade NPC into a default bible, you have broken the rule.

## Verification Before Claiming "Done"

- [ ] Brainstorming design presented in chat and user approved (with Q&A answers
      recorded)
- [ ] Bible file written to user's preferred staging path
- [ ] File passes `wc -c` (≥ 25K chars for a 9-section bible)
- [ ] User-facing walkthrough references live wizard field labels, not static IDs
- [ ] No Endings Matrix / Canonical Ending / Final Verdict section anywhere
- [ ] Every Act's option carousel has a Freeform slot
- [ ] If Mortal Anchor mechanic is included (user-confirmed per-session, NOT default), it is named with cascade threshold; otherwise Quad-Pillar Paranoia stat is the only isolation-tension carrier
- [ ] Lore anchor points to a specific canonical moment (show-finale-or-book-chapter)
- [ ] No commit, no push, no public-wiki edit until user reviews staged file

## Cross-References

- `~/.smartclaw/plugins/superpowers/skills/brainstorming/SKILL.md` — HARD-GATE: present
  design in chat before any implementation
- `~/.smartclaw/skills/read-gemini-share-link/SKILL.md` — capture the Gemini source
  conversation that contains the user's campaign draft (user-owned; flag for
  curator-adoption if updated)
- `~/llm_wiki/wiki/sources/` — staging path for LLM-editable bibles
- `~/projects/worldai_wiki/queries/` — public-facing wiki path (post-approval)
- `~/projects/worldarchitect.ai/wiki/campaigns/<Name>.md` — in-tree dev doc
  mirror (for the worldarchitect.ai repo's internal wiki nav)
- `references/2026-08-14-no-hardcoded-preset-issue-templates.md` — canonical
  issue templates for filing worldarchitect.ai player-feedback as engine-feature
  issues. Use the framing from rule #11 (no hardcoded presets — engine exposes
  primitive, player declares rule) and the 6-issue body shape when filing
  similar work in the future.
- `references/session-2026-08-13-hotd-ashen-crown-canon-corrections.md` —
  documented canon errors Gemini introduced into the HotD Ashen Crown bible
  that the user caught on live `/repro` test (Corlys–Jace relationship,
  Addam-as-traitor, Jace death timing, Lucerys vs Jace grief). Pair with
  User Preferences #12 (cross-check canon before publishing). Use as the
  worked example for verifying any AI-source-mediated campaign bible.
- `references/session-2026-08-18-hotd-ashen-crown-v4-tv-canon-verified.md` —
  2026-08-18 HotD Ashen Crown v4 TV-canon-verified session: 8 v4
  corrections (Addam/Aegon/Aemond/Ormund/Jace-timing/High-Septon/
  lost-two-sons/Shepherd), Wikipedia S3 episode list as canonical anchor,
  5-tool-call parallel dispatch (wiki-ingest + slim + Google Doc + AI DM
  sim + commit/push), explicit user directives verbatim ("follow the TV
  show", "use whatver words you need", "do it in parallel"), and the
  durable lesson that "verified 16k cap" was wrong for IP-anchored bibles.
  Pair with User Preferences #13 (relaxed cap for IP-anchored),
  #14 (expanded CANON-PRIORITY rule), and the new #16 (anchor against
  source-medium episode list, not LLM recall) + #17 (TV-vs-book
  wiki-ingest subfolder split) rules. Use when the user asks to
  rebuild an IP-anchored bible against a recent source-medium release
  where LLM recall may be stale.
- `references/session-2026-08-14-hotd-slimming-w16k.md` — 2026-08-14
  slimming pass: 21,008 → 15,837 chars, in-process AI DM simulation
  harness at `/tmp/wa_sim_v2.py` (PASS on attempt 1 with 0 canon errors
  + 8/8 structural checks), detector regex against known canon errors,
  Firebase Auth popup-blocks-headless-Chromium failure mode. Pair with
  User Preferences #13 (slim-to-16k), #14 (canon-priority prompt),
  #15 (iterate-to-conformance pattern). Use when the user asks to
  paste a slim bible into the wizard or to iterate the bible against
  the live WA instance.
- `references/3-place-sync-from-google-doc.md` — **added 2026-08-19**.
  The 5-step workflow for propagating a canonical Google Doc's manual
  edits to the public wiki + LLM wiki + AI DM sim template. Use when
  the user says "see how I did it in the Google Doc and update the
  other two places." Pair with User Preferences #22 (no pre-baked
  starting scene) and #23 (3-place sync HARD RULE). Includes the
  verified 2026-08-19 Ashen Crown v3 no-starting-scene propagation
  (Google Doc → public wiki PR #9 commit `1ad5858` → LLM wiki commit
  `208053770` → AI DM sim attempt 1 with 0 canon errors + 8 positives).
- `references/synthesis-from-existing-bibles-patterns.md` — bank of
  reusable "best aspect" patterns extracted from the user's named-character
  bibles (Veleria Iseki Reborn, Sylphina von Silford, Vaelen / Rust-Bound
  Blade, Sariel Valyria, Aurelius Caesar, Sosuke Aizen, Nocticula). Use
  when the user says "look at all my campaigns and design X with the best
  aspects" — sample these patterns, build the source-aspect synthesis table
  for the brainstorming pitch, and pull from 3+ sources per major mechanic.
  Includes tone-slider guide (Warhammer / ASOIAF / Berserk / Witcher) and
  common failure modes (cloning one source / conflicting hidden apex /
  wrong number of factions / dropped mortal anchor).
- `references/trope-bank-popular-isekai.md` — 12 trope patterns + 3
  anti-patterns mined from canon isekai / reincarnation series (Mushoku
  Tensei, Frieren, Slime, TBATE, Re:Zero, Bookworm, Spider, Overlord,
  Shield Hero, Tanya). Use when the user asks for an isekai / reincarnation
  / hidden-power / magic-school campaign — sample the patterns that match,
  cite the source URL, apply to the bible's mechanics + narrative beats.
  Includes cross-pattern composition rules (#2+#7, #3+#12, #5+#6+#9) and
  the three anti-patterns to reject (tier-list monoculture, harem-by-default,
  "Demon King dies → show ends"). Verified 2026-08-19 via Wikipedia
  summaries; re-verify after every 2 new bibles.
- `references/op-protagonist-tension-devices.md` — **added 2026-08-22**.
  Six canonical "Strongest in the Room" narrative devices for OP-protagonist
  campaigns (Jobless-MT style). Synthesized from 10-series Wikipedia-cited
  research. Use when the user asks for a magic genius at age 12, "the
  strongest alive," demon-emperor-reincarnated-style protagonist, or names
  MT/Slime/Tanya/Overlord as reference. Includes composition recipes
  (Devices 3+4+6 for magic-school, 2+5 for Overlord, 1+4 for Tanya), 4-row
  Cheat Inventory template, design heuristics, and anti-patterns.
  Pair with v1.6.0 §3 Cheat Inventory sub-block and the Isekai
  7-element coverage audit checklist.
- `references/op-protagonist-tension-devices-user-8.md` — **added 2026-08-22 (v1.7.0)**.
  The user's 8-device OOB framework for keeping OP protagonists tense.
  Companion to `op-protagonist-tension-devices.md` (the canon-isekai 6-device
  reference). The 8-device framework adds Escalate Scale, Shift From Combat,
  Protect Weaker Allies, Counters/Weaknesses, Information/Mystery Gaps, and
  Time Pressure — devices the canon-isekai 6-device list does not cover.
  Each device has a verified-working shape from the Demon-Emperor-Reincarnated
  session, a Bible-section binding (which § of the bible should carry the
  device), and an anti-pattern. Includes a pre-publish coverage audit
  checklist (verify all 8 are addressed before claiming done). Use this
  reference INSTEAD of the 6-device reference when the user explicitly
  supplies the 8-device list (the canonical signal is the user posting
  "Typical ways isekai stories keep tension when the protagonist is OP"
  with the numbered taxonomy).
- `references/session-2026-08-22-demon-queen-reincarnated-v2-trim.md` —
  2026-08-22 v2 trim session: 15,977 → 12,079 chars (2,885 → 2,013 words)
  across 6 targeted patches, mid-task user redirect handled (summarize
  delivered in same turn, rest queued as "Next (background)"), `gog drive
  search` gap surfaced (4 keyword variants for new doc search-then-create),
  /web-advice ladder state at session end. Pair with v1.5.1 changelog and
  the slim-to-1k-2k subsection in the slim-pass iteration playbook. Use
  when the user requests a 1k-2k word ceiling or asks for a world summary
  mid-trim-loop.
- `references/session-2026-08-22-isekai-demon-emperor-live-test.md` —
  2026-08-22 Isekai Demon Emperor live-test: the WA campaign was successfully
  created under jleechan@gmail.com via Aside (`aside "<natural language>"`),
  full game state verified (Level 1 / HP 0/0 / AC 10 / attrs all 10 / Unarmed Strike +2).
  Side lesson: don't fall back to "headless Firebase Auth popup blocked" before
  trying Aside first — the v1.7.2 changelog rule. Also: WA auth lives in IndexedDB,
  not cookies — pre-flight check the WA IndexedDB at
  `~/Library/Application Support/Google/Chrome/Default/IndexedDB/https_worldarchitect.ai_0.indexeddb.leveldb`
  before attempting any cookie-inject path. Pair with v1.7.2 changelog and
  `references/wa-live-test-recipe.md`. Use when the user asks to drive the WA
  wizard via /browser for any account, especially when they say "I signed in to
  Chrome with <account>, should be cookies."
  2026-08-22 Quiet War Drive-doc audit + ≤2k-word multi-surface trim
  (single atomic rewrite: Drive doc body via `gog docs write --replace
  --markdown` + wiki slim commit `79eaae0d6` + `git push origin main` +
  `drive search "name = '<exact title>'"` parent verification + Drive
  folder `1ZLC7LXj2goOP30e395647XO1PChGhDgO` confirm). Pattern: `/DS` on
  a **Google Doc target** produced 3 cut candidates (Hook 1 dup, doc over
  ceiling, no link-back) + 4 thermo findings (including the canonical
  §6 mega-roster → 4-column table judo). End state: Drive doc 1,777
  words (was 2,143), wiki slim 1,926 words (was 2,262), both under
  ≤2,000 ceiling. Pair with v1.5.1 changelog and the multi-surface
  sync recipe in this file's references. Use when the user invokes
  `/DS` or `/document-standards` on a campaign Google Doc URL, or asks
  to trim a campaign bible that lives on Drive + wiki in lockstep.