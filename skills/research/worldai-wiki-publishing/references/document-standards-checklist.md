---
title: "Document-Standards Checklist — worldai_wiki campaign-template pages"
created: 2026-08-18
tags: [document-standards, worldai-wiki, campaign-template, pre-publish-audit]
---

# Document-Standards Checklist — worldai_wiki campaign-template pages

The 13-check audit the user invoked with `/document-standards` (verbatim OOB, 2026-08-18, HotD Ashen Crown). Run before opening any PR to `jleechanorg/worldai_wiki` on a campaign-template page. Re-run after every page update.

## The 13 checks (priority order)

| # | Check | Why it matters | What "pass" looks like |
|---|---|---|---|
| 1 | Frontmatter present + all 5 keys | `SCHEMA.md` enforced; page won't render correctly in wiki nav without these | `title:`, `created:`, `updated:`, `type:`, `tags:` all present in the `---` block at the top of the file |
| 2 | All tags in `SCHEMA.md` taxonomy | `lint_wikilinks.py` enforces; ad-hoc tags break wiki taxonomy queries | `tags: [...]` uses only values from the canonical list — `meta, placeholder, wa-campaign, wa-character, wa-comparison, wa-faq, wa-game, wa-glossary, wa-history, wa-mechanic, wa-persona, wa-prompt, wa-system, wa-tutorial` |
| 3 | Zero `[[wikilinks]]` | `lint_wikilinks.py` enforces; GitHub renders `[[X]]` as literal brackets | 0 occurrences of `[[...]]` anywhere in the page |
| 4 | ≥ 2 outbound markdown links to other wiki pages | `SCHEMA.md` enforced; orphan pages are invisible | `[Label](../concepts/X.md)` style; ≥2 such links in the page body |
| 5 | Self-contained: zero private-repo links + zero local paths | Pitfall #21; players don't have private-repo access | 0 occurrences of `github.com/jleechanorg/worldarchitect.ai` and 0 occurrences of `${HOME}/...` |
| 6 | Copy-paste bible is a single clean ` ```text ` block, no BEGIN/END markers, no nested fences | Pitfall #16; BEGIN/END markers leak into player paste | exactly 2 fences total (open + close), open fence is ` ```text `, fence content has no `BEGIN_COPY_PASTE_BIBLE` and no `END_COPY_PASTE_BIBLE` |
| 7 | Page ≤ 250 lines (AGENTS.md cap) | AGENTS.md enforced; over-cap pages fail CI | `wc -l queries/<slug>.md` ≤ 250 |
| 8 | Lead-paragraph customization hook present | Pitfall #20; players need to see customization promise before scrolling | A blockquote `> You can pick your own gender, class, ...` line in the first 1,000 chars |
| 9 | Post-launch description ("What to expect on your first session") | Pitfall #15; players get dropped into chat/UI with zero context otherwise | A subsection titled "What to expect on your first session" or equivalent |
| 10 | LLM-edit meta-prompt included | Enables player customization before pasting | A blockquote starting "You are an expert narrative designer and Game Master..." in More Details |
| 11 | Quick Setup + More Details structure present | Jeffrey's verbatim OOB 2026-08-05 ("let's make two main sections") | `## 1. Quick Setup` and `## 2. More Details` H2 headings both present |
| 12 | Related section with safe links (all resolve) | Pitfall #11; broken Related links break lint on next edit | `### Related` subsection with links to pages that exist in `concepts/` or `queries/` |
| 13 | All relative paths in the page resolve | Pitfall #22; broken paths break nav | Every `../concepts/X.md`, `../queries/X.md`, `images/...` resolves to a real file |

## Audit recipe (inline Python, ~30 seconds)

```python
from pathlib import Path
import re

page_path = Path("${HOME}/.worktrees/worldai_wiki-hotd-ashen-crown/queries/house-of-the-dragon-ashen-crown-rhaenyra.md")
page = page_path.read_text()

# Check 1: frontmatter
fm_match = re.match(r"---\n(.+?)\n---\n", page, re.DOTALL)
assert fm_match, "No frontmatter block"
fm_keys = [l.split(":")[0] for l in fm_match.group(1).split("\n") if ":" in l]
for key in ["title", "created", "updated", "type", "tags"]:
    assert key in fm_keys, f"Missing frontmatter key: {key}"

# Check 2: tags in taxonomy
VALID_TAGS = ['meta', 'placeholder', 'wa-campaign', 'wa-character', 'wa-comparison',
               'wa-faq', 'wa-game', 'wa-glossary', 'wa-history', 'wa-mechanic',
               'wa-persona', 'wa-prompt', 'wa-system', 'wa-tutorial']
m = re.search(r"tags: \[(.+?)\]", page)
used = [t.strip() for t in m.group(1).split(",")]
invalid = [t for t in used if t not in VALID_TAGS]
assert not invalid, f"Invalid tags: {invalid}"

# Check 3: zero [[wikilinks]]
assert not re.findall(r"\[\[[^\]]+\]\]", page), "[[wikilinks]] present"

# Check 4: ≥2 outbound internal links
md_links = re.findall(r"\[([^\]]+)\]\(([^)]+)\)", page)
internal = [l for l in md_links if not l[1].startswith("http")]
assert len(internal) >= 2, f"Only {len(internal)} internal links, need ≥2"

# Check 5: self-contained
assert not re.findall(r"github\.com/jleechanorg/worldarchitect\.ai\b", page), "Private repo link"
assert not re.findall(r"${HOME}/[^\s)]+", page), "Local path"

# Check 6: single clean fence, no BEGIN/END in fence content
fences = [l for l in page.split("\n") if l.startswith("```")]
assert len(fences) == 2, f"Expected 2 fences, got {len(fences)}"
assert fences[0] == "```text", f"Open fence should be ```text, got {fences[0]!r}"
inner = page.split("```text")[1].split("```")[0]
assert "BEGIN_COPY_PASTE_BIBLE" not in inner, "BEGIN_COPY_PASTE_BIBLE in fence"
assert "END_COPY_PASTE_BIBLE" not in inner, "END_COPY_PASTE_BIBLE in fence"

