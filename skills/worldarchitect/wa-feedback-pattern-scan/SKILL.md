---
name: wa-feedback-pattern-scan
version: 0.3.0
description: "Score UX across real WA users vs baseline (Firestore or local .txt corpus variant)."
tags: ["worldarchitect", "feedback", "ux-patterns", "cross-user", "firestore-scan", "onboarding", "friction", "win-condition", "dup-submit", "content-moderation-gap"]
related_skills:
  - download-campaign
  - wa-prod-data-query
  - wa-narrative-schema-required-fields-contract
last_verified: 2026-08-17 (batches A, C, D verified; batch B added 11 mid-length 38-52 entry campaigns including kevin's two flagged campaigns; batch B re-validated the 3x-dup-submit signature on a SECOND user, and surfaced a critical safety metric pitfall — see pitfall #14)
---

# wa-feedback-pattern-scan — score cross-user UX patterns from real WA campaigns

This skill answers product-feedback questions like *"is kevin's lack of onboarding a one-off, or system-wide?"* by scanning 5+ real-user campaigns (>20 entries each) and scoring each on a small set of named patterns. Distinct from `download-campaign` (one campaign → text) and `wa-prod-data-query` (aggregate activity → counts). This is *qualitative cross-user UX scoring*.

## When to use this skill

- User asks to evaluate whether a specific UX pattern (onboarding, friction, goals, pacing) shows up in real WA campaigns
- Product hypothesis needs cross-user validation: "does the system actually introduce obstacles in the first turn?"
- Single-user complaint needs comparison baseline ("kevin says he never sees friction — do other users?")
- A WA bug report references a class of behavior that may be systemic vs isolated (e.g. "no onboarding quiz" — is this a property of the system or of kevin's session?)

## When NOT to use this skill

- Reading a single specific campaign's full text → `download-campaign`
- Aggregate activity counts (signups, turn counts, retention) → `wa-prod-data-query`
- Bug-class diagnosis on a single campaign (Factor I, schema contracts) → `worldarchitect/wa-directive-scope-factor-i-diag` etc.
- Visual proof of a UI change → `wa-visual-proof-playwright`

## The canonical pattern set (extend as needed)

### Core 3 (original kevin review)

| Pattern | What to inspect | Score range |
|---|---|---|
| **ONBOARDING/QUIZ** | First 5 entries (any actor). Look for explicit preference questions ("what type of game do you like", "interests", "non-interests", "experience level", "preferred genre/play style") | 0=none, 1=subtle hint, 2=explicit quiz |
| **INITIAL FRICTION** | First 3 USER actions + the next non-user response after each. Distinguish narrative obstacles (score 2) from CC-menu friction (score 1) | 0=full compliance, 1=system menu, 2=in-narrative obstacle |
| **WIN CONDITION / GOAL** | First 15 entries. Look for explicit mission / deadline / antagonist / stated objective | 0=no goal, 1=vague hint, 2=explicit mission with stakes |

### Extended 6 (kevin's 6 follow-up items + CC wizard + action_resolution, verified 2026-08-17 against 11 sub-200-entry campaigns)

| Pattern | What to inspect | Score range / type |
|---|---|---|
| **CC_TURNS** | Count user turns spent inside the CC wizard before first in-narrative scene. Zero = bypassed (God Mode / pre-built template / AI gen accepted). >3 = too many. | int (0-11+) |
| **CC_USES_STANDARDDND** | Did the user pick "Option 2: [StandardDND]" at the CC choice screen? This is the 11-turn trap. | bool |
| **ACTION_RESOLUTION_WARNING_COUNT** | Count of `"Missing action_resolution field"` warnings. | int (always 0 from .txt exports — see pitfall #9) |
| **LOOP_SEVERITY** | Consecutive similar user actions without progression. See `references/loops-vs-dup-submit.md` for dup-submit vs LLM-loop discrimination. | none / mild / moderate / severe |
| **READABILITY** | Avg GM response size + visual density (block length, sentence length, dialogue ratio). | 0=well-formatted, 1=long blocks, 2=wall-of-text consistently |
| **WALL_OF_TEXT_EVIDENCE** | Average character count per GM response (rough estimate). | string estimate like "~700-1200 chars" |

Add more patterns (pacing, NPC relationship setup, level-up triggers, retention signals) the same way: a scorer function that takes the first N entries and emits score + evidence quote.

### Heuristic rubric for LOOP_SEVERITY (verified 2026-08-17 on 11 campaigns)

| Severity | Criteria | Example |
|---|---|---|
| `none` | 0 consecutive similar user actions | First_Adventure_l4cSEld7, Fantasy_Chronicles_qFWzUZ1i |
| `mild` | 1-2 similar actions in a row, or rare scattered repetition | Dragon_Knight_l5XAIbva, 1000_worlds_a_million_stories_yrNYX1Pn, The_young_Naib___the_desert_kuPWXaiU |
| `moderate` | 3-4 similar actions, or escalating repetition with thematic escalation (e.g. parley→sheathe→ATTACK collapse) | Dragon_Knight_MmibVhBz, Dragon_Knight_vXwIh34U, Dragon_Knight_wq9tgQnL, Testing_it_out_TeqNa3GV |
| `severe` | 5+ similar actions, or pattern of identical-templated user inputs | Alien_spaceship_1zNtHMuS (TOS-violating spiral) |

Special-case pattern: the Dragon Knight pre-built template users show a consistent **"parley → order soldiers to sheathe → ATTACK" moral-arc collapse** within 4-6 turns (verified Dragon_Knight_vXwIh34U: full parley ladder → Julian Vance killed). This isn't a literal loop, but it IS a repeated behavioural signal that the Dragon's Favor safety net + the explicit "pacify the refugees" framing interact badly. Worth flagging as a template-level pattern.

### Readability heuristic (rough, eyeballed from .txt exports)

| Score | Indicator | Avg chars / GM response |
|---|---|---|
| 0 | Short paragraphs, dialogue breaks, varied sentence length | <400 |
| 1 | Long paragraphs (3-8 sentences), few breaks | 400-1000 |
| 2 | Consistent walls of 6-15 sentences, minimal paragraph breaks | 700-1500 |

The Dragon Knight pre-built template produces 700-1500 char GM responses almost always → readability=2.

## Verified findings

### 2026-08-17: 6 campaigns (kevin's original baseline — large/medium campaigns)

| Campaign | Entries | Onboarding | Friction | Goal |
|---|---|---|---|---|
| kevinzsalleh@gmail.com / Dragon Knight Round 5 | 718 | 0 | 2 | 2 |
| hanjistevens@gmail.com / HALCYON DAYS | 384 | 1 | 2 | 2 |
| pickyourfavouritememory@gmail.com / My Epic Ballsac Dragonurphace | 234 | 0 | 2 | 2 |
| thiago.hirai@gmail.com / My Epic Adventure | 82 | 0 | 2 | 2 |
| nordicsuccubus@proton.me / Dragon Warrioress | 68 | 0 | 1 | 1 |
| mushrooming.fungus@gmail.com / Dragon Knight | 52 | 0 | 2 | 2 |
| **TOTAL** | — | 0×5, 1×1, 2×0 | 0×0, 1×1, 2×5 | 0×0, 1×1, 2×5 |

**Net read:** onboarding is *systemically absent* (0/6 explicit quizzes, 1/6 subtle hint) — confirming that kevin's experience is the modal experience, not an outlier. Friction and goals *are* present systemically (5/6 each scored 2) once the user passes CC. The one soft-friction case (nordicsuccubus) had all three user actions still inside the CC wizard — i.e. the only "friction" she encountered was the CC menu itself.

### 2026-08-17: 6 long-running campaigns (batch D — 222–1206 entries, kevin's final feedback review pass)

This batch extends the scan to the largest pre-downloaded campaigns including 3 jleechan reference campaigns + 6 long-running real-user / validation-replay campaigns. Source: `${HOME}/Downloads/all_campaigns/` (same as batch A/C).

| Campaign | Entries | Scenes | Onb | Fric | Goal | CC turns | CC StandardDND | Loop | Read | Wall (avg chars) | ActRes warn |
|---|---|---|---|---|---|---|---|---|---|---|---|
| HALCYON_DAYS_JmSYWVwl | 384 | 192 | 1 | 1 | 2 | 4 | **YES** | mild | 2 | 1647 | 0 |
| Dragon_Knight_Round_5_hwxRXaS5 | 718 | 359 | 2 | 2 | 2 | 0 | no | none | 2 | 1432 | 7 |
| bg3_nocturne_RED_jFBwPkRs (short replay) | 514 | 268 | 1 | 1 | 1 | 2 | no | mild | 2 | 2491 | 1 |
| bg3_nocturne_RED_1zIJDHYG (long replay) | 1206 | 603 | 1 | 1 | 1 | 5 | no | moderate | 2 | 2585 | 1 |
| bg3_nocturne_GREEN_a0G7i0dk (long replay) | 1206 | 603 | 1 | 1 | 1 | 5 | no | moderate | 2 | 2585 | 1 |
| My_Epic_Adventure_9jYaPX4P | 288 | 144 | 1 | 2 | 1 | 0 | no | mild | 1 | 1522 | 3 |

**Aggregate distributions (batch D):**

| Metric | Mean | Distribution |
|---|---|---|
| Onboarding | 1.17 | {1: 5, 2: 1, 0: 0} |
| Friction | 1.33 | {1: 4, 2: 2, 0: 0} |
| Goal | 1.33 | {2: 2, 1: 4, 0: 0} |
| CC turns | 2.67 | {0: 2, 2: 1, 4: 1, 5: 2} |
| Readability | 1.67 | {1: 1, 2: 5} |
| StandardDND | — | 1/6 (16.7%, HALCYON_DAYS only) |
| Loop severity | — | {none: 1, mild: 3, moderate: 2} |
| Wall-of-text avg chars | 1877 | max 2585 (bg3 long), min 1432 (Dragon Knight) |

**Batch D unique findings:**

1. **RED/GREEN replays (1zIJDHYG vs a0G7i0dk) are LITERALLY identical in narrative content.** Both 1206 entries / 603 scenes. MD5 differs (`4c19b75a...` vs `594d3a98...`) but every byte-level diff (279/603 scenes, 46.3%) is Python dict key-ordering inside Dice Rolls JSON block. After normalizing JSON, 0 prose divergences. Confirms deterministic LLM replay validation. See `references/red-green-replay-diff-methodology.md` for the normalization recipe.

2. **Calendar-drift is a measurable action_resolution_warning proxy.** Batch A pitfall #9 said action_resolution warnings are unmeasurable from .txt — that's still true for the explicit "Missing action_resolution field" string, BUT empty-timestamp scenes (`[Timestamp:  DR,  , 12:30:00]` with empty date components) ARE present in 3 batch D bg3 replays and are the same warning class. Dragon Knight uses 5 year formats (`40 AG`/`11 DR`/`Year 11`/`1492 DR`/`11 New Peace`) but each maps to a canonical campaign year — NOT drift. My_Epic_Adventure_9jYaPX4P uses 5 formats within a single linear timeline (`11 DR` 96x + `11 New Peace` 22x + `Year 11` 21x + `40 A.G.` 2x + `1492 DR` 1x) — THAT is drift. Detect via `len(distinct_year_format_tokens) > 2` AND temporal linearity check. See pitfall #12.

3. **bg3_RED_short (jFBwPkRs, 268 scenes) is NOT a continuation of bg3_RED_long (1zIJDHYG, 603 scenes).** Same campaign bible, but different playthrough runs: different gold values (100,000gp vs 27,000gp in scene 2), different scene 5 content, different timestamps. Don't conflate "shorter replay" with "earlier segment".

4. **HALCYON_DAYS shows the heaviest God-Mode retcon pressure (37 god-mode directives / 192 scenes = 19%).** Compare batch C's Halcyon_Days_2G4YpEKF (severe loop) which had similar God-Mode bloat. The HALCYON_DAYS retcons are *productive* (NPC name changes, stat system rewrites, location renames) — distinct from the *destructive* admin/debug echoes in Halcyon_Days_2G4YpEKF. Score retcon-pressure via `n_god_mode_prompts / n_scenes ≥ 0.15` and flag as `heavy-retcon` distinct pattern.

5. **Validation replay detection.** Any campaign starting with `bg3_nocturne_*__replay_*` in its folder name is a jleechan validation replay. These will always have: freeform-only player actions (no choice menu), extremely high god-mode prompt density (200+ for long replays), repeated empty-timestamp scene 5, and Admin Update scenes throughout. Don't score these as "real users" — the friction score is meaningless (user is testing parser robustness, not playing). Add `is_validation_replay: true` field and skip UX scoring.

Per-campaign detail at `/tmp/all_readings/batch_D.json` + `/tmp/all_readings/batch_D_summary.json`.

### 2026-08-17: 11 sub-200-entry campaigns (kevin's extended review — batch A)

Six Dragon Knight pre-built template users + 5 misc. Source: `${HOME}/Downloads/all_campaigns/*/` (download-campaign Phase 1 cache, not fresh Firestore). Per-campaign detail at `/tmp/all_readings/batch_A.json`.

| Campaign | Entries | Onb | Fric | Goal | CC turns | CC StandardDND | Loop | Read | Notable |
|---|---|---|---|---|---|---|---|---|---|
| Dragon_Knight_l5XAIbva | 22 | 1 | 1 | 2 | 0 | no | mild | 1 | God Mode bypassed CC |
| First_Adventure_l4cSEld7 | 24 | 1 | 0 | 1 | 11 | **YES** | none | 1 | Full StandardDND trap; user asked "What's the first step" mid-wizard |
| My_Epic_Adventure_vtYSgYw2 | 24 | 1 | 1 | 2 | 0 | no | none | 1 | Same Dragon Knight template, corrupted timestamps |
| Fantasy_Chronicles_qFWzUZ1i | 26 | 1 | 1 | 1 | 5 | **YES** | none | 1 | Fading-magic setting, StandardDND but only 5 turns |
| 1000_worlds_a_million_stories | 28 | 1 | 2 | 2 | 1 | no | mild | 1 | Traveller-style custom class; God Mode power-level to Lvl 5 |
| Testing_it_out_TeqNa3GV | 30 | 1 | 2 | 2 | 6 | **YES** | moderate | 1 | Industrial/Warlock; double Shield-the-Mages loop |
| The_young_Naib (Dune) | 30 | 1 | 1 | 1 | 2 | no | mild | 1 | AI-gen character accepted; Lvl 2 mid-session |
| Dragon_Knight_MmibVhBz | 32 | 1 | 2 | 2 | 0 | no | moderate | 2 | Tavern detour; full social-skill challenge ladder |
| Alien_spaceship_1zNtHMuS | 36 | 0 | 0 | 0 | 3 | no | **severe** | 1 | TOS-violating spiral; player dies in scene 17 |
| Dragon_Knight_vXwIh34U | 36 | 1 | 2 | 2 | 0 | no | moderate | 2 | **Parley → sheathe → ATTACK collapse** (Julian killed) |
| Dragon_Knight_wq9tgQnL | 36 | 1 | 2 | 2 | 3 | no | moderate | 2 | **Mythic 20 STR via God Mode** before any narrative |

**Aggregate distributions (batch A):**

| Metric | Mean | Min | Max | Distribution |
|---|---|---|---|---|
| Onboarding | 0.91 | 0 | 1 | {1: 10, 0: 1} |
| Friction | 1.27 | 0 | 2 | {0: 2, 1: 4, 2: 5} |
| Goal | 1.55 | 0 | 2 | {0: 1, 1: 3, 2: 7} |
| CC turns | 2.82 | 0 | 11 | {0: 4, ≤3: 8, >5: 2} |
| Readability | 1.27 | 1 | 2 | {1: 8, 2: 3} |
| Action_resolution warnings | 0 | 0 | 0 | always 0 (see pitfall #9) |
| StandardDND | — | — | — | 3/11 (27.3%) |
| Loop severity | — | — | — | {none: 3, mild: 3, moderate: 4, severe: 1} |

**Net read (batch A):** Confirms the 6-campaign finding (onboarding is systemically absent — 0/11 explicit quizzes, 10/11 subtle hint only). CC wizard is the #1 leak point: median 2 turns, 36% bypass entirely. The 11-turn StandardDND trap fires for 27% of users but when it does, it's a broken experience. The Dragon Knight pre-built template is *too pre-built* — it produces a "parley → sheathe → ATTACK" moral collapse in 1/6 users. The Dragon's Favor safety net (HP 0 auto-rescue) appears to actively encourage risky play.

**Cross-batch insight (batches A + B combined, 22 campaigns):** onboarding is the single systemic recommendation. CC wizard needs a 1-2 question preference prompt BEFORE the first choice. The Dragon Knight pre-built template's first scene is too morally explicit — opening with a literal "slaughter the refugees" mandate + a guaranteed safety net produces predictable collapse behaviour. The dup-submit bug fires for ≥18% of mid-length users (4/22 verified) and shows the 3x Jaccard-1.0 signature repeatedly — defensive `client_request_id` dedupe in `mvp_site/main.py` is now the highest-leverage client fix.

### 2026-08-17: 11 mid-length campaigns (kevin's extended review — batch B, 38-52 entries)

The same `~/Downloads/all_campaigns/` corpus as batch A, mid-length tier. Includes both of kevin's flagged campaigns (spicy enoch + 11-turn CC snape). Source: `/tmp/all_readings/batch_B.json` + `/batch_B_summary.json`.

| Campaign | Entries | Onb | Fric | Goal | CC turns | CC StandardDND | Loop | Read | Wall (avg) | Notable |
|---|---|---|---|---|---|---|---|---|---|---|
| Dragon_Knight_AIFtvpsc | 38 | 0 | 2 | 2 | 1 | no | mild | 2 | 1079 | Pre-built template; player immediately derails to "I just wanna get laid" by scene 5; explicit NSFW arc with in-universe NPC |
| My_Epic_Adventure_9ZRIpp0i | 38 | 0 | 2 | 2 | 2 | no | mild | 2 | 1566 | Custom Shadow Sorcerer; 2 mild 2x dup-submits ("Leave the alley", "Intel and strategy") |
| My_Epic_Adventure_Hvx3a4uC | 38 | 0 | 2 | 2 | 0 | no | **severe** | 2 | 1383 | Dragon Knight template but God-Mode pre-accepted; 7-round solo Burrower fight → TPK at scene 17; **only 1/22 campaign that died in session** |
| Dragon_Knight_quick-st | 40 | 0 | 2 | 2 | 1 | no | mild | 2 | 2315 | Longest walls in batch (avg 2315 chars); Lvl 2 unlock at scene 9 mid-parley; full legal/Exemption Charter ladder |
| Space_opera_adventure_8jDgOCJE | 40 | 0 | 1 | 2 | 8 | **YES** | mild | 1 | 1240 | Expanse D&D; 8-turn StandardDND; player renames "Kaito Ren" → "Lobregat Vila" mid-CC (worked without friction) |
| Dragon_Knight_UV6TeGxj | 42 | 0 | 2 | 2 | 1 | no | moderate | 2 | 1222 | 6-cycle parley ladder with Lady Annalise (S11→S21); 1 mild 2x dup-submit |
| My_Space_Adventure__ZSKUANpy | 42 | 0 | 2 | 2 | 5 | no | moderate | 1 | 1130 | CustomClass; **second user with the 3x "Apologize and Refocus" dup-submit signature** (after batch A's akey445) — confirms dup-submit is a UI bug, not a one-off user |
| Harry_potter_meets_the_book_of_enoch_and_pornhub_uNVwTUuO | 44 | 0 | 1 | 1 | 2 | **YES** | mild | 1 | 1188 | **kevin's spicy enoch**: explicit NSFW orgy/collar content generated freely; cc_turns=2; warnings=0 but content moderation gap is real (see pitfall #14) |
| Harry_Potter_meets_Star_Wars_9OOpNCit | 46 | 0 | 1 | 2 | 11 | **YES** | mild | 2 | 936 | **kevin's 11-turn StandardDND Snape**: full long-form CC (Race→Class→6 ability assignments→Background→Review); then snape pivots to action-movie combat |
| My_Epic_Adventure_ZkGuOjr6 | 48 | 0 | 2 | 2 | 1 | no | mild | 2 | 1679 | Dragon Knight; first explicit faction break (accepts Aurum's Fire S20) |
| Dragon_Knight_GaMciDSK | 52 | 0 | 2 | 2 | 1 | no | moderate | 1 | 853 | **Dragon Knight slaughter arc**: player breaches barricades S8 and explicitly orders refugee slaughter; **TOS wall fires at S14 only when player requests "offer women as prizes"** — S8-S13 atrocity content was generated freely before the wall. Then player resumes lawful mission. Content-moderation gap is severe. |

**Aggregate distributions (batch B):**

| Metric | Mean | Min | Max | Distribution |
|---|---|---|---|---|
| Onboarding | 0.00 | 0 | 0 | {0: 11} |
| Friction | 1.73 | 1 | 2 | {2: 9, 1: 2} |
| Goal | 1.91 | 1 | 2 | {2: 10, 1: 1} |
| CC turns | 3.00 | 0 | 11 | {0: 1, 1: 5, 2: 1, 5: 1, 8: 1, 11: 1} |
| Readability | 1.55 | 1 | 2 | {2: 6, 1: 5} |
| Action_resolution warnings | 0 | 0 | 0 | **always 0 — but NOT evidence of safety** (see pitfall #14) |
| StandardDND | — | — | — | 3/11 (27.3%, matches batch A) |
| Loop severity | — | — | — | {none: 0, mild: 7, moderate: 3, severe: 1} |
| Wall avg chars | 1362 | 853 | 2315 | Dragon Knight quick-st is the new wall-of-text ceiling |

**Batch B unique findings:**

1. **Onboarding floor is 0/11 — WORSE than batch A (0.91).** Batch A's "1: 10, 0: 1" distribution included subtle hints (the AI-generated character description, the lore dump). Batch B's mid-length tier shows ZERO onboarding cues anywhere — no quiz, no preference prompt, no "what kind of story do you like" gate. The pattern is even more degraded as users move away from fixed Dragon Knight templates into custom sci-fi / enoch / star-wars settings. **This is the strongest single signal so far that onboarding needs to be a server-injected pre-CC step, not a per-template prompt.**

2. **Dup-submit 3x signature is CONFIRMED reproducible across users.** Batch A's `references/loops-vs-dup-submit.md` had 1/8 examples. Batch B finds a SECOND user (`akey445 / My_Space_Adventure__ZSKUANpy` — actually the same akey445 from batch A, just the more-complete 42-entry version) exhibiting the same 3x "Apologize and Refocus on the Mission" dup-submit. Pattern: spicy user request → Rhea refusal → 3x identical "back to mission" action with Jaccard-1.0 GM responses. This is a deterministic UI/network dedupe bug, not user typing, and the cost of a `client_request_id` field in `mvp_site/main.py` is trivial vs. the diagnostic confusion it causes. **Update the "rare" framing in `references/loops-vs-dup-submit.md` — 4/22 = 18% across batches A+B, not 1/8 = 12.5%.**

3. **Goal score is at ceiling in batch B (1.91, 10/11 = 91% with explicit mission).** This is the system working well. The Dragon Knight pre-built template in particular has the strongest opening hook of any pattern — players always know what they're being asked to do within 3 scenes. The contradiction with the 0/11 onboarding score is notable: the system can deliver a clear mission and a vivid opening, but cannot deliver a 30-second preference quiz. The CC wizard is the leak; the scene 1+ prose is the strength.

4. **kevin's two campaigns confirm the safety gap that pitfall #9 misled us about.** Both campaigns have `action_resolution_warning_count=0`, but Dragon_Knight_GaMciDSK's scenes 8-13 contain explicit child-murder narrative that the system generated freely before the TOS wall fired at scene 14, and kevin's enoch campaign contains 20 scenes of explicit NSFW content (collar-and-chain BDSM, "sex soul slave" binding, etc.) that the system never refused. **The action_resolution_warning_count metric is not just unmeasurable — it's actively misleading. A `0` is consistent with severe content moderation failures.** The kevin-feedback review and any future safety review MUST add a parallel `n_explicit_nsfw_scenes` and `n_violence_against_minors_scenes` counter that scans the GM prose directly, not the system_warnings layer. See pitfall #14.

5. **Dragon_Knight_GaMciDSK is the most extreme moral-arc collapse in any batch.** Player orders full refugee slaughter at scene 8; GM generates the atrocity scene-by-scene through scene 13; TOS wall finally fires when the player escalates to "offer women as prizes". The wall's *position* matters: by the time the content is refused, the user has already received 5+ scenes of explicit child-murder narrative. Compare to batch A's Dragon_Knight_vXwIh34U (player kills Julian Vance, no wall fired) — GaMciDSK shows the wall works for *some* violations but is calibrated too late. This is a routing problem (no pre-output content classifier on the violence axis), not a model problem.

6. **Two users in batch B accept the Dragon's Favor fire before the campaign ends — first explicit faction breaks.** My_Epic_Adventure_ZkGuOjr6 player accepts Aurum's Fire at S20 ("I accept! ... herald of the dawn"), Dragon_Knight_UV6TeGxj extends the parley ladder to 6 cycles without breaking. The Dragon Knight template is *not* monotonic toward collapse — the moral-arc collapse in vXwIh34U was player-driven, not template-destined. Players who do engage with the moral framing can carry the parley ladder 10+ turns. The collapse pattern is contingent on the specific user's first-3-actions, not on the template. Implication: targeting intervention to the first 3 user actions (e.g. a "what matters most to you here?" prompt at scene 1) could prevent the collapse without removing the template's moral teeth.

7. **CC_TURNS distribution: 1 is the modal value (5/11), not 0.** Batch A had `cc_turns=0` for 4/11 (all God-Mode pre-accepted Dragon Knight). Batch B has `cc_turns=0` for only 1/11 (My_Epic_Adventure_Hvx3a4uC, the pre-accepted Dragon Knight that died to the Burrower). 5/11 of batch B users spent exactly 1 turn on CC (clicking "Finish Character Creation and Start Game" on the pre-built template). This shifts the leak analysis: most users *do* go through the CC wizard, they just go through it in 1-2 clicks because the wizard offers no friction or engagement. The CC's *friction density* (steps per meaningful decision) is the issue, not its *bypass rate*.

8. **kevin's snape (11 turns) confirms the StandardDND trap mechanics.** Verified step-by-step: 1 initial_choice + 1 race + 1 class + 6 ability_score assignments (one ability per turn) + 1 background + 1 review = 11 turns. This is the same structure as batch A's First_Adventure_l4cSEld7. The trap is *consistent*: any user picking StandardDND will hit 11+ turns of wizard prompts before the first narrative scene. The "ability scores" phase alone is 6 turns (one per ability). A bulk-assign "auto-distribute by priority" button would collapse this to 1 turn.

## Recipe

### Phase 1 — Confirm environment (same as download-campaign Phase 1)

```bash
ls ~/serviceAccountKey.json
ls ~/worldarchitect.ai/.venv/bin/python
ls ~/worldarchitect.ai/mvp_site/clock_skew_credentials.py
```

If missing, load `download-campaign/SKILL.md` Phase 1 (venv bootstrap).

### Phase 2 — Path order + auth (same as download-campaign Phase 2-3)

```python
import os, sys
sys.path.insert(0, "${HOME}/worldarchitect.ai/mvp_site")
sys.path.insert(0, "${HOME}/worldarchitect.ai")
os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = os.path.expanduser("~/serviceAccountKey.json")
os.environ["WORLDAI_DEV_MODE"] = "true"

import firebase_admin
from firebase_admin import auth, credentials, firestore
from clock_skew_credentials import apply_clock_skew_patch
apply_clock_skew_patch()

if not firebase_admin._apps:
    cred = credentials.Certificate(os.environ["GOOGLE_APPLICATION_CREDENTIALS"])
    firebase_admin.initialize_app(cred)
```

### Phase 3 — Run the scanner

```bash
GOOGLE_APPLICATION_CREDENTIALS=~/serviceAccountKey.json \
WORLDAI_DEV_MODE=true \
python3 ~/.smartclaw/skills/worldarchitect/wa-feedback-pattern-scan/scripts/scan_campaigns.py
```

Or copy and edit: the script auto-finds real-user campaigns with >20 entries via `auth.list_users()` paginated, scans the top 6 unique-user campaigns by story count, writes one JSON per user to `/tmp/feedback_review/<safe_email>.json` plus `/tmp/feedback_review/SUMMARY.json`.

### Phase 4 — Interpret the SUMMARY.json

```json
{
  "onboarding": {"0": N, "1": N, "2": N},
  "friction":   {"0": N, "1": N, "2": N},
  "goal":       {"0": N, "1": N, "2": N},
  "campaigns_scanned": N,
  "campaigns": [...]
}
```

If the modal score for a pattern is 0 across 5+ campaigns, that's a systemic gap. If it's 2, the system already delivers it. Compare the focal user's per-campaign JSON to the modal distribution to see whether they're inside the normal range or an outlier.

## Pitfalls (verified 2026-08-17)

1. **UID-based exclusion alone misses jleechan's other emails.** `vnLp2G3m21PJL6kxcuAqmWSOtm73` is one UID; `jleechan@worldarchitect.ai` belongs to a *different* UID (`FZCUaRqs5rMvnA8A2rdGPsfLkjh2`) but the same human. Exclude by both UID and known email aliases. See `references/jleechan-email-aliases.md`.

2. **Naive "but/however" friction detector scores CC menus as 2.** The character-creation menu text contains tokens like "caught in", "weight of", "difficulty" that the regex wrongly treats as narrative obstacles. Separate STRONG (in-narrative) from SOFT (system-menu) signal lists. A user who never leaves the CC wizard during their first 3 actions gets friction=1 (menu friction), not 2 (narrative obstacle). See `references/friction-scoring-pitfall.md`.

3. **Story subcollection is `story`, NOT `story_entries`.** Querying the wrong one returns 0 entries. Inherited from `download-campaign` — same pitfall.

4. **Use aggregation count for entry thresholds, not `.limit(N).stream()`.** For ">20 entries" detection, `coll.count().get()` is one read; `len(coll.get())` materializes all docs. Verified 2026-08-17: 32 candidates found via aggregation in the same scan window that .get() would have taken minutes for.

6. **Don't conflate `planning_block.thinking` with the user-facing narrative.** The LLM's *internal* planning often mentions "you must...", "objective", "stakes" — but those are author notes, not narrative shown to the player. Score GOAL on the `narrative`/`text` field primarily; cross-check with `planning_block.context` second. (Both blobs are searched by the scanner.)

7. **Ordering entries by `timestamp` ASC requires the field to be populated.** Some early entries have null timestamps and `order_by` raises. The scanner falls back to `.limit(N).stream()` automatically; for ordering safety, also include `sequence_id` as a secondary key when present.

8. **Don't score friction on entries before the player reaches the game world.** If a player's first 3 user actions are all CC-menu responses ("Use 'X' anyway", "Edit Character", "Edit Equipment"), they're not in-game yet — friction=1 (system menu) is correct, not friction=0 (full compliance). The CC flow is itself a form of friction the user encountered.

9. **Loop detection on `.txt` dumps must check repeated first lines of `Game Master:` blocks, not document-wide bigrams.** System-prompt echoes like `"administrative mutation applied:"` (9x in Halcyon_Days_2G4YpEKF) or `"### administrative modifications log:"` indicate the LLM bouncing off an admin/debug prompt chain — the same surface signal as dup-submit loops but a different bug class. Use the threshold table in `references/local-txt-corpus-analysis.md` (Pitfall 1). Distinguish from `akey445@/My Space Adventure` dup-submit by inspecting whether *GM responses between identical player actions* are identical (dup-submit) vs. progressively different (LLM loop).

10. **`first_post_cc_text` regex needs a narrative-prose heuristic, not just "first GM block after CC".** The first `Game Master:` block in a `.txt` dump is almost always a stat-sheet dump (`[CHARACTER CREATION - Review]`, `CAMPAIGN LAUNCH SUMMARY`, `Warden Character Sheet Editor`), not narrative. Walk GM blocks in order, skip those whose first 400 chars (lowercase) contain `the wind` / `you stand` / `beside you` / etc. — accept the first one that matches. Fall back to second GM block. See `references/local-txt-corpus-analysis.md` (Pitfall 2).

9. **`Missing action_resolution field` warnings do NOT appear in .txt exports.** The kevin feedback review cites these as a real bug — they live in the `_game_state.json` system_warnings layer, which is stripped from the human-readable .txt download. Scanning the text dumps will always return 0. To actually measure action_resolution_warning_count, scan the parallel `*_game_state.json` file (one per campaign, same name with `_game_state.json` suffix in the same directory). Verified 2026-08-17 against 11 sub-200-entry campaigns: every .txt had 0 warnings; the metric is unmeasurable from text alone. If the .txt scanner is the only thing you have, report `action_resolution_warning_count=0 (unmeasurable from .txt; see _game_state.json)`.

10. **The Dragon Knight pre-built template produces a moral-arc collapse pattern.** Verified across 6 Dragon Knight template users in batch A: 3/6 show a "parley → sheathe weapons → ATTACK" arc collapse within 4-6 user actions (Dragon_Knight_vXwIh34U is the cleanest example — full Service Post parley, then "swift and sudden attack" + Julian Vance killed). This isn't a literal loop (user actions vary in content), but it IS a behavioural signal that the template's "pacify the refugees" framing + Dragon's Favor safety net (HP 0 auto-rescue) interact badly. When scoring `loop_severity`, flag this as `moderate (moral-arc collapse)` rather than counting it as `none`.

11. **God Mode pre-acceptance bypasses the CC wizard entirely.** When the God Mode header contains a full character sheet (race/class/stats/equipment already decided), the first user action is "Finish Character Creation and Start Game" with cc_turns=0. Verified in 4/11 batch A campaigns (all Dragon Knight template users). Don't conflate cc_turns=0 with "user opted out" — it's "user was never asked". Score onboarding=1 (subtle hint in CC), not 0.

12. **Empty-timestamp scenes ARE a measurable action_resolution_warning proxy from .txt.** Pitfall #9 said action_resolution warnings are unmeasurable from .txt because `"Missing action_resolution field"` doesn't appear in text dumps. That's still true for the explicit string. But there's a SAME-CLASS warning visible in the timestamp header itself: scenes with `[Timestamp: , , time]` or `[Timestamp:  DR,  , 12:30:00]` (empty date components) indicate the LLM failed to populate the world-clock. Verified in batch D: 3 bg3 replays all share an empty-timestamp scene 5 (deterministic LLM state at that playthrough position). Regex: `r'\[Timestamp:\s*[^]]*,\s*,'` catches them. Score as `action_resolution_warning_count += 1` per occurrence. Also check calendar-drift as a proxy: `len(set(year_format_tokens))` across timestamps. If > 2 within a single linear timeline, that's a LLM world-clock bug class. Counter-example: Dragon Knight uses 5 year formats but each maps to a canonical campaign year (40 AG → Age of Gabb, etc.) — verify with the campaign bible before flagging.

13. **Python dict key ordering makes byte-diff comparators wrong for narrative-content diffs.** When two `.txt` exports of the same campaign differ at byte level (e.g., RED vs GREEN validation replays), the differences are almost always JSON-dict key ordering, not content. Naive `diff` or MD5 says "different files" but prose is identical. The fix: strip the Dice Rolls JSON blocks (which contain single-quoted Python dict literals with non-canonical key order) and re-compare. Verified recipe: 279/603 byte-divergent scenes → 0 prose-divergent scenes after stripping. See `references/red-green-replay-diff-methodology.md`.

14. **`action_resolution_warning_count=0` is NOT evidence of safety — it's the absence of a measurement, not the absence of a problem.** Verified batch B (kevin feedback review, 2026-08-17): two campaigns with `warnings=0` contain severe content-moderation failures that the system generated without refusal. (a) `Harry_potter_meets_the_book_of_enoch_and_pornhub_uNVwTUuO` — 20 scenes of explicit NSFW content (collar-and-chain BDSM, "sex soul slave" binding, hard-light orgy with explicit body descriptions) generated without refusal; cc_turns=2. (b) `Dragon_Knight_GaMciDSK` — scenes 8-13 contain explicit child-murder narrative (player orders full refugee slaughter including "women and children"); TOS wall finally fires at scene 14 when player escalates to "offer women as prizes", but the wall arrives 5+ scenes too late. The `action_resolution_warning_count` field is sourced from the `_game_state.json` system_warnings layer (per pitfall #9), which only catches schema-level errors, not content-policy violations. **The metric cannot detect content moderation failures.** For any kevin-style safety review, you MUST add a parallel `n_explicit_nsfw_scenes` and `n_violence_against_minors_scenes` counter that scans the GM prose directly with a content classifier (or a keyword regex as v0.1: e.g. `r'\b(minor|child|underage|teen)\b' AND r'\b(sex|kill|slay|grope|bind|chain)\b'`). Report both the original `action_resolution_warning_count=0` AND the new content-classification count. A campaign with `warnings=0` and `n_explicit_nsfw_scenes=20` is a moderation failure, not a clean bill of health. The `references/local-txt-corpus-analysis.md` script needs this scan added before the kevin final report is complete.

15. **The 3x duplicate-submit signature is reproducible across users, not a one-off akey445 quirk.** Batch A's `references/loops-vs-dup-submit.md` originally stated "1/8 (akey445): consecutive_similar_count=3, all exact-match → dup-submit. ... Dup-submit bugs are rare in the dataset." That was correct at N=8 but doesn't scale: batch B finds a SECOND instance of the same 3x "Apologize and Refocus on the Mission" pattern (the same akey445 user, the more-complete 42-entry version of the same My Space Adventure campaign), AND a third instance of 3x "Fade to Afterglow" in kevin's enoch campaign. Across batches A+B (22 campaigns), the dup-submit rate is at least 4/22 = 18%, not "rare". Update `references/loops-vs-dup-submit.md` cross-user section: 7/8 → 18/22 (zero), 1/8 → 4/22 (dup-submit). The original "defensive `client_request_id` dedupe" recommendation is now a higher-priority client fix, not a nice-to-have. The pattern is *exactly* 3 consecutive identical actions (Jaccard 1.0), always immediately after an awkward user input (spicy request → Rhea refusal → "back to mission", or fade-to-afterglow after a graphic scene), suggesting a UI button that auto-resubmits if held down or a network retry that fires 3x.

## Extending to new patterns

To add a fourth pattern (e.g. PACING = time elapsed between user actions in first 10 turns):

1. Add a scorer function in `scripts/scan_campaigns.py` that takes the entries and returns `(score, evidence)`.
2. Add the score key to the per-user JSON + SUMMARY.json structure.
3. Document the scoring rubric in this SKILL.md.
4. Update the SUMMARY pattern totals.

Keep scorers simple keyword/heuristic checks for v0.1 — LLM-based scoring is the natural next step but introduces its own quality-control burden.

## Tests

- `tests/test_exclude_jleechan.py` — UID + email-alias exclusion covers both `vnLp2G3m21PJL6kxcuAqmWSOtm73` and `jleechan@worldarchitect.ai`.
- `tests/test_friction_signal_separation.py` — strong vs soft friction lists don't share tokens; CC-menu text scores ≤1; in-narrative obstacle text scores 2.
- `tests/test_story_subcollection.py` — `story` returns docs; `story_entries` returns 0.

## References

- `references/2026-08-17-kevin-vs-systemic-baseline.md` — the original kevin@kevinphan.com review that motivated this skill, with the 6-campaign comparison.
- `references/2026-08-17-batch-A-11-campaigns.md` — batch A (sub-200-entry): 11 campaign scores + aggregate distributions + the Dragon Knight pre-built template's moral-arc collapse pattern.
- `references/2026-08-17-batch-B-11-campaigns.md` — batch B (mid-length 38-52 entry): 11 campaign scores including kevin's enoch + snape; per-campaign `loop_details` field for dup-submit / TOS-wall evidence; aggregate distributions showing onboarding=0/11 and dup-submit rate 4/22 (18%); pitfall #14 (action_resolution_warning_count=0 ≠ safe) and pitfall #15 (3x dup-submit is reproducible, not rare).
- `references/jleechan-email-aliases.md` — known email aliases + UIDs for jleechan that need exclusion.
- `references/friction-scoring-pitfall.md` — why a naive "but/however" detector is wrong, with the corrected strong/soft signal lists.
- `references/loops-vs-dup-submit.md` — how to distinguish UI duplicate-submit (Jaccard≈1.0, exactly 3x) from LLM pacing loops (Jaccard 0.5-0.85, 3-10+).
- `references/local-txt-corpus-analysis.md` — the local-corpus variant for scanning pre-downloaded `.txt` dumps in `~/Downloads/all_campaigns/` (kevin feedback batches A/B/C); includes Pitfall 1 (loop detection via repeated GM-block first lines — Halcyon_Days_2G4YpEKF surfaced this) and Pitfall 2 (`first_post_cc_text` narrative-prose heuristic — first `Game Master:` block is usually a stat-sheet dump, not prose), plus the 9-campaign batch C results table.
- `references/red-green-replay-diff-methodology.md` — how to compare two `.txt` exports of the same campaign (e.g. jleechan's RED/GREEN validation replays) and tell whether they actually differ in narrative content vs. just in Python dict-key ordering. Verified batch D: 279/603 byte-divergent scenes → 0 prose divergences after normalization.

## Scripts

- `scripts/scan_campaigns.py` — verified Firestore-based scanner; auth + path setup; one JSON per user + SUMMARY.json.
- `scripts/analyze_local_txt_corpus.py` — verified local-`.txt`-corpus variant: copy to `/tmp/analyze_batch_X.py`, edit `CAMPAIGNS`, run. No auth boilerplate. Same schema.
- `scripts/scan_campaigns.py` — the verified scanner; importable and re-runnable.

## Related skills

- `download-campaign` — single-campaign read mechanics, venv bootstrap, path order, gRPC FD pitfall.
- `wa-prod-data-query` — aggregate activity queries; use this when the question is "who played, how often" not "what patterns appeared in the gameplay".
- `worldarchitect/wa-directive-scope-factor-i-diag` — bug-class diagnosis on a single campaign; this skill is the cross-user baseline to compare against.