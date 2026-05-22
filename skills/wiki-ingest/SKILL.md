---
name: wiki-ingest
description: Ingest a source document into the LLM wiki at ~/llm_wiki/. Delegates to ~/.claude/skills/wiki-ingest/SKILL.md for the canonical workflow.
---

# wiki-ingest — Hermes Wrapper

This skill is a pointer/delegate to the real workflow at `~/.claude/skills/wiki-ingest/SKILL.md`.

**Do not reimplement.** Read that file and follow it exactly.

## Quick Reference

Canonical wiki lives at: `~/llm_wiki/`

### 8-Phase Workflow (from ~/.claude/skills/wiki-ingest/SKILL.md)

**Phase 1: Resolve source file**
```bash
WIKI="$HOME/llm_wiki/wiki"
SOURCE="$HOME/llm_wiki/raw/$(basename "<arg>")"
mkdir -p "$(dirname "$SOURCE")"
cp "<arg>" "$SOURCE" 2>/dev/null || cp "$(pwd)/<arg>" "$SOURCE"
SLUG=$(basename "<arg>" | sed 's/\.md$//' | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]')
```

**Phase 2: Read source document** — fully read the source file.

**Phase 3: Read wiki context** — read `wiki/index.md` and `wiki/overview.md`.

**Phase 4: Create source page** — write `wiki/sources/<slug>.md`:
```markdown
---
title: "<title>"
type: source
tags: []
date: YYYY-MM-DD
source_file: <relative path>
---

## Summary
2-4 sentence summary.

## Key Claims
- Claim 1
- Claim 2

## Key Quotes
> "Quote here" — context

## Connections
- [[EntityName]] — how they relate
- [[ConceptName]] — how it connects
```

**Phase 5: Update index** — add entry to `wiki/index.md` under Sources section.

**Phase 6: Oracle impact check** — check if new content affects [[jeffrey-oracle]]. If so, append to `wiki/log.md`.

**Phase 7: Entity & concept extraction** — create entity pages for key people/companies/projects; create concept pages for key ideas/methods.

**Phase 8: Log** — append to `wiki/log.md`: `## [YYYY-MM-DD] ingest | <Title>`

## Wiki Structure
```
~/llm_wiki/
├── raw/              # ingested source files (copied here)
├── sources/          # source pages (type: source)
├── wiki/
│   ├── index.md     # curated source/concept/entity index
│   ├── overview.md  # wiki overview
│   ├── log.md       # ingest log
│   ├── entities/    # entity pages
│   └── concepts/    # concept pages
```

## Source Page Format Rules
- YAML frontmatter required: `title`, `type: source`, `tags`, `date`, `source_file`
- 2-4 sentence summary
- Key claims (bullet list)
- Key quotes with context
- Connections using wiki links `[[Name]]`
- Entity ratio target: >5% (entities vs total pages)
- Concept ratio target: >5%

## Skills Discovery Note
Per `## COMMIT: claude-skills-discovery`, always check `~/.claude/skills/` first for any domain that has a formalized workflow there. This skill exists as a Hermes-side pointer because Hermes is a separate agent from Claude Code but shares the same `~/.claude/skills/` canonical workflows.
