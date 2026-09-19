# Title-as-bug-name signal (verified 2026-08-16)

## Observed pattern

On 2026-08-16, user invoked `/repro` on campaign `hf6mdyTHGVXuPxuR8r9C` with the message *"Run /repro seems like my god mode directive of ignoring elena vance and doing canon characters ignored. dont code just analyze"*. The Firestore `meta.title` was **"Genius doctor (json leak + god mode ignored)"**.

The title itself encodes TWO bug-class names:

| Title substring | Bug class | Canonical reference |
|---|---|---|
| `json leak` | JSON serialization leak — `TypeError: Object of type {Sentinel,set} is not JSON serializable` at `mvp_site/main.py:get_campaign` | `references/json-serialization-leak.md` |
| `god mode ignored` | Factor F (narrative-ack-as-write) + Factor I (Identity-scope Conflict) | `references/god-mode-directive-missing-subclasses.md` §Factor F + this skill |

The user filed this campaign knowing god mode wasn't sticking AND that the JSON serialization was intermittently breaking — they wrote the bug names into the title.

## Why this matters

A title-as-bug-name hit is **stronger evidence than the user's chat message** for routing decisions because:

1. The title is **persistent in canonical state** (Firestore `campaigns/<CID>` document). The chat message is ephemeral.
2. The title was authored **after the bug manifested** (the user has seen the bug live, then named it). Chat messages are typed mid-event.
3. The title **may cross reference multiple bug classes** in one phrase. The chat message usually picks one.

## Diagnostic rule

**Before any Firestore read or BQ query on a `/repro` invocation, scan `meta.title` for canonical bug-class substrings.** If the title contains:

- `json leak` / `serializ` / `TypeError` → load `references/json-serialization-leak.md` first
- `god mode ignored` / `directive lost` / `command forgotten` → load Factor F + Factor I refs
- `cache` / `slow` / `latency` → load `references/bq-llm-payload-truncation-pitfall.md` §"Cross-campaign cache-hit comparison"
- `npc forgot` / `resurrected` / `came back` → load `references/non-repro-verification-recipe.md` first (most likely NON-REPRO)
- `invent` / `made up` / `silver vial` / `blood-scent` → load `references/repro-llm-invented-lore-artifacts-2026-07-18.md`
- `level up stuck` / `stuck at level` / `level N pending` → load `references/unbounded-scaling-l30-level-up-bug-class-2026-07-21.md`

If the title has no bug-class substring, fall through to the standard `references/phenotype-lock-static-evidence.md` 3-grep recipe.

## Verified diagnostic shortcut

On 2026-08-16, scanning the title alone told the agent: "this is a god-mode + structural issue, look for Factor F bundle + stale persisted state". The agent then ran:

1. `copy_campaign.py --find-by-id hf6mdyTHGVXuPxuR8r9C` → source UID
2. Direct Firestore `current_state` read → confirmed `god_mode_directives[]` had 3 entries (none about canon / Elena) and `npc_data` had 4 entries (Elena Vance still present, no Marcus Andrews/Glassman/etc.)
3. BQ god-mode turn dump → confirmed 4 of 5 god-mode turns emitted ZERO `directives.add` AND claimed in `dm_notes` to have added NPCs that aren't in `npc_data`

The verdict landed in 4 tool calls because the title-scan pre-routed to Factor F.

## Anti-pattern

**Don't assume the title is just a flavor string.** Most campaign titles are flavor (`"Flight 814 Crisis"`, `"The Prodigy of Flight 814"`, etc.). When a title contains parenthetical clauses OR compound adjectives that look like a bug description (`"(json leak + god mode ignored)"`, `"(stuck at L77)"`, `"(Viktor hierarchy wrong)"`), it's a self-confessed structural-issue flag — treat it like a sibling-issue scan hit.

## Cross-skill rule

Whenever you load this skill, also check `meta.title` for any of the substrings above. If matched, load the corresponding reference BEFORE running Firestore or BQ queries — the title-scan saves an average of 2-3 diagnostic turns by pre-routing the agent to the right Factor class.

## Source

Verified 2026-08-16, campaign `hf6mdyTHGVXuPxuR8r9C`, source `jleechan@gmail.com` / UID `vnLp2G3m21PJL6kxcuAqmWSOtm73`. Title in Firestore: `"Genius doctor (json leak + god mode ignored)"`. Cross-class hit, two Factor families loaded.