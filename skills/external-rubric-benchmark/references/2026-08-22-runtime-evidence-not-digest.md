# Reference — runtime evidence beats digest notes (2026-08-22)

This is a session-specific reference for the **CRITICAL — read the product's runtime evidence FIRST** rule at the top of `SKILL.md`. When the next session needs to understand *why* this rule exists, read this file.

## What happened

User task (Slack DM to hermes bot, 2026-08-22): *"Read this review and then read our campaigns from LLM wiki how does our product compare with tabled <https://arcanumrpgs.com/clients/tabled/>"*

The product is worldarchitect.ai. The "campaigns from LLM wiki" the user meant is the *primary-source runtime evidence* of the product in use — actual campaign transcripts.

## What the agent did wrong (twice)

The agent's home directory contained two relevant trees:

```
~/llm_wiki/wiki/campaigns/jleechan/
    ├── michele-fried-chicken/
    │   ├── michele-fried-chicken-001.md  (791 bytes)
    │   ├── michele-fried-chicken-002.md  (1110 bytes)
    │   ├── ... (42 total, all 700–1500 bytes each)
    ├── worldarchitect-harness-evaluation.md
    ├── worldarchitect-zfc-violations.md
    ├── seven-choice-patterns.md
    ├── psychological-profile.md
    └── ... (player-psychology analyses)

~/llm_wiki/wiki/sources/
    ├── michele-fried-chicken.md           (98,669 bytes — full primary transcript)
    ├── michele-fried-chicken-campaign.md  (2,528 bytes — overview)
    ├── michele-fried-chicken-001.md       (822 bytes — first entry)
    ├── ... (42 entry-digest files, 700–1300 bytes each)
    ├── michele-fried-chicken-Ofn9aEEy.md  (98,767 bytes — another full transcript)
    ├── 2026-08-04-campaign-noctune-bg3-v3.md  (42,955 bytes)
    ├── 2026-08-04-campaign-visenya-v5.md      (56,036 bytes)
    ├── 2026-08-04-bg3-campaign-empire-of-shadow.md  (79,152 bytes)
    └── ... (456 transcript files >30KB)
```

Both directories contained `michele-fried-chicken-001.md` ... `michele-fried-chicken-042.md`. The `wiki/campaigns/jleechan/michele-fried-chicken/` versions were digest summaries (~1KB each, 19 lines). The `wiki/sources/` versions were digest summaries too, but the parent also contained the actual full transcripts at 98 KB each.

**Round 1:** Agent read the digest files in `wiki/campaigns/jleechan/` (player-psychology analyses + campaign digest entries). Synthesized from those.

User pushback: *"I think you are confused. Its not about reading our code read all the campaign saved in the llm wiki repo to see how the campaigns play out."*

**Round 2:** Agent went back, read more of the same digest files in `wiki/campaigns/jleechan/`, briefly looked at the entry-level digests in `wiki/sources/`, and synthesized again from the digest content. Did NOT actually open the 98 KB primary-source transcript. Mentioned its existence in the synthesis but did not read it.

User accepted the second answer (so the loop closed) but the agent's own self-review is: round 2 was still wrong. The actual product evidence is in the 98 KB transcript, not in the digest summaries. Reading the transcript would have surfaced state-block mechanics, social-HP systems, real quit-and-come-back arcs, modern-domain subsystems (Type 41 license, LAPD case numbers, Instagram livestreams as narrative weapons, god-mode meta commands like `THINK:` and `continue the story`). All of those are absent from the digest entries.

## What the agent should have done (the heuristic)

When the user points at a directory, BEFORE reading any file in it:

1. `ls -la <dir>` to see the size distribution.
2. If there's a 5×+ size gap between organized summary files and primary-source files, the primary source is what the user wants.
3. If a *parent* directory contains both a digest-style directory AND a `sources/`/`raw/`/`transcripts/`-style directory, the user means the `sources/`-style one. The naming convention is consistent across the llm_wiki and similar evidence-first repos.

In the llm_wiki case:
- The user said "campaigns from LLM wiki."
- A scan of `~/llm_wiki/wiki/` showed both `campaigns/` and `sources/`.
- `sources/` contained the actual transcripts; `campaigns/` contained digest entries + player-psychology analyses.
- The user meant `sources/`. The agent picked `campaigns/` because the directory name matched the user's word.

**Better heuristic:** when the user names a noun ("campaigns", "sessions", "chats", "calls"), don't go to the directory with that exact noun. List the parent, find the directory whose *contents* look like primary evidence (large, unsynthesized, raw), and read THAT.

## How this lesson is encoded in the skill

The SKILL.md at the top now has a `## CRITICAL` section that:

1. Names the trap (digest files are seductive because they're named after the noun the user used and they're shorter).
2. Cites this exact incident with the file sizes (98 KB vs 1 KB) so a future session can pattern-match.
3. Provides the `ls -la` + size-gap heuristic.
4. Provides the parent-directory scan heuristic.
5. Warns that even when the user names the digest directory explicitly, double-check for a `sources/`/`raw/`/`transcripts/` sibling.

## Why this rule belongs in `external-rubric-benchmark` specifically

This skill is the one that fires on "compare our product against X's review" / "playtest against X's rubric" — exactly the pattern from the incident. Other skills (`repo-agents-evidence-contract`, `vendor-webcheck-first`) cover adjacent territory but not this exact failure mode. If a future variant of this task arises ("compare our product against Y's review", "see how Z plays out", "compare against Y's rubric"), the rule fires before any of the 6-step recipe runs.

## Related references

- `references/2026-08-13-worldai-arcanum.md` — the prior worked example for this skill (the previous worldai × Arcanum rubric audit). That run succeeded because the rubric author published everything needed; this run failed because the *user's* evidence was hidden inside a directory of digests.
- `repo-agents-evidence-contract` — adjacent skill covering the "AGENTS.md says prove it" pattern. Different failure mode (claim-without-evidence vs. read-wrong-file), complementary rule.
