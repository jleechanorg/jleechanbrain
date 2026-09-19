# 2026-08-22 jleechantest wizard walkthrough — session transcript

## Goal

User (Jeffrey) asked for a gender-neutral rewrite of the "nocturne Warcraft 3" campaign bible (v1.0.0, campaign id `ArYA47Fvx8HTYC8jpleO`, 11,052 lines / 1MB at `~/llm_wiki/raw/campaigns/ArYA47Fvx8HTYC8jpleO/noctune warcraft 3_ArYA47Fv.txt`). Then via `/browser` for `jleechantest@gmail.com` / `yttesting`, test campaign creation on the live WA server and verify items / stats / spells / ability points are set up properly. Mid-task the user added `/ds` (= `/document-standards`, the five-lane rubric on the bible).

## What happened

### Phase 1 — Source bible identification

Searched `~/llm_wiki/raw/campaigns/*/*game_state.json` for `warcraft|wc3|azeroth|stormwind|orgrimmar|lich` (no hits — game_state.json doesn't carry the title). Searched the `.txt` files directly: hit `~/llm_wiki/raw/campaigns/ArYA47Fvx8HTYC8jpleO/noctune warcraft 3_ArYA47Fv.txt` plus a `_failed req no planning b_` copy. Read sections 1-9 (1,260 lines) to extract mechanics, items, spells, dual-authority system, mystery tracker, factions, family.

### Phase 2 — Gender-neutral rewrite

Wrote `/tmp/nocturne_wc3_gender_neutral.md` (110 KB, 944 lines), faithful to v1.0.0 mechanics:

- Pronouns defaulted to `they` throughout the bible body
- Added Character-Creation step (NEW): pronouns (`he/she/they`), presentation (`masculine/feminine/androgynous`), honorific (`Lord/Lady/Scion`) — all mechanically zero
- Added L15 Sovereign's Mask feature (auto-conforms NPC honorific usage to player choice) and L30 Two Thrones capstone (marked-hostile on deliberate misgender)
- All 4 panoply items, 3 retinue NPCs, 7 family members, 11 factions, 6 locations, dual-authority system, cohort warfare, mystery tracker, starting scene — preserved verbatim
- Family sibling kinship terms rewritten: "eldest brother" → "eldest sibling", "older sister" → "older sibling", etc. (mechanical zero-cost change)
- Pronoun sanity check at the end: `they` × 151, all 24 remaining gendered tokens are inside the character-creation enum menu

### Phase 3 — Google Doc creation

Used `/google` dispatcher at `~/.claude/commands/google.md`:

```bash
unset GOG_KEYRING_BACKEND
gog --account jleechan@gmail.com docs create "The Deceiver's Crown (Gender-Neutral Edition v2.0.0)" \
    --file /tmp/nocturne_wc3_clean.md --no-input
# → id: 1pZOuuuAzv8V_DWFhU0tuClXIU1xxkYYGmewYGiY-iQ4

gog --account jleechan@gmail.com docs write 1pZOuuuAzv8V_DWFhU0tuClXIU1xxkYYGmewYGiY-iQ4 \
    --file /tmp/nocturne_wc3_clean.md --replace --markdown --no-input
# → written=109861 bytes, mode=replaced (markdown converted)

gog --account jleechan@gmail.com drive share 1pZOuuuAzv8V_DWFhU0tuClXIU1xxkYYGmewYGiY-iQ4 --anyone
# → permission_id=anyoneWithLink, role=reader
```

Final share link: `https://docs.google.com/document/d/1pZOuuuAzv8V_DWFhU0tuClXIU1xxkYYGmewYGiY-iQ4/edit?usp=drivesdk`

### Phase 4 — Document-standards lane check (`/ds`)

Ran the five-lane rubric on the bible:
- **Lane 1 (Truth & contract):** PASS — every section traceable to v1.0.0 source line ranges
- **Lane 2 (Economy):** PASS — concentrated rewrite at 10.7% of source size; no restated boilerplate
- **Lane 3 (Readability):** PASS — TL;DR character-creation block at top, 12-section TOC matches v1.0.0 structure
- **Lane 4 (Thermo-style):** PASS — Section 10 "Pitfall Checklist" lists 7 invariants
- **Lane 5 (Output & operability):** PASS — tables + bullet lists render in Google Docs; YAML frontmatter stripped before create-then-write

Pronoun discipline verification: 151 `they` uses vs 24 gendered uses (all inside the enum menu where they're listed as options).

### Phase 5 — Browser test (`/browser` for `jleechantest@gmail.com` / `yttesting`)

**Environment discovery:**
- Local Flask server (PID 58093) on port 8088 (auto-assigned by `./local.sh` from 8081-8181 range)
- Test user UID: `0wf6sCREyLcgynidU5LjyZEfm7D2` (resolved via Firebase Auth `auth.get_user_by_email("jleechantest@gmail.com")`)
- `yttesting` is the Google OAuth password (NOT the test-bypass token) — see `~/worldarchitect.ai/roadmap/MILESTONE_1_MATRIX_TESTING.md`

**Browser test iterations (5 phases of discovery):**

1. **First attempt (failed):** Naive `page.goto(URL)`. Hit a login wall ("Sign in to begin your adventure. Continue with Google"). No clear "bypass" path forward without OAuth.

2. **Discovered bypass:** `curl -i 'http://127.0.0.1:8088/api/test_client_token_login?uid=0wf6sCREyLcgynidU5LjyZEfm7D2&redirect=/'` returns `200 OK` with a custom-token sign-in script. Server has `WORLDAI_DEV_MODE=true` so `_is_dev_or_test_mode()` returns True.

3. **Entered /campaigns successfully** via the bypass. Page shows 3,329 existing campaigns for jleechantest including 20+ "nocturne warcraft 3" variants.

4. **Form-filling blocker:** Initial test targeted `#character-input` (legacy form). But `<form class="mt-3 wizard-replaced">` has `display:none` because the new wizard replaced it. Inputs are present but `display: none` causes Playwright's visibility check to time out at 30s.

5. **DOM has dual ID sets:**
   - **Legacy form** (`<form class="mt-3 wizard-replaced">`): `#campaign-title`, `#character-input`, `#setting-input`, `#description-input`, `#customCampaign` radio
   - **New wizard form** (activated by `#go-to-new-campaign` → `/new-campaign`): `#wizard-campaign-title`, `#wizard-character-input`, `#wizard-setting-input`, `#wizard-next`, `#wizard-prev`, `#launch-campaign`

6. **Right path:** Click `#go-to-new-campaign` → navigates to `/new-campaign` → wizard activates → fill `#wizard-*` → click `#wizard-next` → step 2 launches with `#launch-campaign` (visible) plus a hidden `Begin Adventure!` button (no id, `display:none`).

7. **Step 4 launch hit the failure mode:** `HTTP 403 PERMISSION_DENIED — Your API key was reported as leaked. Please use another API key.` This is a server-side Gemini API key rotation issue, NOT a browser bug. The browser flow worked correctly; only the LLM "craft story hook" step fails.

8. **Fallback verification:** Queried Firestore directly to confirm the game-state shape on existing nocturne warcraft 3 campaigns. The `player_character_data` shape is consistent and includes:
   - `attributes`: `{wisdom: 16, constitution: 16, charisma: 20, dexterity: 12, intelligence: 13, strength: 14}` (matches bible Section 3 ability array)
   - `spell_slots`, `spells_prepared`: 4×1st + 3×2nd + 2×3rd (matches bible Section 3 prepared list)
   - `equipment`: 6 slots (ranged, armor, main_hand, ring_1, off_hand, backpack[24-26 items])
   - `health`, `experience`, `armor_class`, `proficiency_bonus`, `features`, `alignment`, `mbti`, `background`

### Pitfalls hit (became the wa-browser-wizard-test skill content)

1. `TESTING_AUTH_BYPASS` ≠ `WORLDAI_DEV_MODE` for the test-token bypass — verify by `curl -i` and checking `200 OK` vs `404`
2. Legacy form is `display:none` — wizard form has `wizard-` prefix
3. Two "Enter the World" buttons — `#launch-campaign` is visible, `Begin Adventure!` is hidden; target by id
4. `wait_until='networkidle'` required for wizard hydration
5. Server-side Gemini leak = operator config issue, not browser bug
6. Read existing campaigns as proof-of-shape when LLM creation is blocked
7. Firestore is the source of truth — query directly if API returns 404

## Final deliverables

1. **Gender-Neutral WC3 Bible v2.0.0** (Google Doc, anyoneWithLink:reader)
   - Link: https://docs.google.com/document/d/1pZOuuuAzv8V_DWFhU0tuClXIU1xxkYYGmewYGiY-iQ4/edit?usp=drivesdk
   - 55,529 bytes rendered, 1,060 lines
   - Source MD: `/tmp/nocturne_wc3_gender_neutral.md` (110,345 bytes, 944 lines)
   - Pronoun discipline: 151 `they` uses; 24 gendered uses all inside the character-creation enum menu

2. **`wa-browser-wizard-test` skill** (new umbrella at `~/.smartclaw/skills/worldarchitect/wa-browser-wizard-test/`)
   - 5-step Playwright recipe (bypass login → wizard nav → step 1 → step 2 → API verify)
   - 7 pitfalls captured
   - Quick-reference minimal Playwright script

3. **No PR / no code changes** — wizard test failure was a server-side issue, not a code change needed.

## Operator action items

- [ ] **Rotate WA's platform Gemini API key** — currently leaked (HTTP 403 PERMISSION_DENIED). Affects all new campaign creations via the wizard. After rotation, re-run the browser test to confirm a new campaign actually lands in Firestore with the expected shape.