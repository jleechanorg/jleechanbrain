# MCP server inventory + token-cost removal proposal

**Status:** Proposal (investigation only — no config changes in this PR)
**Bead:** orch-51op
**Date:** 2026-07-07
**Scope:** Read-only investigation of `~/.claude.json` (`mcpServers` section) and
`~/.claude/mcp-strict.json`. **No file under either path was edited to produce this
document.** Any actual server removal/consolidation requires Jeff's explicit sign-off —
this doc only proposes candidates and rationale.

## Background

Every MCP server's tool schemas get injected into the system prompt on every API
turn, regardless of whether that turn uses the tool. `llm_inspector`'s own measurement
(`docs/on-demand-tool-profiles-solution.md` in that repo) put MCP tool defs at **~15-20%
of ~53K tokens of fixed per-turn overhead** in past captures — a real, recurring cost
paid on every single Claude Code turn across every project. This doc inventories what's
currently configured and flags consolidation/removal candidates.

## Goals

1. Enumerate MCP servers configured in `~/.claude.json` and `~/.claude/mcp-strict.json`
   without exposing the secrets embedded in those files.
2. Establish a real, repeatable token-cost measurement methodology (not guesses) using
   `llm-inspector`'s existing per-server breakdown, and show what it outputs for real
   captured requests.
3. Estimate current server cost using known/observed tool counts where precise live
   captures weren't available, clearly labeling estimates vs. measured numbers.
4. Propose removal/consolidation candidates with rationale, each requiring Jeff's
   sign-off before any config file is touched.

## Tenets

- Read-only investigation — `~/.claude.json` and `~/.claude/mcp-strict.json` were only
  `cat`/parsed, never written.
- No secret values (API keys, bearer tokens) are reproduced in this document — only
  server names, transport type, and tool counts.
- Measured data preferred over guessed data; every estimate below is labeled as such.
- Any recommendation to remove/consolidate is a **candidate for Jeff's review**, not an
  action taken.

## Current inventory

### `~/.claude/mcp-strict.json` — 12 servers

This is the curated "strict mode" MCP config (referenced from repo CLAUDE.md:
*"Register new MCPs in `~/.claude/settings.json` and `~/.claude/mcp-strict.json`"*), used
via `--mcp-config`/`--strict-mcp-config` for scoped sessions (e.g. agent-orchestrator
worktrees — confirmed via `~/.claude/history.jsonl` references from those worktrees). It
is **not** the default config auto-loaded by a plain `claude` invocation — that pulls from
`~/.claude.json` instead (see below). Roughly mirrors `~/.codex/config.toml`'s
`[mcp_servers.*]` sections (13 entries there, near-identical set).

| Server | Transport | Purpose |
|---|---|---|
| `mcp_mail` | HTTP (`localhost:8765`) | Inter-agent messaging (mcp-agent-mail) |
| `sequential-thinking` | stdio (npx) | Structured reasoning scratchpad |
| `context7` | stdio (npx) | Library/API documentation lookup |
| `gemini-cli-mcp` | stdio (npx) | Gemini CLI bridge |
| `grok` | stdio (npx) | Grok/xAI second-opinion queries |
| `playwright-mcp` | stdio (npx) | Browser automation |
| `perplexity-ask` | stdio (npx) | Perplexity search |
| `openclaw` | stdio (local binary) | OpenClaw gateway bridge |
| `beads` | stdio (local binary) | `br` issue tracker access |
| `chrome-superpower` | stdio (node, plugin) | Chrome browser automation (superpowers-chrome plugin) |
| `second-opinion-tool` | stdio (remote URL) | AI Universe multi-model second opinion |
| `slack` | stdio (local Go binary) | Slack API access |

### `~/.claude.json` — `mcpServers` section

- **Top-level `mcpServers`:** 1 entry — `slack` (separate from the `mcp-strict.json`
  Slack server; this is the connector registered globally, used outside strict-mode
  sessions).
- **Per-project `mcpServers`:** scanned all 22 `projects` entries in `~/.claude.json`.
  Only **1 of 22** projects has a project-scoped MCP server: `worldai-debug`, registered
  under the `worldarchitect.ai` project only (`mvp_site.worldai_mcp_stdio`, per
  `claude mcp list` inside that repo).
