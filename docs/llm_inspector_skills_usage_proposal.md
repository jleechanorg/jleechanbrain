# llm-inspector `--skills-usage`: current state + dormant-skill detection proposal

**Status:** Proposal (doc-only, no implementation in this PR)
**Bead:** orch-51op
**Repo owning the tool:** `jleechanorg/llm_inspector` (checked out locally at
`$HOME/projects_other/llm_inspector`)
**Date:** 2026-07-07

## Background

The dev-tooling backlog asked for an investigation into `llm_inspector --skills-usage`:
report which Claude/Codex/Hermes skills are actually being invoked vs. dormant, to help
prune the skill catalog (126+ skills live under `~/.claude/skills/`, `~/.agents/skills/`,
etc. — see `docs/skill-trim-round-6-2026-06-19.md` in that repo for the last manual trim).

**Finding: the flag already exists.** `llm-inspector analyze --skills-usage` is fully
implemented (`src/skills-usage.ts`, wired into `src/cli.ts`) and works today. This proposal
therefore does **not** ask "should we build this" — it documents current behavior and
proposes a scoped extension (dormant-skill detection) that the current implementation does
not cover.

## Goals

1. Document what `--skills-usage` currently does and does not do, so nobody re-implements
   it from scratch.
2. Identify the concrete gap between "report what was used" (done) and "report what to
   prune" (not done) — the actual ask from the backlog item.
3. Propose a minimal, additive extension with a defined data source, output format, and
   implementation sketch, without writing code (doc-only task).

## Tenets

- No silent implementation — this is a spec, not a PR that ships the feature.
- Reuse the existing scanner (`scanSkillsUsage`) rather than building a second log parser.
- Deterministic log/file parsing only (structured field extraction: `Skill` tool_use
  blocks, `<command-name>` tags, directory listings) — no semantic/LLM classification
  needed for this feature, so it does not trigger a ZFC violation.

## Current behavior (verified 2026-07-07)

Command: `node dist/cli.js analyze --skills-usage --days 30` (also documented in
`README.md`).

```text
=== Skills Usage ===
Window: last 30 days (since 2026-06-07)
Scanned 1591 session file(s), 101317 log entries in window.

| Skill / Command  | Source        | Count |
| ----------------- | ------------- | ----- |
| /copilot          | slash command | 33    |
| /goal             | slash command | 22    |
| /polish           | slash command | 19    |
| history            | Skill tool    | 8     |
| nextsteps          | Skill tool    | 8     |
...
| TOTAL              |               | 182   |
```

`--json` produces the same data as structured JSON
(`{ windowDays, since, scannedFiles, parsedLines, entries[], totalInvocations }`).

**Data source (existing):** `~/.claude/projects/*/*.jsonl` — Claude Code session
transcripts. For each JSONL line in the time window, it looks for:
- Assistant `tool_use` blocks where `name === "Skill"` → counts `input.skill`
  (source: `skill_tool`)
- User messages containing `<command-name>/foo</command-name>` → counts `/foo`
  (source: `slash_command`)

**Scope of "usage" today:** only Claude Code sessions. Codex (`~/.codex/sessions/`) and
Hermes (its own session/log store) are not scanned. The backlog item asked for
"Claude/Codex/Hermes skills" — today only the Claude Code leg is covered.

**What it does NOT do today:**
- It never reports skills that were *not* invoked. It has no notion of the full skill
  catalog — it only aggregates observed invocations. A skill with 0 uses in the window
  simply never appears in the table; there's no way to distinguish "dormant" from "doesn't
  exist."
- It doesn't scan Codex or Hermes session stores (see above).
- It doesn't cross-reference skill *names* used in logs against the actual `SKILL.md`
  files on disk (dead symlinks, renamed skills, or typo'd invocations would silently
  produce a usage count with no matching catalog entry, or vice versa).

This matches the actual backlog ask closely but not exactly: "report which skills are
actually being invoked vs dormant" requires a second data source (the catalog) that the
tool doesn't currently read.

## Proposed extension: `--dormant` / `--skills-usage --show-dormant`

### Data sources

1. **Usage side (existing, reuse as-is):** `scanSkillsUsage()` from
   `src/skills-usage.ts`, unchanged. Already reads `~/.claude/projects/*/*.jsonl`.
2. **Catalog side (new):** enumerate skill names from:
   - `~/.claude/skills/*/SKILL.md` (one level deep, matching the walker in the
     implementation sketch below) → skill name = directory
     name (matches `input.skill` naming convention observed in usage logs, e.g.
     `history`, `nextsteps`, `swarm`).
   - `~/.claude/commands/*.md` → slash-command name = `/` + filename stem (matches the
     `/copilot`, `/goal` style entries already in usage output).
   - Optionally `~/.agents/skills/*/SKILL.md` and `~/.codex/skills/*/SKILL.md` for parity
     with the Codex leg, once/if Codex session scanning is added (see "Known limitations"
     below — out of scope for the first cut).
   - Both catalog roots should be overridable via CLI flags (mirroring the existing
     `--projects-dir` override pattern in `skills-usage.ts`), so this works across
     machines with different `$HOME` layouts.
3. **Diff:** catalog set minus usage set (by name, source-typed: `skill_tool` catalog
   entries only diff against `skill_tool` usage entries; `slash_command` catalog entries
   only diff against `slash_command` usage entries — a skill and a command can share a
   name without being the same thing).

