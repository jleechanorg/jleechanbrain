---
name: worldai-wiki-publishing
description: "Publish WorldAI campaign templates to the right wiki."
version: 1.5.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [worldai, wiki, campaign-template, worldai_wiki, publishing, public-wiki]
    related_skills: [llm-wiki, download-campaign, web-page-screenshots, finish-the-job, github-pr-workflow]
---

# Publishing to the WorldArchitect.AI Wiki Ecosystem

The user has **three** distinct wikis for the WorldArchitect.AI project. Picking the wrong one is a recurring trap: writing to the in-tree `wiki/` directory of the `worldarchitect.ai` code repo feels right because the path lives next to the code, but **players never see that wiki**. The public-facing surface that ships through the worldarchitect.ai nav link is a separate GitHub repo.

## When to Use

- User asks to put a campaign template (House of the Dragon, BG3, Naruto, GoT, custom D&D 5e) on the wiki
- User says "publish this to the worldai wiki" / "add it to worldai_wiki" / "make a wiki page players can read"
- User asks for instructions people can follow to set up a custom campaign
- User mentions a setting / IP / genre that has a campaign-bible precedent in the existing 9-section structure (see Phase 2 below)
- The deliverable should be **player-shareable** (vs. internal dev docs)

Do NOT use this skill for:

- Downloading existing WA campaigns from Firestore → use `download-campaign` (read-side)
- Editing the **in-tree** developer docs (D&D 5e mechanics, repro procedures, engineering concepts) in `worldarchitect.ai/wiki/` — that wiki is internal-only; no public-facing nav points to it
- Generic Karpathy-style LLM wikis that aren't about WorldArchitect.AI → use `llm-wiki`

## The Three Wiki Homes (Decision Table)