- **`claude mcp list` inside the `worldarchitect.ai` project** additionally shows
  `claude.ai Google Drive` (a hosted connector, `https://drivemcp.googleapis.com/mcp/v1`)
  — this is a Claude-native connector, not something registered in either JSON file
  directly, but it does add to the same per-turn tool-definition budget and should be
  counted in any full accounting.

**Net picture:** `~/.claude.json` itself is lean (1 global + 1 project-scoped server).
Nearly all of the MCP surface area lives in `~/.claude/mcp-strict.json`'s 12 servers,
which is the config most sessions actually run under day to day (confirmed by observing
`--mcp-config ~/.claude/mcp-strict.json` invocations in `~/.claude/history.jsonl`).

## Token-cost measurement methodology (real data)

`llm-inspector`'s `analyze` command already breaks MCP costs down **per server**, from a
real captured request body (`src/analyzer.ts:116-175`). Ran against 5 real historical
captures in that repo (`docs/captures/*.json`, captured 2026-04-21) via:

```bash
LLM_INSPECTOR_CAPTURE_DIR=$HOME/projects_other/llm_inspector/docs/captures \
  node dist/cli.js analyze --last 5
```

Consistent real numbers across all 5 captures (that session's server set — different from
today's `mcp-strict.json` list, since server configs drift over time, but this establishes
the *measurement methodology* and shows real per-tool cost variance):

| Server (that capture's config) | Tools | Bytes | Tokens | Tokens/tool |
|---|---:|---:|---:|---:|
| `mcp-agent-mail` | 11 | 19,961 | 5,705 | 519 |
| `worldai` | 10 | 4,738 | 1,357 | 136 |
| `plugin_superpowers-chrome_chrome` | 1 | 3,695 | 1,053 | 1,053 |
| `grok-mcp` | 3 | 2,668 | 763 | 254 |
| `claude_ai_Google_Drive` | 2 | 1,467 | 419 | 210 |

**Key finding: tokens/tool varies 4-8x across servers** (136 to 1,053 in this sample) —
tool *count* alone is a weak proxy for cost. A single Chrome-automation tool with a large
JSON schema (1,053 tokens) costs more than worldai-debug's entire 10-tool surface (1,357
tokens total). Any cost-cutting decision needs per-server *measured* tokens, not just a
tool-count heuristic.

**Limitation of this doc:** producing current, live per-server numbers for today's 12
`mcp-strict.json` servers requires running `llm-inspector start` and making a real Claude
Code request through the capture proxy (`ANTHROPIC_BASE_URL=http://localhost:9000`). That
changes the active session's routing, which is a live-environment action beyond a
read-only doc investigation — flagged here as the concrete next step (see "Recommended
next step" below), not performed in this pass.

### Estimated current tool counts (not measured — for triage prioritization only)

Known/estimated tool counts for today's `mcp-strict.json` servers, from public
documentation and this session's own live deferred-tool list (which includes the
`worldai-debug` and `slack` connector tool sets actually loaded for
`worldarchitect.ai`):

| Server | Tool count | Source | Estimated tokens (using measured avg ~344/tool, ±the 136-1053 range above) |
|---|---|---|---|
| `worldai-debug` | 10 | measured (same server, still 10 tools per `claude mcp list` output) | ~1,357 (measured value, unchanged) |
| `slack` (connector, `mcp__slack__*`) | 14 | counted from this session's live tool list | ~2,400-4,800 (est.) |
| `context7` | 2 | public: `resolve-library-id`, `get-library-docs` | ~400-1,200 (est.) |
| `sequential-thinking` | 1 | public: single `sequentialthinking` tool | ~200-1,000 (est.) |
| `perplexity-ask` | 1 | public: single search tool | ~200-1,000 (est.) |
| `grok` | 3 | measured in April capture (`grok-mcp (3)` = 763 tok) | ~763 (measured, likely stable) |
| `playwright-mcp` | ~20-25 | public: full browser-automation tool surface (navigate, click, type, screenshot, etc.) | ~2,700-26,000 (est., wide range — needs live measurement, likely the single largest server here) |
| `chrome-superpower` | 1 | measured in April capture (`plugin_superpowers-chrome_chrome (1)` = 1,053 tok) | ~1,053 (measured, likely stable) |
| `gemini-cli-mcp` | unknown | not probed | unknown — needs live measurement |
| `openclaw` | unknown | not probed | unknown — needs live measurement |
| `beads` | unknown | not probed | unknown — needs live measurement |
| `second-opinion-tool` | unknown | not probed | unknown — needs live measurement |
| `mcp_mail` (mcp-agent-mail) | 11 | measured in April capture | ~5,705 (measured, likely stable — this was the single most expensive server measured) |

