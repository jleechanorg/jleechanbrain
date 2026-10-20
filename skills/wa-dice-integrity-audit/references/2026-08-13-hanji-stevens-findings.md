# Hanji Stevens dice investigation — 2026-08-13

First audit run with this skill. Captured here so future runs on other
users can compare and so the bug pattern from Hanji's case can be
recognized quickly.

## Subject

- **Email**: hanjistevens@gmail.com
- **UID**: oPISN50TvEcH21uVYKzlZX1kKNv2
- **Campaign of interest**: 2G4YpEKFCPAVC7gjS3ET ("Halcyon Days", D&D 5e near-future cyber-warden)
- **Created**: 2026-08-07 00:04:03 UTC
- **Last played**: 2026-08-13 15:20:04 UTC (he came back today after a 6-day pause)
- **Story docs**: 222 (111 user + 111 gemini)

## Headline findings

- **d20 distribution is non-uniform**: chi-squared = 159.67 (df=19), p << 0.001
- **Mean face = 14.07** (expected 10.5) — biased upward by 3.57
- **StDev = 3.26** (expected 5.76) — rolls compressed toward the mean
- **Nat 20: 2 / 87 = 2.3%** (expected 5.0%)
- **Nat 1: 0 / 87 = 0.0%** (expected 5.0%) — zero natural ones across 87 d20 rolls
- **Success rate at DC 12-15: 89.8%** (expected ~35%)

## Critical caveats

1. **All 87 d20 rolls are NPC-side** (actor=gemini). PC rolls do NOT
   exist in structured form — user-actor story docs are bare
   `{actor, mode, part, text, timestamp}` with no dice data. Test 2
   (PC vs NPC) was therefore skipped.
2. **24/41 dice_rolls entries have no dice_server_seed** — 60% of NPC
   dice are unauditable post-hoc. The other 17 have seeds.
3. **4/17 seeded entries have rng_verified=False** despite valid SHA-256
   commitment — fabricated rolls with cryptographic fingerprint. This is
   the most serious bug class because the integrity layer *should* have
   blocked these but only logs a warning.
4. **debug_info.dice_strategy tagged on only 1/111 docs** — post-hoc
   audit of which RNG path each roll used is impossible at scale.
5. **debug_info.system_instruction_char_count = 534,750** for
   `gemini-3.5-flash-lite` — 21 prompt files bundled. Root cause of
   model fatigue / instruction-dropping that produces the dice issues.

## God-mode directive persistence trace

Hanji set 30+ rules via god mode across the session. Of those:

**Persisted into game_states/current_state**:
- PC attribute rebalancing (CHA 14, STR 9, DEX 12, etc.)
- Sechi NPC stat-block (AC 15, initiative 18, hp_max 100, Stremma Pistol)
- Hamicho Duran NPC with Fijini fishing-rod kit
- Equipment: Last Shot dual revolvers, 1d8 force damage
- Initiative tracking, combat_state structure
- Knowledge asymmetry: Sechi/Seda "cold", Namaro "bonded"
- Franklin-and-Lamar banter flag
- Dual-realm setting (New Halcyon vs Old Halcyon)

**Hit schema gaps (no field exists)**:
- `combat_formula` / `damage_formula` / `rpg_formula` (anime damage system)
- `rng_source` / `server_rng` / `secure_rng` (cryptographic RNG)
- `crit_rules` / `fumble_rules` (natural 20/1 special handling)
- Full NPC stat build-out (only Sechi + Hamicho got full stat blocks)

He re-asked for rules 2/3/4 on 2026-08-13 (today) in tighter language —
*"Why do i always win dice rolls"* → *"Reduce some values and make dice
rolls in general more harder"* → *"dice rolls more of like a strength vs
defense kind of thing"*. Same complaint 6 days apart, refined phrasing.

## Bugs filed

See jleechanorg/worldarchitect.ai issues:

- [#8872](https://github.com/jleechanorg/worldarchitect.ai/issues/8872) — User-actor docs have no dice field (PC rolls never structured)
- [#8873](https://github.com/jleechanorg/worldarchitect.ai/issues/8873) — dice_rolls entries have no actor/subject marker
- [#8874](https://github.com/jleechanorg/worldarchitect.ai/issues/8874) — 60% of response-side dice rolls have no dice_server_seed
- [#8875](https://github.com/jleechanorg/worldarchitect.ai/issues/8875) — **critical** — Fabricated rolls committed with valid seed but no code execution
- [#8876](https://github.com/jleechanorg/worldarchitect.ai/issues/8876) — System instruction 534K chars for Flash Lite (root cause)
- [#8877](https://github.com/jleechanorg/worldarchitect.ai/issues/8877) — debug_info.dice_strategy tagged on only 1/111 docs
- [#8878](https://github.com/jleechanorg/worldarchitect.ai/issues/8878) — Surface dice_server_seed + commitment in UI
- [#8879](https://github.com/jleechanorg/worldarchitect.ai/issues/8879) — Epic tracking all of the above

## Recommended fix order

1. #8875 (block fabricated-with-fingerprint — critical, user-facing)
2. #8876 (system prompt trim — root cause for several downstream bugs)
3. #8874 (close the unauditable 60%)
4. #8877 (strategy tagging for the rest)
5. #8872 + #8873 (PC-side capture + attribution)
6. #8878 (UI surface so users can verify)

## How to reproduce

```bash
# 1. Extract dice rolls
cd ~/worldarchitect.ai
WORLDAI_DEV_MODE=true .venv/bin/python \
    ~/.smartclaw/skills/wa-dice-integrity-audit/scripts/extract_user_dice.py \
    --email hanjistevens@gmail.com \
    --output /tmp/hanji_dice.json \
    --include-raw

# 2. Run chi-squared audit
WORLDAI_DEV_MODE=true .venv/bin/python \
    ~/.smartclaw/skills/wa-dice-integrity-audit/scripts/chi_squared_audit.py \
    --input /tmp/hanji_dice.json
```

Expected output: Test 1 FAIL (chi-squared=159.67 >> 30.14), Test 2 SKIPPED
(no PC rolls), Test 6 Nat 1 = 0%, all per-die tests on d20 fail.

## Related session artifacts (not in this skill)

- `/tmp/hanji_investigate.py` — schema survey (Step 3.4-3.7)
- `/tmp/hanji_rolls_deep.py` — dice_rolls legacy + seed verification
- `/tmp/hanji_stats.py` — accurate counts for issue bodies
- `/tmp/hanji_active.json` — raw roll dump

## Open question for next session

Hanji came back to the *same* campaign on 2026-08-13 (15:20 UTC) and
made the same dice complaint. Does he churn this time, or stick around
once #8875 ships? Worth watching his `rate_limits.last_updated` over
the next 7 days.