| Home | Audience | Path | When to write |
|---|---|---|---|
| **A. Public player-facing wiki** (THE one players see) | Players + external devs | `github.com/jleechanorg/worldai_wiki` — clone to `~/wawiki` or `/tmp/wawiki.*` | **Default for any "wiki page for players" ask.** Includes `entities/`, `concepts/`, `queries/`, `raw/`, `SCHEMA.md`, `index.md`, `log.md`. |
| **B. In-tree developer docs** (HIDDEN from players) | WorldAI engineers | `${HOME}/projects/worldarchitect.ai/wiki/` | Only when the user is writing D&D mechanics reference, repro procedures, engineering architecture notes, or other internal team material. **NOT for player content.** |
| **C. Private Karpathy KB** (the user's compound notes) | User's personal research / cross-session memory | `~/llm_wiki/wiki/` | Background source material, synthesis of multiple WA campaigns, meta-prompt engineering notes, anything that's personal KB not destined for the public wiki. |

**How to identify which one the user wants:**

- "Show this wiki page to people and let them play the campaign" → **A**
- "Add it to the worldai wiki" / "the wiki people see" / "the wiki nav link" → **A**
- "Add to our internal docs" / "update the developer reference" → **B**
- "Save it for future sessions" / "add to my LLM wiki" / "ingest this" → **C**
- **When ambiguous: write to A (public)** — that's the surface players see; B is for engineers; C is for the user's private KB. If unsure, ask one short clarifying question; don't guess and ship to B.

**Critical diagnostic for A vs B confusion:** the `worldarchitect.ai` website's "Knowledge base / wiki" nav link points to `https://github.com/jleechanorg/worldai_wiki` (set in `mvp_site/frontend_v1/js/ui-utils.js:12` `WORLDAI_WIKI_URL`). Verify with:

```bash
rg -n 'WORLDAI_WIKI_URL' ${HOME}/projects/worldarchitect.ai/mvp_site/frontend_v1/js/
```

If the user says "the WorldAI wiki" without specifying, this is the one they mean.

## Phase 0 — Sanity check the repo exists

```bash
# Clone the public wiki if not already local
test -d ~/wawiki && cd ~/wawiki || (cd /tmp && git clone --depth=1 https://github.com/jleechanorg/worldai_wiki.git wawiki)
cd ~/wawiki  # or /tmp/wawiki
cat SCHEMA.md | head -100
```

Read the schema's **Domain**, **Tag Taxonomy**, **Type Taxonomy**, and **Frontmatter** requirements BEFORE writing anything. Closed taxonomies — no ad-hoc tags/types.

## Phase 1 — Pick the right directory

| Page type | Directory | Frontmatter `type:` | Common tags |
|---|---|---|---|
| Campaign template with pasteable bible | `queries/` | `query` | `[wa-campaign, wa-tutorial]` (+ `[wa-character]` if it ships a PC) |
| Concept page (system explainer) | `concepts/` | `concept` | `[wa-campaign, wa-tutorial]` for design guides |
| Entity page (a character, place, faction) | `entities/` | `entity` | `[wa-character, wa-persona]` for characters |
| Raw source mirror | `raw/` | (raw frontmatter; `source_url:`, `ingested:`, `sha256:`) | (raw sources are immutable) |

For a campaign template with setup instructions, the right home is **a single `queries/<slug>-campaign.md` page** with everything in it: intro, paste-ready bible (a single clean `\`\`\`text` code block — see Pitfall #16), and the wizard walkthrough. The wiki's `concepts/CampaignDesign.md` already explains generic campaign design — your page should be the **specific campaign's** setup, not a duplicate.

### Page structure for player-shareable campaigns (Quick Setup + More Details)

Jeffrey's preferred layout for any player-facing campaign template (verified across two revisions on PR #7, 2026-08-04 → 2026-08-05). When the user asks for a campaign template they intend to share with players, default to this shape:

```
# <Campaign Title> — Custom Campaign Template

A ready-to-play **<genre>** solo campaign for WorldArchitect.AI. ...

This page is split into two parts:

1. **[Quick Setup](#1-quick-setup)** — three minutes. Sign in, paste, play.
2. **[More Details](#2-more-details)** — character customization, LLM editing, mechanics deep-dive, troubleshooting, screenshots.

If you want the paste-ready bible and step-by-step launch, jump to Quick Setup.
If you want to customize the character, understand the mechanics, or troubleshoot, scroll to More Details.

---

## 1. Quick Setup
**What you're playing** — one-paragraph hook + setting + tone + mechanics summary.
**Three minutes to launch** — numbered steps with a paste-this table (no long annotations).
### Copy-Paste Bible — the full 9-section bible in a SINGLE ```text``` code block. No BEGIN/END markers, no divider lines, no decoration inside the fence. The instruction sentence ("copy the entire block below into <field>") lives ABOVE the fence as regular markdown.

---

## 2. More Details
### Customize the character — the field-by-field customization guide (gender, age, dragon name, parent, look, starting relationship).
### Editing the bible with an LLM (before you paste) — meta-prompt for AI-assisted customization.
### Full setup walkthrough (every form field, every checkbox) — annotated reference version of Quick Setup.
### What to expect on your first session.
### Class & mechanics deep-dive.
### Troubleshooting.
### Related — wiki-internal links (MUST resolve; see Pitfall #11). Every outbound link must be self-contained within `worldai_wiki` — see Pitfall #21.
```

**Why this structure:** Jeffrey said "let's make two main sections in the guide — 1. just quick setup and what to copy and paste, 2. more details/info" verbatim, 2026-08-05. The Quick Setup section is for a player who wants to launch in 3 minutes. The More Details section is for a player who wants to customize, troubleshoot, or understand the mechanics. Keep both; don't fold them into one. The Provenance / sibling-repo-paths subsection was dropped after Jeffrey's OOB on 2026-08-05 ("make sure this wiki is self contained and doesnt reference other repos") — see Pitfall #21.

## Phase 2 — Write the page

Page requirements (enforced by `scripts/lint_wikilinks.py`):

1. **Frontmatter** with `title`, `created`, `updated`, `type`, `tags`. `sources` if you reference raw mirrors.
2. **Filename**: lowercase, hyphens, no spaces (`house-of-the-dragon-campaign.md`).
3. **Markdown links only** (`[Display Text](path/Page.md)`) — **NO `[[wikilinks]]`**. GitHub does not render Obsidian-style links; they show as literal `[[brackets]]`.
4. **≥ 2 outbound links** to other wiki pages (e.g. `[CampaignDesign](../concepts/CampaignDesign.md)`).
5. **No ad-hoc tags** — only use tags from `SCHEMA.md`'s taxonomy. Add to the taxonomy first if you need a new one.
6. **Sources section** at the bottom if you reference any raw mirrors.

The 9-section Campaign Bible structure is the reusable skeleton for any campaign template:

1. Campaign Intro (power-fantasy hook + world twist + era)
2. Character Personality (MBTI hinge + sensory signature + Core Compulsion Mechanic + 3 inner-monologue seeds)
3. Character Class (gestalt or renamed class + signature game-breaking ability)
4. Assets & Retinue (starting rank, wealth, Panoply, 3 starting NPCs)
5. Family (the Viper's Nest — 2 Titan parents + 4 older siblings)
6. Factions (10 noble houses + 10 friendly + 10 antagonistic)
7. World Lore (timeline with Divergence Point, magic system, current crisis, 3 escalating arcs)
8. Gazetteer & Mechanics (4 stages + 2 custom systems + 8-entry relic loot table)
9. Starting Scene (atmosphere + A/B/C first decision)

The wiki's `concepts/CampaignDesign.md` already references the "v4 Campaign Bible template" Google Doc for the generic design — your campaign-specific page should slot in as an example, not duplicate.

## Phase 3 — Verify the wizard live BEFORE publishing

The wiki instructions will be useless if they don't match the live worldarchitect.ai UI. Before opening the PR, **verify the wizard end-to-end in a real browser** — both the field labels and the checkbox defaults.

**Source-of-truth order (verified 2026-08-05):** the wizard JS code is the source of truth for live defaults; the Step 2 review screen is NOT (it displays only "Narrative" under AI Personalities, hiding Mechanics/Companions state). The pattern of mistakes this skill previously encoded ("Mechanics unchecked — check this", "Use Default World unchecked") was the agent guessing from prose descriptions and getting it wrong three times in a row.

```
1. Read mvp_site/frontend_v1/js/campaign-wizard.js (or vite/react equivalent) — find the
   defaultChecked= for every checkbox and the initial value of every field.
2. Boot the local Flask test-mode server (TESTING_AUTH_BYPASS=*** ./run_local_server.sh
   --force-default-port) and probe live with Playwright — verify what the rendered DOM
   actually has at boot.
3. Drive the wizard with the full bible pasted (see templates/walkthrough-verify.py).
4. Capture screenshots at every step (Step 1 filled + Step 2 review).
5. Document user-facing labels in the wiki — they're stable; internal IDs are not.
```

If you skip step 1-2 and ship prose-only instructions, you will publish wrong checkbox defaults. PR #7 had this exact bug twice (commits bcafc06 had the right defaults in code, a80f846 inverted them after the live Playwright probe — the live probe is what flipped the truth).

### Two wizards exist in the repo — V1 (Flask, port 8081) vs V2 (React, port 3002)

`${HOME}/projects/worldarchitect.ai/mvp_site/tests/test_v1_vs_v2_campaign_comparison.py` documents a hypothetical V2 server on port 3002, but **there is no V2 in this repo** — `mvp_site/static/v2/index.html` is a 779-byte placeholder stub (no JS, no CSS, no routes). The live site is served by Flask from `mvp_site/frontend_v1/` (5.4MB). The V2 deletion question is a separate cleanup PR (see references/v1-vs-v2-misdiagnosis.md for the full analysis).

If you see the V1/V2 test file, do NOT assume V2 exists. Treat it as legacy test scaffolding that references a separate (likely Cloud Run or React frontend repo) project — not a deliverable in this repo.

### Live-id reality check (V1 Flask wizard, Aug 2026 prod)

| Static `index.html` says… | Live DOM actually is… |
|---|---|
| `id="campaign-title"` | `id="wizard-campaign-title"` |
| `id="character-input"` | `id="wizard-character-input"` |
| `id="setting-input"` | `id="wizard-setting-input"` |
| `id="description-input"` | `id="wizard-description-input"` |
| `id="use-default-world"` | `id="use-default-world"` (real id; static html is stale) |
| `id="prompt-narrative"` | `id="prompt-narrative"` (real id) |
| `id="prompt-mechanics"` | `id="prompt-mechanics"` (real id) |
| `id="generate-companions"` | `id="generate-companions"` (real id) |
| `id="toggle-description"` | `id="wizard-toggle-description"` |
| (no static id) | `id="wizard-next"` |
| (no static id) | `id="wizard-prev"` |
| (no static id) | `id="launch-campaign"` |

The static `mvp_site/frontend_v1/index.html` is **partially stale** — the deployed wizard is JS-built and uses slightly different IDs (`wizard-` prefix on most inputs). Use **user-facing labels** in the wiki (they're stable across versions), not internal IDs.

### Live checkbox defaults — V1 Flask wizard (verified 2026-08-05)

| Wizard DOM id | User-facing label | Default | Action for HotD-style templates |
|---|---|---|---|
| `#prompt-narrative` | Narrative (Jeff's Narrative Flair) | **checked** | Leave checked |
| `#prompt-mechanics` | Mechanics (Jeff's Mechanical Precision) | **checked** | Leave checked — wizard ships it on by default, NO action needed |
| `#generate-companions` | Generate starting Companions | **checked** | **OPTIONAL: uncheck** for a tighter cast if the bible already lists starting companions |
| `#use-default-world` | Use Default Fantasy World (Celestial Wars/Assiah setting) | **checked** | **UNCHECK this** for ASOIAF/HotD/non-Assiah templates |
| `#edit-narrative`, `#edit-mechanics`, `#edit-companions`, `#edit-default-world` | Sub-toggles inside the Edit modal | hidden by default | Not user-facing in the basic wizard flow; don't reference in the wiki |

**Why these defaults are dangerous to guess:** the prior version of this skill encoded the inverse ("Mechanics unchecked — check this", "Use Default World unchecked") and that wrong advice shipped to PR #7 twice. The trap is that "checked" feels wrong for a checkbox that asks "Enable this", but the wizard defaults to ON for ALL FOUR — including the one whose name implies it should be OFF. Don't guess; probe live.

**Step 2 review screen displays** only **Narrative** under "AI Personalities:" — Mechanics and Companions are stored in the campaign config but not surfaced in the visible summary. "Options: None selected" is the default Step 2 readout, even when Mechanics is checked. Don't claim the Step 2 screen proves Mechanics carried through; trust the wizard code, not the review screen text.

### Live behavior to verify in the wiki

- The "Campaign description prompt" field is **collapsed by default** — user must click the Expand toggle to see it
- The `wizard-description-input` textarea accepts the full bible (verified up to ~15,000 chars)
- Step 2 "Ready to Launch!" review screen is editable inline (click any field to edit, click outside to save, Escape to cancel)
- The wizard is **2 steps** (Choose Type → Launch), NOT 3

### Local TESTING_AUTH_BYPASS drive — the canonical path

When you can't sign in with a real Google account (or don't want to depend on one), use the local Flask server in TESTING_AUTH_BYPASS mode. This is the path the skill used to verify the wiki walkthrough end-to-end on 2026-08-05 (see references/live-wizard-defaults.md and templates/walkthrough-verify.py).

```bash
# 1. Start the local server (boots Flask on :8081 + MCP on :8001 + classifier warmup, ~30s)
mkdir -p /tmp/worldai-hotd-smoke
TESTING_AUTH_BYPASS=true bash ./run_local_server.sh --force-default-port --no-log-stream > /tmp/worldai-hotd-smoke/server.log 2>&1 &

# 2. Wait for it to be ready (HTTP 200 on /)
for i in {1..30}; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://localhost:8081/?test_mode=true&test_user_id=test-user-123" 2>/dev/null)
  [ "$code" = "200" ] && break
  sleep 2
done

# 3. Drive with Playwright (see templates/walkthrough-verify.py for the full script)
python3 /tmp/worldai-hotd-smoke/walkthrough-verify.py

# 4. Stop the server cleanly
kill $(cat /tmp/worldarchitect.ai/main/flask_backend.pid) $(cat /tmp/worldarchitect.ai/main/mcp_server.pid)
```

Captured screenshots land at `/tmp/worldai-hotd-smoke/screenshots/walkthrough_step1_filled.png` and `walkthrough_step2_review.png` ready to embed in Slack with `MEDIA:/tmp/worldai-hotd-smoke/screenshots/walkthrough_step2_review.png`.

If the test-mode server keeps port 8081 alive but the wizard doesn't load, you're probably hitting a stale `.pyc` cache — kill the Flask PID and re-run.

## Phase 4 — Update index + log + run lint

```bash
cd ~/wawiki  # or wherever the clone is
# Insert one-line entry in index.md under the appropriate section
# Append a ## [YYYY-MM-DD] create | <page title> entry to log.md

# Lint — both must pass
python3 scripts/lint_wikilinks.py          # exit 0 = pass
python3 -m pytest tests/test_wikilink_lint.py -q   # 12 passed = pass
```

`tests/test_http_links.py` will report the new page as 404 if it hasn't been pushed to origin yet — that's a transient false-positive, not a failure to act on. It resolves after merge.

## Phase 5 — Open a PR (NOT push to main)

The repo enforces no-force-push-to-main. Always:

```bash
cd ~/wawiki
git checkout -B feat/<short-slug> origin/main
git add queries/<new-page>.md queries/images/<slug>/ index.md log.md
git -c commit.gpgsign=false commit -F - <<'COMMIT_EOF'
claude/minimax-M3: <one-line summary>

<3-5 bullet body explaining what + why + live-site verification result>
COMMIT_EOF
git push -u origin feat/<short-slug>
gh pr create --base main --head feat/<short-slug> \
  --title 'wiki: <short title>' \
  --body-file /tmp/pr_body.md
```

**Attach the Step 2 screenshot to the wiki repo** (not just the PR description) so it renders inline when the page is viewed on github.com blob view. Image path: `queries/images/<slug>/step2-launch-desktop.png` — reference via `![caption](images/<slug>/step2-launch-desktop.png)` (relative, no absolute paths).

## Phase 6 — Update sibling repos

The user usually wants **all three** wiki homes updated, not just the public one:

1. **Public player-facing wiki** (A) — PR via Phase 5 above
2. **In-tree developer docs** (B) — local commit in `worldarchitect.ai` if the in-tree `wiki/` is mentioned; not always needed
3. **Private LLM KB** (C) — append a source page in `~/llm_wiki/wiki/sources/2026-08-04-<slug>.md` with the full extended bible + meta-prompt reasoning for LLM-assisted editing

If the user asks "update the wiki" without specifying, default to **A only** (public is what players see). For background research / future-session recall, also write to **C**.

### Phase 6.5 — IP-canon-split subfolder pattern for source-medium-anchored bibles (added 2026-08-18)

When the campaign bible is anchored to a TV show, book, game, or film (e.g., HotD, BG3, Naruto, GoT, Dune), the `~/llm_wiki/wiki/sources/` staging area should mirror the IP's source-medium split. **The public wiki page (A) is unchanged** — it's still a single `queries/<slug>-rhaenyra.md` page. The **LLM wiki (C)** gets the split:

```
~/llm_wiki/wiki/sources/
├── <ip>-tv-show/                           # TV show canon (primary)
│   ├── README.md                            # Season index
│   ├── season-N-episode-1-<slug>.md
│   ├── season-N-episode-2-<slug>.md
│   └── ...
├── <ip>-books/                             # Book canon (fallback only)
│   └── README.md                            # Placeholder + "TV show > book" rule
└── <campaign-bible>.md                     # The campaign bible (cross-links both)
```

Each episode page includes: air date, director, writer, viewer count, plot summary, canon-state changes vs prior episode, cross-references to character entities and sibling episodes, sources. The campaign bible's frontmatter includes `tv_show_canon: "[[<ip>-tv-show/README.md]]"` and `book_canon_fallback: "[[<ip>-books/README.md]]"`.

**Why split by source medium:** (a) the CANON-PRIORITY rule from `campaign-design-rpg-bible` (TV show > book, full stop) is enforced structurally in the frontmatter; (b) the AI DM gets a per-episode working-memory map when it loads the bible; (c) future agents can re-verify the bible's claims against the per-episode pages without re-curling Wikipedia.

**Verified working example:** 2026-08-18 HotD Ashen Crown v4 — 8 S3 episode pages + 1 season index + 1 book placeholder pushed in one commit (`ac658db56` on `jleechanorg/llm-wiki` main). The PR diff was +11 pages / ~25K bytes; AI DM sim compliance with CANON-PRIORITY improved from v3's 3 errors to v4's 0 errors. See `references/session-2026-08-18-hotd-ashen-crown-v4-tv-canon-verified.md` in `campaign-design-rpg-bible` for the full session record.

### Phase 6.6 — Sibling-repo parallel-dispatch pattern (added 2026-08-18)

When the user asks to update multiple wikis + Google Doc + run a sim in one turn ("keep working on X, also do Y in parallel"), the canonical pattern is:

1. **Write all file-content in parallel via multiple `write_file` calls in one tool block** — each episode page is independent, each can be written without waiting on the others.
2. **Copy the slim bible to PR #9 worktree in the same turn** — `cp /tmp/<slug>_bible_only.txt queries/<slug>.md` + `git add <path>` + commit + push, all in one shell block.
3. **Regenerate Google Doc in the same turn** — `gog docs create "<title>" --file /tmp/<slug>_gdoc.md --json` returns the new doc ID immediately. **To update an existing Google Doc in place** (overwrite its content with new markdown), use `gog docs update <docId> --content-file <path> --format markdown` (verified 2026-08-18, HotD Ashen Crown: `gog docs update "1vpTfAgIP9mf04MJ9X8t-Wjv5-MW3eVBGtxPyuMSebKg" --content-file /tmp/hotd_gdoc_v3_update.md --format markdown` successfully replaced the v3-HARD doc content with the v3-TV-CANON+HARD bible; `gog docs cat <docId>` after to verify). The default behavior replaces all content; pass `--append` to append instead.
4. **Run AI DM sim on the slim** — `python3 /tmp/<slug>_sim.py` reads from the same `/tmp/<slug>_bible_only.txt`, doesn't depend on the wiki or Google Doc state.
5. **Commit the LLM wiki batch** — `git add <exact-paths>` + commit + push, separate from the public wiki PR but in the same turn.

**Why one turn:** the user said "do it in parallel" — meaning one turn, many tool calls. Sequencing each as a separate turn would burn ~5-7 turns of context for what is one logical operation. Verified 2026-08-18 (HotD Ashen Crown v4): 5 parallel operations (wiki-ingest + slim + Google Doc + AI DM sim + commits/pushes) executed in 1 turn with 0 inter-dependencies. See `references/session-2026-08-18-hotd-ashen-crown-v4-tv-canon-verified.md` in `campaign-design-rpg-bible`.

### Phase 6.7 — Public-wiki title carries NO version label (added 2026-08-18)

When the user says "just call it v3 and in the public worldai wki dont give it a ersion" (verbatim OOB, 2026-08-18), the convention is:

- **Public wiki page title** (frontmatter `title:` + first H1): NO version label. Use the canonical name: "House of the Dragon — The Ashen Crown (Rhaenyra)", NOT "[v3 TV-CANON + HARD]" or similar.
- **Paste-ready bible** (inside the ` ```text ` fence): MAY carry an internal version label like "[v3 TV-CANON + HARD]" as a marker for the AI DM. This is bible content, not page title.
- **Git commit message**: should still carry the version internally for traceability ("docs(queries): Ashen Crown bible v3 TV-CANON + HARD").
- **PR title + description**: the version can appear as part of the changelog narrative, but the page itself stays version-agnostic.

**Why:** the public wiki is the surface players see. Players don't think in terms of "v3 vs v4" — they see one campaign. The version is a working artifact for the AI DM + agent iteration, not a player-facing concept. Verified 2026-08-18: HotD Ashen Crown page title was changed from "v4 TV-CANON + HARD" to "House of the Dragon — The Ashen Crown (Rhaenyra)" at the user's request; the paste-ready bible kept "[v3 TV-CANON + HARD]" internally.

### Phase 6.8 — `/document-standards` pre-publish audit (added 2026-08-18)

When the user says "lets run /document-standards on it in the worldai wiki" (verbatim OOB, 2026-08-18), run a structured 13-check audit against the page BEFORE opening the PR. The audit catches issues the wikilink linter alone misses (e.g., invalid tags, fence-decoration violations, page-length cap, self-containment). Full checklist recipe at `references/document-standards-checklist.md`. The 13 checks, in priority order:

| # | Check | Why it matters |
|---|---|---|
| 1 | Frontmatter present + all 5 keys (`title`, `created`, `updated`, `type`, `tags`) | `SCHEMA.md` enforced; page won't render correctly in wiki nav without these |
| 2 | All tags in `SCHEMA.md` taxonomy (no ad-hoc tags) | `lint_wikilinks.py` enforces; ad-hoc tags break wiki taxonomy queries |
| 3 | Zero `[[wikilinks]]` (use markdown links) | `lint_wikilinks.py` enforces; GitHub renders `[[X]]` as literal brackets |
| 4 | ≥ 2 outbound markdown links to other wiki pages | `SCHEMA.md` enforced; orphan pages are invisible |
| 5 | Self-contained: zero private-repo links + zero local paths | Pitfall #21; players don't have private-repo access |
| 6 | Copy-paste bible is a single clean ` ```text ` block, no BEGIN/END markers, no nested fences | Pitfall #16; BEGIN/END markers leak into player paste |
| 7 | Page ≤ 250 lines (AGENTS.md cap) | AGENTS.md enforced; over-cap pages fail CI |
| 8 | Lead-paragraph customization hook present | Pitfall #20; players need to see customization promise before scrolling |
| 9 | Post-launch description ("What to expect on your first session") | Pitfall #15; players get dropped into chat/UI with zero context otherwise |
| 10 | LLM-edit meta-prompt included | Enables player customization before pasting |
| 11 | Quick Setup + More Details structure present | Jeffrey's verbatim OOB 2026-08-05 ("let's make two main sections") |
| 12 | Related section with safe links (all resolve) | Pitfall #11; broken Related links break lint on next edit |
| 13 | All relative paths in the page resolve | Pitfall #22; broken paths break nav |

**Verify-and-fix loop:** if a check fails, patch the page in the same turn (the checklist tells you which line). Re-run after each fix. Verified 2026-08-18 (HotD Ashen Crown): 4 ad-hoc tags trimmed to 3 valid (`wa-campaign, wa-tutorial, wa-character`); 22 lines trimmed by compressing Customize + Troubleshooting + Full-setup-walkthrough tables to single-paragraph forms; all 13 checks passed before PR push. The 13/13 PASS summary should appear in the Slack thread reply right before the PR commit.

**When to run `/document-standards`:** before opening any PR to `worldai_wiki` repo on a campaign-template page. Also re-run after every page update (the page may have grown past the line cap, or added a new tag that isn't in the taxonomy).

## Document-Standards reference

For the 13-check pre-publish audit (the `/document-standards` workflow), see `references/document-standards-checklist.md`. Run before opening any PR to `worldai_wiki` on a campaign-template page.

## Common Pitfalls

1. **Wrong repo.** Writing to `${HOME}/projects/worldarchitect.ai/wiki/` (in-tree dev docs) when the user wanted the public-facing `worldai_wiki`. Players never see the in-tree wiki; it's internal. Verify the target with `gh repo view jleechanorg/worldai_wiki` if unsure.

2. **Stale `index.html` field IDs.** The static `index.html` shows IDs like `campaign-title`, `description-input` — the live wizard uses `wizard-campaign-title`, `wizard-description-input`. **Document user-facing labels in the wiki**, not internal IDs. The user-facing labels are stable across deploys; the internal IDs change as the JS evolves.

3. **Wrong checkbox defaults — the recurring trap.** Every checkbox in the V1 Flask wizard is **checked by default**, including "Use Default Fantasy World" and "Generate starting Companions" — exactly the opposite of what a casual reader would expect from prose. The previous version of this skill encoded the inverse ("Mechanics unchecked — check this", "Use Default World unchecked") and PR #7 shipped that bad advice twice. Always probe live defaults with the Playwright TESTING_AUTH_BYPASS recipe (Phase 3) **before** documenting them. Never trust your prose intuition for which way a default is "supposed to" be.

4. **Description field is collapsed by default.** Players who paste the bible into the wrong field get a blank submission. Tell them to click the Expand toggle.

5. **`[[wikilinks]]` instead of markdown links.** `scripts/lint_wikilinks.py` enforces `[Display Text](path/Page.md)`. GitHub renders `[[Page]]` as literal `[[brackets]]` text and breaks navigation.

6. **Orphan page.** New page must be added to `index.md` under the right section, or it's invisible. Every page also needs ≥ 2 outbound links to other wiki pages.

7. **Direct commit to main.** `worldai_wiki` AGENTS.md enforces no-force-push-to-main. Always work on a `feat/<slug>` branch + PR.

8. **Large commit scope pollution.** The `worldarchitect.ai` code repo has 300+ dirty files from other agents' WIP. Adding wiki files to that mess with `git add .` accidentally pulls in 17,000+ lines of deletions. Always `git add <exact-paths>` only.

9. **Forgetting the screenshot path.** Playwright screenshots default to wherever the script writes them. If you write to `${HOME}/.aside/...` (the Aside convention) you lose the file when the session ends. Write to `/tmp/<slug>/screenshots/` and copy into `queries/images/<slug>/` before committing.

10. **The 9-section Campaign Bible structure is the reusable skeleton.** When the user asks for "a campaign template," default to this shape. The wiki's `concepts/CampaignDesign.md` already explains the generic design — your campaign-specific page should slot in as an example, not duplicate.

11. **Broken Related-section wikilinks break the wikilink linter when you update.** The early versions of this skill included a "Related" section with aspirational links to `../overview.md`, `../sources/campaign-creation-tips.md`, `../sources/story-structure-tips.md`, `../sources/ai-combat-tips.md` — none of which exist in the `worldai_wiki` repo (there is no `sources/` directory and no `overview.md`). The original commit landed with these broken because `lint_wikilinks.py` only checks links that resolve at parse time — it can't see pages that were never created. **Every time you update a wiki page that contains such a Related section, run `python3 scripts/lint_wikilinks.py` BEFORE pushing**, or you will push a red build. The safe Related targets as of 2026-08-05: `[How to play — first 30 minutes](../queries/how-to-play-worldai.md)`, `[CampaignDesign](../concepts/CampaignDesign.md)`, `[CharacterCreation](../concepts/CharacterCreation.md)`, `[CampaignWizard](../concepts/CampaignWizard.md)`, `[Combat](../concepts/Combat.md)`. Verify with `ls ${HOME}/projects/worldai_wiki/{concepts,queries,sources,entities}/` before writing the section.

12. **V1 wizard (Flask, port 8081) vs V2 wizard (React, port 3002) trap.** The repo at `mvp_site/tests/test_v1_vs_v2_campaign_comparison.py` documents a hypothetical V2 server on port 3002, but V2 does NOT exist in this repo — only `mvp_site/static/v2/index.html` (a 779-byte stub). The live site is V1 (Flask + the `mvp_site/frontend_v1/` vanilla JS bundle). Don't let the V1/V2 test filename trick you into assuming a V2 React app is shipping. See `references/v1-vs-v2-misdiagnosis.md` for the full misdiagnosis pattern.

13. **Step 2 review screen doesn't surface Mechanics/Companions state.** The "AI Personalities:" line shows only "Narrative" even when Mechanics is checked. Don't cite the Step 2 review text as proof that a checkbox "carried through" — it's stored in the campaign config but the review screen doesn't display it. Trust the wizard code (`mvp_site/frontend_v1/js/campaign-wizard.js`) for default state; trust the Playwright probe (Phase 3) for live state.

14. **Character-customization examples must live IN the Quick Setup table, not buried in More Details.** Jeffrey's OOB (Slack ts=1785909171.805539, 2026-08-05): "In the examples say you can pick gender, class anything about character." The Quick Setup section must include a "Make the character yours" callout with concrete examples (gender swap, age, class override, dragon name, parent swap, look, starting relationship) — not just a one-line "or write your own" pointer to More Details. If a first-time player can't see customization examples without scrolling past the bible, they will assume the bible's 16-year-old default is mandatory.

15. **Quick Setup step 4 must describe what happens after Enter the World.** A first-time player reading the wiki gets dropped into a chat/UI with zero context if the walkthrough ends at "click Enter the World." /advice reviewer C (deleg_765bfb72, 2026-08-05) flagged this explicitly: the page never answers "what do I see after I click Enter the World?" Add a 2-3 sentence description of the AI DM's first narration (claiming scene) + the A/B/C first decision + free typing. The bible's Section 9 has the canonical copy; the wiki Quick Setup just needs to point at it.

16. **The bible block is ONE clean `\`\`\`text` code block — no BEGIN/END markers, no dividers, no decoration inside the fence.** Jeffrey's verbatim OOB (Slack C0AUXSVFSA2 ts=1785977738.112939, 2026-08-05): "Fix this. it hsouldnt be in the copy and paste bible part" / "Copy and paste bible is should be able to copy and paste and not trim/delete start/end stuff" / "I jsut dont even want those markets, i just want something to copy". The earlier version of this skill (and PR #7) shipped `BEGIN_COPY_PASTE_BIBLE — copy everything between BEGIN and END` at the top, `═══════════════════════════════════════════════════════════════════════════` divider lines, and `END_COPY_PASTE_BIBLE — stop copying here` at the bottom — ALL inside the fence. A player doing "select from BEGIN to END" then grabbed (a) the markers themselves, (b) the divider lines, (c) the closing fence, and (d) the next line of prose. The fix is a single `\`\`\`text` block containing ONLY the bible content; the one-sentence instruction ("Copy the entire block below into the **Campaign description prompt** field, then click **Next** → **Enter the World**.") lives ABOVE the fence as regular markdown. Verify with `awk '/^```/{print NR": "$0}' queries/<slug>-campaign.md` — must show exactly two `\`\`\`text` lines (one open, one close), and the bible content must start on the line after the open fence with no decoration. This pattern was confirmed end-to-end via PR #8 ([fix/hotd-wiki-broken-awoiaf-link](https://github.com/jleechanorg/worldai_wiki/pull/8)) on 2026-08-05; the user's prior approval of the page structure explicitly does NOT extend to bringing back BEGIN/END markers, divider lines, or any text inside the fence that the player would have to trim out.

17. **Page-length cap is 250 lines (AGENTS.md).** A single campaign-template page that includes Quick Setup + bible + More Details + troubleshooting + provenance can easily hit 350+ lines. Two options when over the cap: (a) split into `queries/<slug>-walkthrough.md` (Quick Setup + setup) + `queries/<slug>-bible.md` (bible only) + `queries/<slug>-mechanics.md` (More Details), cross-linked; (b) move the bible into `raw/` (immutable raw source) and link to it from `queries/`. Option (a) is the default; option (b) is heavier-handed. Either way, run `python3 scripts/lint_wikilinks.py` after the split and verify all cross-page links resolve.

18. **Dead-but-load-bearing legacy UI trap (prefill migration).** The V1 frontend ships a hidden `<form id="new-campaign-form">` from the original `index.html:165-200` AND a modern wizard (`js/campaign-wizard.js`) injected at runtime. The wizard hides the legacy form via `originalForm.style.display = 'none'` at `enable()` (line 645), but `populateFromOriginalForm()` (lines 1255-1279) STILL reads from the legacy form's `#campaign-title`, `#campaign-prompt`, `#generate-companions` to seed itself when a user types into the form before the wizard bootstraps. The legacy form is hidden in the rendered UI but load-bearing in the prefill migration path. Deleting the legacy form alone (without no-op'ing `populateFromOriginalForm()`) makes every `enable()` throw `Cannot read properties of null (reading 'querySelector')`; deleting `populateFromOriginalForm()` alone (without removing the markup) silently kills the prefill path with no error signal. **Run the 4-check diagnostic in `references/dead-but-load-bearing-legacy-ui.md` BEFORE drafting any "delete legacy UI" PR.** This pattern surfaced 2026-08-05 when Jeffrey said "the campaign creation flow has two copies" and the right answer turned out to be "yes two copies, but you can't delete either alone."

19. **Dead-but-load-bearing legacy UI trap (submit delegation, the deeper cousin).** Even after you understand prefill, the legacy form is ALSO the actual submission mechanism. `campaign-wizard.js:launchCampaign()` (line 1684) calls `populateOriginalForm()` to copy wizard values into the hidden form fields, then dispatches `originalForm.dispatchEvent(new Event('submit'))` (line 1712). The real POST happens in `app.js:3742-3920` (the legacy `submit` handler), NOT in the wizard. This is documented as a known bug in `docs/user-stories-ui/reviews/FIX_STATUS.md` (verify with `rg 'attemptLaunch.*returns a Promise' docs/`): `attemptLaunch()` thinks launch returns a Promise (line 1522 `if (launchResult && typeof launchResult.then === 'function')`) but `dispatchEvent` returns `undefined`, so the wizard's own `.catch()` → `resetLaunchState()` path (lines 1523-1526) never fires. The 5-check diagnostic — beyond the prefill-only 4-check in `references/dead-but-load-bearing-legacy-ui.md` — is: **(5) grep `originalForm.dispatchEvent|legacyForm.dispatchEvent|<legacy-id>\.dispatchEvent` — if the wizard (or any modern UI) dispatches DOM events on the legacy element, the legacy handler is the actual executor and you cannot delete it without rewriting both submission AND error-handling paths.** This trap was discovered 2026-08-05 when the "delete the legacy form" PR was scoped: a clean delete requires (a) refactoring `launchCampaign()` to POST directly, (b) moving `app.js:3742-3920` submit handler logic into the wizard (POST + error handling + retry confirm), (c) wiring `attemptLaunch()`'s `.catch()` to actually fire, (d) updating affected tests, (e) updating all `testing_ui/` browser selectors (`test_smoke_theme_common.py:1028`, `byok_browser_base.py:2063`, `realistic/agent_pool/runner.py:343`). A "just delete the markup" PR breaks campaign launch end-to-end.

20. **Lead-paragraph customization hook is mandatory, not optional.** Jeffrey's OOB (Slack thread C0AUXSVFSA2, 2026-08-05): "also ehre we can just say you can pick your gender/class/background etc queries/house-of-the-dragon-campaign.md". Customization hooks must appear IN the lead paragraph (right after the title + tagline), not only in Quick Setup (Pitfall #14) or More Details. Pattern: a single blockquote > line that says "You can pick your own gender, class, background, dragon name, parent swap, look, starting relationship, and pretty much anything else" with 2-3 concrete example swaps ("if you want to be a woman knight sworn to Rhaenyra, a male maester-in-training, a bastard of Aegon II instead of Daemon, a 30-year-old veteran, etc."). This is upstream of Pitfall #14 — players who never scroll past the lead need to see the customization promise immediately. Confirmed 2026-08-05: PR #7 `fdf237d` shipped the lead-paragraph hook.

21. **Public wiki pages must be self-contained — no references to private repos or local paths.** Jeffrey's OOB (Slack C0AUXSVFSA2 ts=1785977738.112939, 2026-08-05): "make sure this wiki is self contained and doesnt reference other repos". The public `worldai_wiki` is the surface players see; it cannot link to private repos (`github.com/jleechanorg/worldarchitect.ai` is the prime example — players don't have access and the link 404s for them). Same rule for absolute local paths like `${HOME}/projects/worldarchitect.ai/wiki/...` — those leak operator-only filesystem structure. What is allowed: (a) intra-wiki links to other pages in the same repo (`[Combat](../concepts/Combat.md)`); (b) links to external public references the player might actually click (e.g. `https://en.wikipedia.org/wiki/Dance_of_the_Dragons`); (c) self-references to the same public repo (e.g. troubleshooting row pointing at `https://github.com/jleechanorg/worldai_wiki/tree/main/queries`). Drop `### Provenance` and `## Sources` sections that name private-repo source files; if you must keep provenance, fold it into a single one-liner that doesn't link anywhere. Audit before publish: `rg -n 'github\.com/jleechanorg/worldarchitect\.ai|${HOME}/' queries/<slug>.md` — must return zero matches. Caught on PR #7 → fixed in `72c6adb` and again on the in-tree mirror (`6c5d7b157d`).

22. **Verify every link in the page resolves before publishing.** Jeffrey's OOB (Slack C0AUXSVFSA2, 2026-08-05): "Test all links and make sure they work" / "dont reference things like this if the link is broken". The wikilink linter (`scripts/lint_wikilinks.py`) only catches markdown links that point at non-existent files inside the wiki — it does NOT probe HTTP URLs, and it can't catch external refs to private repos (Pitfall #21). Before merging any wiki PR, run a full link audit:

```bash
# 1. Inventory every reference
grep -oE '\[[^]]+\]\(([^)]+)\)' queries/<slug>.md | sed 's/^[^)]*(\(.*\))$/\1/' | sort -u
grep -oE 'https?://[^ )"]+' queries/<slug>.md | sort -u

# 2. Relative paths — every one must exist
for f in $(grep -oE '\.\./[a-zA-Z_/.]+\.md|images/[a-zA-Z_/.0-9-]+\.(png|jpg|jpeg|gif|webp)' queries/<slug>.md | sort -u); do
  [ -f "$f" ] && echo "OK   $f" || echo "MISS $f"
done

# 3. HTTP URLs — probe with browser UA (some hosts block default curl)
for url in $(grep -oE 'https?://[^ )"]+' queries/<slug>.md | sort -u); do
  code=$(curl -fsS -A "Mozilla/5.0" -L --max-time 12 -o /dev/null -w "%{http_code}" "$url" 2>&1)
  echo "$code   $url"
done
```

`awoiaf.westeros.org` is a known hard-blocker (returns HTTP 403 even with browser UA — Cloudflare / hot-link protection); replace with the Wikipedia equivalent. For GitHub repo links, also verify the path actually resolves by checking the GitHub API: `gh api repos/<org>/<repo>/contents/<path>` should return a non-empty array. Document each link's status in the PR body ("Link audit: all 15 references green" or "Replaced broken X with Y"). Caught on PR #7 → fixed in PR #8 ([fix/hotd-wiki-broken-awoiaf-link](https://github.com/jleechanorg/worldai_wiki/pull/8), 2026-08-05).

23. **Don't flatten source-medium canon into a single "sources" list for IP-anchored bibles (added 2026-08-18).** When the campaign is anchored to a TV show / book / game / film, the LLM-wiki `sources/` should be split by medium (e.g., `hotd-tv-show/` for S1-S3 episode summaries, `hotd-books/` for Fire & Blood references), not a flat list of "see Wikipedia for S3 E1-E8." The split enforces CANON-PRIORITY structurally and gives the AI DM a per-episode working-memory map. Verified 2026-08-18: 8 S3 episode pages + 1 season index + 1 book placeholder pushed in one commit. See Phase 6.5.

24. **Don't serialize parallel-dispatch operations (added 2026-08-18).** When the user says "do X and keep working on Y in parallel" or "do it in parallel", they mean one turn with multiple tool calls — not sequencing each operation across multiple turns. The sibling-repo pattern (Phase 6.6) is the canonical example: wiki-ingest + slim + Google Doc + AI DM sim + commit/push in one turn. Sequencing would burn ~7 turns of context for what is one logical operation.

25. **Source-of-truth vs `~/.smartclaw/skills/<name>/` divergence (added 2026-08-20).** The `download-campaign` skill referenced from this umbrella is exported FROM `jleechanorg/claude-commands` (source-of-truth repo at `hermes/skills/download-campaign/`) TO `~/.smartclaw/skills/download-campaign/` (deployed location the launchd job `ai.jleechan.wiki-campaign-daily-ingest` actually runs). They CAN diverge — when they do, the launchd job reads the deployed copy, NOT the source. **A PR fix to source-of-truth does NOT fix the launchd job until re-exported.**

    **Verified 2026-08-20** (PR [#357](https://github.com/jleechanorg/claude-commands/pull/357)): today's launchd run processed 157 real WA users and failed all 157 with `'NoneType' object has no attribute 'collection'`. The deployed file at `~/.smartclaw/skills/download-campaign/scripts/download_campaign.py` had a refactor regression where `init_firebase()` returned `None` when `firebase_admin._apps` was already populated. PR #357 fixed the source on `origin/main` (added regression test + docstring); but the launchd job kept reading the buggy deployed file because the deployed file had not been patched in place. Three byte sizes observed in the same session: deployed (16330 — buggy), source main checkout `${HOME}/claude-commands` (9356 — also buggy, older missing `--mode all-users`), `origin/main` worktree (14120 — already correct).

    **Rule:** after ANY PR fix to a skill that lives in both `jleechanorg/claude-commands` and `~/.smartclaw/skills/`, ALSO patch the deployed file in the same turn if a launchd job runs against it. A merge to `origin/main` does NOT propagate to `~/.smartclaw/`. The deploy pipeline (`scripts/deploy.sh` Stage 4.6) syncs `~/.smartclaw/skills/` → `~/.smartclaw_prod/skills/` but does NOT pull from `jleechanorg/claude-commands`. The source → staging direction requires either (a) the operator manually re-exporting via `/exportcommands`, or (b) a fresh worktree + `cp` of the changed file from `jleechanorg/claude-commands:hermes/skills/<name>/` to BOTH `~/.smartclaw/skills/<name>/` AND `~/.smartclaw_prod/skills/<name>/` (the latter is what the running gateway actually loads).

    **3-byte-size smoking-gun diagnostic** when a launchd job fails with a bug the source has already fixed:

    ```bash
    stat -f %z "$HOME/.smartclaw/skills/<name>/scripts/<file>.py"        # deployed (launchd runs this)
    stat -f %z "$HOME/.smartclaw_prod/skills/<name>/scripts/<file>.py"  # prod (gateway loads this)
    stat -f %z ${HOME}/claude-commands/hermes/skills/<name>/scripts/<file>.py  # source main checkout
    cd ${HOME}/claude-commands && git log -1 --format='%h' -- hermes/skills/<name>/scripts/<file>.py  # source HEAD
    ```

    If all four sizes differ, the launchd bug is in the deployed file even though source has the fix. Patch deployed in place; PR-merge to source can follow.

    **Companion bug class caught in the same session** (`download-campaign` Pitfall #9 in the `download-campaign` skill): `init_firebase()` returning `None` when `firebase_admin._apps` was pre-populated by `clock_skew_credentials.apply_clock_skew_patch()`. The fix is one-line: `return firestore.client()` must be OUTSIDE the `if not firebase_admin._apps:` block. The deployed patch was applied to `~/.smartclaw/.../download_campaign.py` directly to make tomorrow's 09:00 launchd run green immediately; PR #357 carries the source-of-truth test + docstring guardrail so the regression can't silently re-appear.

## LLM-Edit Meta-Prompt (ship with every campaign template)

Every campaign-bible page should include this exact meta-prompt so players can customize before pasting:

> You are an expert narrative designer and Game Master. I have pasted the "[Campaign Title]" custom-campaign template for WorldArchitect.AI. I want to edit it as follows:
>
> **[describe your changes here, e.g.,]**
> - Change the dragon's name from "[name your dragon]" to "Vyraxes"
> - Make the protagonist explicitly female, 18, not 16
>
> Apply only the changes I asked for. Preserve every other section verbatim. Return the full edited campaign bible, ready to paste into the WorldArchitect.AI "Campaign description prompt" field.

This meta-prompt survives most player-shaped edits without breaking the 9-section structure.

## Verification Checklist

- [ ] Page is in the correct wiki home (A: `worldai_wiki`, B: `worldarchitect.ai/wiki/`, C: `~/llm_wiki/wiki/`)
- [ ] Frontmatter has `title`, `created`, `updated`, `type`, `tags` (and `sources` if applicable)
- [ ] All tags are in `SCHEMA.md` taxonomy (no ad-hoc tags)
- [ ] All links are markdown (`[Text](path.md)`), zero `[[wikilinks]]`
- [ ] ≥ 2 outbound links to other wiki pages
- [ ] **Related-section links all resolve** — `python3 scripts/lint_wikilinks.py` exits 0 after the Related section is added (Pitfall #11)
- [ ] **Copy-paste bible is a single clean code block** — no BEGIN/END markers, no divider lines, no decoration inside the fence; one instruction sentence above the fence (Pitfall #16)
- [ ] **Page is self-contained** — zero references to private repos (`github.com/jleechanorg/worldarchitect.ai`) or local paths (`${HOME}/...`) (Pitfall #21)
- [ ] **Every link resolves** — relative paths exist, HTTP URLs return 2xx/3xx, GitHub API confirms repo paths (Pitfall #22)
- [ ] **V1 vs V2 wizard verified** — captured a real screenshot of the live site via Playwright Python in TESTING_AUTH_BYPASS mode; wizard version (V1 Flask or V2 React) matches the instructions
- [ ] **Checkbox defaults probed live** — Phase 3 Playwright probe captured the actual `is_checked()` state for every checkbox at boot, not inferred from prose (Pitfall #3)
- [ ] **Dead-but-load-bearing UI checked** — if the page references a "two copies" UI (legacy form + injected component), grep the JS for readers of the legacy IDs BEFORE deleting anything (Pitfall #18 + `references/dead-but-load-bearing-legacy-ui.md`)
- [ ] `python3 -m pytest tests/ -q -m "not slow"` → all pass
- [ ] LLM-edit meta-prompt included at the bottom of the page
- [ ] Page has been walked live on worldarchitect.ai before publishing (Step 2 review verified with screenshot)
- [ ] PR opened on `feat/<slug>` branch (not main)
- [ ] Image evidence committed to the repo (not just the PR description)
- [ ] **IP-canon-split applied when source-medium anchored** (added 2026-08-18) — if the bible is anchored to a TV show / book / game / film, `~/llm_wiki/wiki/sources/<ip>-tv-show/` (per-episode pages) and `~/llm_wiki/wiki/sources/<ip>-books/` (placeholder) exist; the campaign bible's frontmatter cross-links both. See Phase 6.5.
- [ ] **Source-of-truth vs deployed-skill divergence checked** (added 2026-08-20) — if `download-campaign` or any sibling skill was patched in source, also `cp` the deployed `~/.smartclaw/skills/<name>/scripts/<file>` AND `~/.smartclaw_prod/skills/<name>/scripts/<file>` in the same turn; a PR merge to `origin/main` does NOT propagate. See `references/source-vs-deployed-skill-divergence.md` + Pitfall #25.
- [ ] User notified of the PR URL + commit SHA + sibling-repo paths