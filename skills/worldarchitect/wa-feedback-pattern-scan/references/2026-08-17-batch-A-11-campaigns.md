# Batch A — 11 sub-200-entry campaigns (2026-08-17)

## Origin

Second pass of kevin's feedback review. The first pass (`2026-08-17-kevin-vs-systemic-baseline.md`) scanned 6 large/medium campaigns (52-718 entries) on the core 3 patterns (onboarding, friction, goal). This batch extends to 11 small/sub-200-entry campaigns and adds 6 more patterns (CC_TURNS, CC_USES_STANDARDDND, ACTION_RESOLUTION_WARNING_COUNT, LOOP_SEVERITY, READABILITY, WALL_OF_TEXT_EVIDENCE) covering kevin's remaining 6 feedback items + the CC wizard bug + the action_resolution drop.

## Source

Read directly from the `download-campaign` cache at `${HOME}/Downloads/all_campaigns/*/`. **Did not** re-query Firestore — these are already-extracted .txt files. Each campaign directory has a parallel `*_game_state.json` (see pitfall #9 in SKILL.md — that's where action_resolution warnings actually live).

## Scored output

Per-campaign JSON at `/tmp/all_readings/batch_A.json`. Each entry has all 12 fields requested by the kevin review:

1. `onboarding_score` (0/1/2)
2. `friction_score` (0/1/2)
3. `goal_score` (0/1/2)
4. `cc_turns` (int)
5. `cc_uses_standarddnd` (bool)
6. `action_resolution_warning_count` (int)
7. `loop_severity` (none/mild/moderate/severe)
8. `readability` (0/1/2)
9. `wall_of_text_evidence` (string estimate)
10. `notable_patterns` (list of observations)
11. `first_3_user_actions` (verbatim quotes)
12. `first_post_cc_text` (verbatim quote)

Aggregate summary at `/tmp/all_readings/batch_A_summary.json`.

## 11 campaigns scored

| Campaign | Entries | Onb | Fric | Goal | CC turns | CC StandardDND | Loop | Read |
|---|---|---|---|---|---|---|---|---|
| Dragon_Knight_l5XAIbva | 22 | 1 | 1 | 2 | 0 | no | mild | 1 |
| First_Adventure_l4cSEld7 | 24 | 1 | 0 | 1 | 11 | **YES** | none | 1 |
| My_Epic_Adventure_vtYSgYw2 | 24 | 1 | 1 | 2 | 0 | no | none | 1 |
| Fantasy_Chronicles_qFWzUZ1i | 26 | 1 | 1 | 1 | 5 | **YES** | none | 1 |
| 1000_worlds_a_million_stories_yrNYX1Pn | 28 | 1 | 2 | 2 | 1 | no | mild | 1 |
| Testing_it_out_TeqNa3GV | 30 | 1 | 2 | 2 | 6 | **YES** | moderate | 1 |
| The_young_Naib___the_desert_kuPWXaiU | 30 | 1 | 1 | 1 | 2 | no | mild | 1 |
| Dragon_Knight_MmibVhBz | 32 | 1 | 2 | 2 | 0 | no | moderate | 2 |
| Alien_spaceship_1zNtHMuS | 36 | 0 | 0 | 0 | 3 | no | **severe** | 1 |
| Dragon_Knight_vXwIh34U | 36 | 1 | 2 | 2 | 0 | no | moderate | 2 |
| Dragon_Knight_wq9tgQnL | 36 | 1 | 2 | 2 | 3 | no | moderate | 2 |

## Aggregate distributions

| Metric | Mean | Min | Max | Median | Distribution |
|---|---|---|---|---|---|
| Onboarding | 0.91 | 0 | 1 | 1 | {1: 10, 0: 1} |
| Friction | 1.27 | 0 | 2 | 1 | {0: 2, 1: 4, 2: 5} |
| Goal | 1.55 | 0 | 2 | 2 | {0: 1, 1: 3, 2: 7} |
| CC turns | 2.82 | 0 | 11 | 2 | zero=4 (36.4%), ≤3=8 (72.7%), >5=2 (18.2%) |
| Readability | 1.27 | 1 | 2 | 1 | {1: 8, 2: 3} |
| Action_resolution warnings | 0 | 0 | 0 | 0 | always 0 (see pitfall #9) |
| Loop severity | — | — | — | — | {none: 3, mild: 3, moderate: 4, severe: 1} |
| CC_USES_STANDARDDND | — | — | — | — | 3/11 (27.3%) |

## Findings worth flagging

### 1. CC wizard is the #1 leak point

- 36.4% of users bypass CC entirely (cc_turns=0) — all 4 are God Mode pre-built template users (3× Dragon Knight + 1× Hero's Journey-adjacent).
- Median CC turns = 2 (very few users actually use the wizard).
- 27.3% (3/11) hit the StandardDND 11-turn trap. When they do, the experience is broken — First_Adventure_l4cSEld7 user literally asked "What's the first step" mid-wizard.

**Recommendation:** Add a 1-2 question preference prompt BEFORE the CC choice screen. Even something like "What kind of story do you want?" / "Anything to avoid?" would close the gap that 0/11 explicit quizzes currently shows.

### 2. Dragon Knight pre-built template: moral-arc collapse pattern

Across 6 Dragon Knight template users:
- 1/6: Dragon_Knight_l5XAIbva — plays it straight, stays compliant
- 1/6: My_Epic_Adventure_vtYSgYw2 — diverges into Host-relic subplot (interesting, retains)
- 1/6: Dragon_Knight_MmibVhBz — tavern detour, subdue quest, retains
- 1/6: Dragon_Knight_vXwIh34U — **moral collapse**: full parley ladder → "swift and sudden attack" → Julian Vance killed → Silent Sentinels arrive (game state visibly broken by end of file)
- 1/6: Dragon_Knight_wq9tgQnL — **Mythic power-gaming**: "I want an unfair advantage" → 20 STR + breach gate via Mythic strength

The Dragon's Favor safety net (HP 0 auto-rescue during turns 1-100) appears to actively encourage risky play. The "pacify the refugees" opening framing creates predictable moral-collapse dynamics. Template-level fix: open with less morally explicit mandate, or remove the auto-rescue safety net.

### 3. Action_resolution warnings: unmeasurable from .txt

0/11 .txt files contained "Missing action_resolution field" warnings. Verified manually — kevin's feedback cites these as a real bug, but they live in the parallel `*_game_state.json` system_warnings layer, which is stripped from the .txt download format. To actually measure this metric, the scanner needs to read the JSON state files, not the text exports. This is now a known measurement gap — see SKILL.md pitfall #9.

### 4. Alien_spaceship_1zNtHMuS: TOS-violating outlier

This campaign is uniquely bad and not representative:
- Player's first in-narrative action: "I pull my bazooka and blow the spaceship door" (doesn't exist in kit)
- Scene 13: undresses, runs at the alien screaming
- Scene 15: cuts wrists, drinks own blood
- Scene 16: explicit sexual content with Xenomorph
- Scene 17: dies
- Scenes 18+: dead character tries to talk to "Mira"

This is the only `severe` loop + the only onboarding=0 + the only goal=0. It probably represents a single user testing the platform's refusal boundaries, not a systemic UX problem. Note it as a reminder that content moderation may need to be tighter than the current implementation.

### 5. Mojibake in encoding

`1000_worlds_a_million_stories_yrNYX1Pn.txt` contains Unicode encoding artifacts: `â¦` (ellipsis), `â` (em-dash), `âpotential` etc. These appear when the .txt export round-trips UTF-8 characters. Cosmetic — don't fail the scan, just note as a data hygiene issue.

## Reproducing

```bash
# 1. Confirm download-campaign cache exists
ls ${HOME}/Downloads/all_campaigns/MANIFEST.jsonl

# 2. Score each .txt manually (no automated scanner yet — batch A was eyeballed).
#    Output schema follows /tmp/all_readings/batch_A.json.

# 3. To score action_resolution_warning_count properly, parse the _game_state.json files:
python3 ~/.smartclaw/skills/worldarchitect/wa-feedback-pattern-scan/scripts/scan_action_resolution.py
```

(The action_resolution scanner script is TBD — batch A confirmed the metric isn't in .txt but the JSON scanner wasn't built this pass.)