### Output format sketch

Text mode, appended after the existing usage table:

```text
=== Dormant (0 invocations in last 30 days) ===
Catalog: 126 skills, 187 slash commands (313 total)
Used:     51 skills,   38 slash commands  (89 total, 28.4%)
Dormant:  75 skills,  149 slash commands (224 total, 71.6%)

| Name                  | Source     | Catalog path                                    |
| ---------------------- | ---------- | ------------------------------------------------ |
| algorithmic-art         | skill      | ~/.claude/skills/algorithmic-art/SKILL.md         |
| antigravity-computer-use | skill    | ~/.claude/skills/antigravity-computer-use/SKILL.md|
| /benchg                | command    | ~/.claude/commands/benchg.md                      |
...
```

`--json` mode adds a parallel `dormant` array to the existing JSON shape:

```json
{
  "windowDays": 30,
  "since": "...",
  "entries": [ /* existing usage entries, unchanged */ ],
  "dormant": [
    { "name": "algorithmic-art", "source": "skill_tool", "path": "~/.claude/skills/algorithmic-art/SKILL.md" },
    { "name": "/benchg", "source": "slash_command", "path": "~/.claude/commands/benchg.md" }
  ],
  "catalogTotals": { "skills": 126, "commands": 187 },
  "usedTotals": { "skills": 51, "commands": 38 }
}
```

This keeps the existing `entries` field backward-compatible (no breaking change for any
script already parsing `--skills-usage --json`), and adds `dormant` as strictly additive.

### Implementation sketch (NOT implemented in this PR — spec only)

New module `src/skills-catalog.ts`:
- `scanSkillCatalog(dirs: string[]): Promise<CatalogEntry[]>` — walks each dir, one level
  deep, looking for `*/SKILL.md` (skill dirs) and `*.md` directly under a `commands/`
  root (slash commands). Returns `{ name, source, path }[]`.
- Pure filesystem enumeration, no parsing of SKILL.md content required for this feature
  (name + existence is enough) — keeps this squarely in the "deterministic
  transformation" ZFC exemption bucket, not semantic classification.

CLI wiring in `src/cli.ts`:
- Add `--show-dormant` boolean flag to the existing `analyze --skills-usage` subcommand
  (not a new top-level command — it's a view over the same scan).
- Add `--skills-dir <path>` and `--commands-dir <path>` overrides, defaulting to
  `~/.claude/skills` and `~/.claude/commands`, mirroring the existing
  `--projects-dir` pattern.
- `formatSkillsUsage()` in `skills-usage.ts` gets a sibling `formatDormantSkills()`, or an
  optional second table appended when `--show-dormant` is set.

Tests (mirroring `src/skills-usage.test.ts` conventions): fixture directories with a few
`SKILL.md` / command `.md` files, fixture JSONL usage logs, assert the diff excludes used
names and includes unused ones, and that `--json` output has both `entries` and `dormant`.

### Known limitations of the proposal itself

- **Naming collisions:** a skill directory name and a slash-command filename can coincide
  (e.g., `goal_harness` skill vs. potential `/goal_harness` command) with different
  invocation surfaces. The source-typed diff above handles this, but catalog scanning
  needs to preserve source type carefully — worth a unit test specifically for this case.
- **Aliases:** several skills are documented as aliases of each other (e.g., `/cs` →
  `/code-standards`, `/h` → `/goal_harness`, per the alias list surfaced in this session's
  skill listing). A dormant report that doesn't understand aliasing will flag `/cs` as
  dormant even if `/code-standards` was used heavily, or vice versa. First-cut proposal:
  do NOT attempt alias resolution (that would require parsing each command file's body
  for "Alias for X" markers — feasible but adds scope); ship the naive per-name diff
  first, note aliases as a known false-positive source in the tool's own README, and
  only add alias resolution if the false-positive rate proves annoying in practice.
- **Codex / Hermes skills:** out of scope for the first cut, per "Scope of usage today"
  above. The backlog item's "Claude/Codex/Hermes" framing implies a future second data
  source (Codex session JSONL under `~/.codex/sessions/`, and whatever Hermes uses for
  its own logs) feeding the same usage-aggregation shape. That is a separate, larger
  follow-up (new session-log parser per tool), not bundled into this dormant-detection
  proposal.
- **Time window sensitivity:** a skill can be "dormant in the last 30 days" but used
  quarterly (e.g., a release-process skill). The existing `--days` override already lets
  a caller widen the window; the dormant report should default to the same `--days` value
  the usage scan uses, so callers doing a "should I prune this" audit can rerun with
  `--days 90` before deciding.

## Testing

N/A — this is a proposal document, not a code change. No implementation, so no test run.
If/when implemented, tests would live in `src/skills-catalog.test.ts` and an extension of
`src/skills-usage.test.ts`, following the existing `vitest` conventions in that repo
(`npm test` / `vitest run src/`).

## Known Limitations

This document proposes but does not implement `--show-dormant`. It is scoped to the
Claude Code leg only; Codex and Hermes usage scanning are explicitly out of scope and
noted as follow-up work above. Any actual implementation requires review/approval before
landing, per this task's doc-only constraint.
