# Friction-scoring pitfall (verified 2026-08-17)

## The trap

The first version of `scan_campaigns.py` scored friction 0-2 by looking for any of these tokens in the GM's response after each of the first 3 user actions:

```
but, however, you can't, you cannot, blocked, obstacle, resist, danger, attack,
fail, refuse, denied, stopped, barrier, guard, intercept, prevent, you must first,
roll, difficulty, challenge, die, dies, wound, hurt, defeated, rejected
```

Across 6 real-user campaigns, this produced friction=2 for **all 6** — including cases where the user's first 3 actions were entirely inside the character-creation wizard (e.g. "Use 'X' anyway", "Edit Character", "Edit Equipment"). The reason: the GM's CC-wizard response text contains high-friction vocabulary like "weight of", "caught in", "difficulty" that the regex wrongly treated as in-narrative obstacles.

This made the scoring useless as a cross-user signal — every campaign scored 2 regardless of whether the GM actually pushed back on the player.

## The fix

Split the signal lists:

- **STRONG (in-narrative obstacles):** "you can't", "blocked", "resist", "attack", "fail", "refuse", "denied", "roll", "die", "wound", "defeated", "rejected", "you fail", "attack hits", "you take [damage]", etc. These mark the GM pushing back *inside the story world*.

- **SOFT (system menu / CC flow):** "character creation", "edit character", "what aspect would you like", "are you sure", "do you want to", "are you certain", "would you like to", "banned list", "menu", "select", etc. These mark the system imposing friction via UI, not narrative.

Score = `max(strong_seen, soft_seen)`. Strong → 2, Soft-only → 1.

## Why this matters

The user's question was "does the GM introduce obstacles to the first action, or does it just accept whatever the user typed?" A naive keyword count over-credits CC menus (which are friction the *system* imposes, not the *story*). Distinguishing the two lets us answer the actual question, and reveals a real pattern: **once a player is in-game, the GM reliably pushes back** (5/6 scored 2 in the corrected scan); **during CC, the only friction is menus**.

## Reusable

The strong/soft split applies to any "did the system push back?" scorer. The same pattern works for evaluating whether the GM asks for clarification (strong: "you need to specify X"; soft: "please select an option"), whether it introduces consequences (strong: "X is now wounded"; soft: "X stat changed in inventory"), etc.

## Verified result (corrected, 2026-08-17)

| Campaign | First 3 user actions | Friction (corrected) |
|---|---|---|
| kevinzsalleh@gmail.com / Dragon Knight Round 5 | CC + in-game (Prefect demanding slaughter) | 2 |
| hanjistevens@gmail.com / HALCYON DAYS | CC menu + 2 in-game | 2 |
| pickyourfavouritememory@gmail.com / My Epic Ballsac Dragonurphace | in-game (dragon battle context) | 2 |
| thiago.hirai@gmail.com / My Epic Adventure | CC + 2 in-game (Winter-Mourn march) | 2 |
| nordicsuccubus@proton.me / Dragon Warrioress | ALL 3 inside CC menu | 1 |
| mushrooming.fungus@gmail.com / Dragon Knight | CC + 2 in-game (Vespera conversation) | 2 |

The nordicsuccubus case (friction=1) is now correctly identified as "the only friction the user encountered was the CC wizard itself" — a meaningful product signal.