# Check 7: ≤250 lines
lines = page.split("\n")
assert len(lines) <= 250, f"Page is {len(lines)} lines (cap 250)"

# Check 8: lead-paragraph customization hook
assert "pick your own gender" in page.lower(), "No customization hook in lead"

# Check 9: post-launch description
assert "What to expect on your first session" in page, "No post-launch description"

# Check 10: LLM-edit meta-prompt
assert "Editing the bible with an LLM" in page, "No LLM-edit meta-prompt"

# Check 11: Quick Setup + More Details structure
assert "## 1. Quick Setup" in page and "## 2. More Details" in page, "Structure missing"

# Check 12: Related section with safe links
assert "### Related" in page, "No Related section"
for link in ["how-to-play-worldai", "CampaignDesign", "CharacterCreation",
             "CampaignWizard", "Combat"]:
    assert link in page, f"Safe link missing: {link}"

# Check 13: all relative paths resolve
base = page_path.parent
for label, target in md_links:
    if target.startswith("../") or target.startswith("./") or target.startswith("images/"):
        full = (base / target).resolve()
        assert full.exists(), f"Broken relative path: {target} -> {full}"

print(f"13/13 checks passed")
```

## Common fixes (when a check fails)

| Failing check | Fix |
|---|---|
| 1: frontmatter key missing | Add the key to the `---` block at the top |
| 2: ad-hoc tag | Remove from `tags: [...]` (or add to SCHEMA.md taxonomy if it's a new valid tag) |
| 3: `[[wikilink]]` | Replace with `[Label](../path/Page.md)` |
| 4: <2 internal links | Add more cross-references in the Related section or body |
| 5: private-repo or local path | Replace with `[Label](https://github.com/jleechanorg/worldai_wiki/tree/main/...)` for public wiki self-refs, or remove the link entirely |
| 6: BEGIN/END markers in fence | Use awk to strip: `awk 'NR==1{next} NR>1 && /END_COPY_PASTE_BIBLE/{exit} {print}' /tmp/slim.txt > /tmp/clean.txt` |
| 7: > 250 lines | Compress Customize / Troubleshooting / Full-setup-walkthrough tables to single-paragraph forms |
| 8: no customization hook | Add `> You can pick your own gender, class, subclass, dragon name, parent swap, look, starting relationship, and pretty much anything else.` to the lead paragraph |
| 9: no post-launch description | Add a "What to expect on your first session" subsection with 2-3 sentences about what the AI DM narrates first |
| 10: no LLM-edit meta-prompt | Add the standard "expert narrative designer" blockquote to More Details |
| 11: structure missing | Reorganize into Quick Setup + More Details (Pitfall #15) |
| 12: Related links broken | Verify with `ls ${HOME}/projects/worldai_wiki/{concepts,queries}/` before writing; only link to existing pages |
| 13: relative path broken | The relative path resolves to nothing on disk; either create the target file or change the link to one that resolves |

## Verified working example

**2026-08-18 HotD Ashen Crown:** Initial draft was 267 lines (over the 250 cap) and had 4 ad-hoc tags (`hotd, hardcore, dance-of-the-dragons, tv-canon-verified`) not in the SCHEMA.md taxonomy. Two patches applied:
1. **Tag trim:** Removed the 4 ad-hoc tags; kept `wa-campaign, wa-tutorial, wa-character`. Check 2 passed.
2. **Line trim:** Compressed the Customize section's 8 bullets to one paragraph, the Troubleshooting section's 5 bullets to 3, and the Full-setup-walkthrough table (8 rows) to a 4-line paragraph. Total: -22 lines. Check 7 passed (245 lines).

Result: 13/13 checks passed. PR #9 commit `485417a` shipped with the audit summary in the Slack thread reply: "13/13 document-standards checks passed."

## What this audit does NOT check

- **Lint-wikilinks script** (`scripts/lint_wikilinks.py`) — runs as part of CI. This audit is a manual pre-publish check; the script catches what regex can resolve at parse time. See Pitfall #11 for the gap between manual check and script.
- **HTTP URL availability** — the audit only checks relative paths. For external URLs (Wikipedia, etc.), use `curl -fsS -A "Mozilla/5.0" -L --max-time 12 -o /dev/null -w "%{http_code}" <url>` to verify (Pitfall #22).
- **AI DM compliance** — running the bible through an AI DM sim is a separate workflow (see `campaign-design-rpg-bible` User Pref #15). `/document-standards` covers the wiki page's structural correctness, not the bible content's runtime correctness.