**Caveat:** the "estimated tokens" column for unmeasured servers uses the observed
136-1,053 tokens/tool range as bounds, not a precise number. Treat this table as a
*triage* prioritization aid (which servers are worth measuring first), not a budget.

## Removal / consolidation candidates

All of the following require Jeff's explicit sign-off before any `mcpServers` entry is
edited or removed. None have been acted on.

1. **Browser automation is triple-registered: `playwright-mcp` + `chrome-superpower` +
   the `claude-in-chrome` connector.** The repo's own `browser-testing` skill already
   states a preference order — aside CLI/aside-mcp is primary, Playwright MCP is an
   explicit fallback, and `mcp__claude-in-chrome__*` is forbidden for browser-testing
   use. Despite that documented preference, all three tool surfaces still load into
   every turn's budget. `playwright-mcp` alone is the single largest estimated server
   above (~20-25 tools). **Candidate: demote `playwright-mcp` and `chrome-superpower`
   to on-demand/session-scoped loading** (per the on-demand toggling design already
   proposed in `llm_inspector`'s `docs/on-demand-tool-profiles-solution.md`) rather than
   always-on, since the documented primary path (Aside) doesn't route through MCP at
   all.
2. **Three overlapping "ask another model" servers: `grok`, `gemini-cli-mcp`,
   `second-opinion-tool`.** The skill catalog already has `/secondo`,
   `/second_opinion`, `advice`, and `ai-universe-second-opinion-workflow` doing
   multi-model fan-out via CLI subprocess calls (not MCP tool-call overhead sitting in
   the request). **Candidate: audit whether `grok`/`gemini-cli-mcp`/`second-opinion-tool`
   MCP servers are still exercised directly (vs. the skill-based dispatch paths), and
   consolidate to whichever path is actually used** — this needs the dormant-usage data
   from the companion `llm_inspector --skills-usage` proposal
   (`docs/llm_inspector_skills_usage_proposal.md`) extended to MCP tool calls, not just
   Skill-tool/slash-command usage, since MCP tool_use invocations aren't currently
   tracked by that scanner either.
3. **`context7` and `perplexity-ask`** are both narrow, single/dual-purpose lookup
   tools (library docs; web search) that overlap with the general-purpose `WebSearch`/
   `WebFetch` built-ins and `research`/`deep-research` skills. **Candidate: measure
   actual invocation frequency before deciding** — low marginal cost each (1-2 tools),
   so this is a lower-priority candidate than #1/#2 above.
4. **Two independent Slack integrations**: the `slack` entry in `mcp-strict.json` (Go
   binary, stdio) and the top-level `slack` connector in `~/.claude.json`. Worth
   confirming these aren't both loaded simultaneously in the same session (redundant
   tool schemas for the same underlying API) — flagged for verification, not a
   confirmed duplicate since they may serve genuinely different scopes (strict-mode
   worktree sessions vs. default sessions).

## Recommended next step (not performed here — read-only scope)

Run `llm-inspector start` + a single real Claude Code turn through the capture proxy,
then `llm-inspector analyze --skills-usage`-style per-server breakdown against **today's**
12-server `mcp-strict.json` config, to replace the "estimated" column above with measured
numbers before Jeff decides on any removals. This is a live-environment action (changes
`ANTHROPIC_BASE_URL` for one test session) and was intentionally not done in this
doc-only, read-only investigation pass.

## Testing

N/A — this is a read-only investigation and proposal document. No code or config was
changed; nothing to test. The "measured" numbers above came from re-running
`llm-inspector analyze` against pre-existing capture files already checked into that
repo's `docs/captures/` — that command was executed and its real output is quoted above,
not fabricated.

## Known Limitations

- Per-server token costs for 5 of 12 `mcp-strict.json` servers (`gemini-cli-mcp`,
  `openclaw`, `beads`, `second-opinion-tool`, and current-config `playwright-mcp`/
  `slack`) are estimates or unknowns, not measurements — see "Recommended next step."
- This doc does not attempt to resolve whether `mcp-strict.json` and `~/.claude.json`
  servers are ever loaded simultaneously in the same session (transport/precedence
  semantics weren't fully traced) — flagged as candidate #4 above for follow-up, not
  resolved here.
- No MCP server was disabled, removed, or edited to produce this document.
