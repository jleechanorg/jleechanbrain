# Verified External Claims — 2026-08-06 Audit

Source artifact: `${HOME}/roadmap/ai-coding-advice-2026-08-06.md` (review task)

This is a worked example of the methodology in `SKILL.md` — useful as a template for similar audits.

## StrongDM / Attractor / AttractorBench

- `https://github.com/strongdm/attractorbench` — 200, real
- `https://github.com/strongdm/attractor` — 200, real (sibling repo, the NLSpec source)
- `https://raw.githubusercontent.com/strongdm/attractorbench/main/README.md` confirms:
  - Tiered benchmark: Tier 0 smoke (30 lines, 7 tests), Tier 1 unified LLM SDK (2,150 lines, 35 tests, 115 DoD items), Tier 2 coding agent loop (1,450 lines), Tier 3 attractor pipeline (2,080 lines)
  - Language-agnostic; agents pick implementation language. Contract: `make build`, `make test`, `./bin/conformance`
  - Deterministic mock-LLM verifier — no real API calls
  - Weighted composite score: 5% build + 5% self-test + 30% each T1/T2/T3 conformance
  - Cost-aware tracking (tokens and dollars per unit compliance)
  - Harbor-based runner
  - 2026-02-23 notice: "scores/totals not valid for ranking until additional burn-in runs"
- The 2389 post (Harper Reed, Mar 9 2026) independently confirms the attractor thesis and credits StrongDM/Justin McCarthy as originator

## Dan Shapiro chronology (critical distinction)

Two posts — do NOT conflate:

1. **Jan 2026**: "The Five Levels: from Spicy Autocomplete to the Dark Factory"
   - URL: `https://www.danshapiro.com/blog/2026/01/the-five-levels-from-spicy-autocomplete-to-the-software-factory/`
   - **Title-drift gotcha**: the "intuitive" slug `...to-the-dark-factory/` 404s; actual slug ends in `...to-the-software-factory/`
   - Contains the NHTSA-derived ladder: Level 0 = vi, Level 2 = pair-programming with model, Level 3 = Waymo-with-safety-driver (manager of AI tabs), Level 4 = robotaxi (PM writing specs), Level 5 = dark factory (lights off, nobody reviews code)
2. **Feb 2026**: "You Don't Write the Code. You Don't Read the Code Either."
   - URL: `https://danshapiro.com/blog/2026/02/you-dont-write-the-code/`
   - References the 5-levels post as a "completely random and unrelated" sidebar link. Does NOT itself contain the ladder.
   - Built Kilroy (`https://github.com/danshapiro/kilroy`) — Go CLI running attractor pipelines in isolated worktrees with CXDB checkpoints.
   - Also references Steve Yegge's "Gas Town"

## 2389.ai "The Dark Factory Is a .dot file"

- URL `https://2389.ai/posts/the-dark-factory-is-a-dot-file/` 301-redirects to `https://2389.ai/research/writing/the-dark-factory-is-a-dot-file/`
- Author: Harper Reed, 2389 Research Inc., Mar 9 2026, 8 min read
- Confirms: StrongDM attractor spec → independent convergence of Kilroy (Go, Shapiro), Mammoth (Go, 2389), Smasher (Rust, 2389), Tracker (Go, 2389) on the same 3-layer architecture (LLM client + agent loop + DOT pipeline)
- Dorodango framing: codegen software is disposable; specs are the durable artifact
- "Pipelines are the product" — DOT files are the reusable blueprints, runners are throwaway
- Products mentioned:
  - **Mammoth** (Go, Feb 2026) — 21-rule DOT linter, fan-in nodes with configurable join policies (all-success/majority/first-success), verification nodes that run shell commands at zero token cost, 5-phase node lifecycle
  - **Smasher** (Rust, Mar 2026) — 5 crates, HTMX frontend with SSE streaming, 6 built-in agent tools, smasher chat REPL
  - **Tracker** (Go, Mar 2026) — bubbletea TUI, automatic checkpointing to `.tracker/runs/`, weekend-scale build
  - **Coven** (referenced)
- Diagrammatic styles: vulnerability analyzer (all tool nodes, no LLM, deterministic, seconds, $0) vs Pong builder (every node is LLM call, 20 min, ~$15, nondeterministic)
- dotpowers.dot — 53-node, 7-phase pipeline cloning Jesse Vincent's Superpowers methodology

## Steve Yegge ZFC origin

- Article: "Zero Framework Cognition: A Way to Build Resilient AI Applications"
- URL: `https://steve-yegge.medium.com/zero-framework-cognition-a-way-to-build-resilient-ai-applications-56b090ed3e69`
- Published: **Oct 22 2025**
- Author: Steve Yegge (ex-Geoworks, Amazon, Google, Grab, Sourcegraph; 41K Medium followers)
- **Cloudflare gotcha**: direct curl returns 403. Wayback Machine has it.
- Wayback timestamp used: `20260720054812`
- Capture URL: `https://web.archive.org/web/20260720054812/https://steve-yegge.medium.com/zero-framework-cognition-a-way-to-build-resilient-ai-applications-56b090ed3e69`
- Availability probe: `curl "http://archive.org/wayback/available?url=steve-yegge.medium.com/zero-framework-cognition-a-way-to-build-resilient-ai-applications-56b090ed3e69"` → 200, 7 captures Oct 2025 – Jul 2026
- Key quotes: "AI to make decisions... if it's tricky to code, just give it to a model"; "Keep the smarts out of the client side!"; "ZFC violation!" catchphrase; "thin, safe, deterministic shell around AI reasoning"
- Local skill at `~/.claude/skills/zero-framework-cognition/SKILL.md:10` carries the verbatim quote "Models decide; server executes."
- Backstory chain in article: Martin Fowler's "Smart Endpoints and Dumb Pipes" (2014) → Karpathy's Software 2.0 (2017) → ZFC (2025)

## OpenRouter attribution headers (verified mid-2026)

Source: `https://openrouter.ai/docs/api-reference/overview`

- Canonical: `HTTP-Referer` — site URL for rankings on openrouter.ai
- Canonical: `X-OpenRouter-Title` — app title
- Legacy alias still accepted: `X-Title`
- Newer: `X-OpenRouter-Categories` — marketplace categories

When auditing claims citing only `X-Title` (the legacy alias), note that `X-OpenRouter-Title` is now canonical. Both still work; cite the current docs.

## Tavily status (2026-06-30 disabled claim — UNVERIFIABLE as vendor event)

- `https://status.tavily.com/` shows 100% uptime across API / MCP / Website for May–Aug 2026
- No public incident matching the 2026-06-30 date in the status history feed
- `api.tavily.com` returns 200 as of fetch time
- Doc phrasing was local-scoped ("Can't run `web_search`") — likely local account/key/config state, NOT a vendor outage
- **Conclusion**: the 2026-06-30 date is unverifiable as a vendor-side event. Disambiguate in the verdict.

## Premise mismatch (Phase 0 caught this)

Only 2 of the 6 claims in the review prompt were actually present in the artifact:

- Tavily disabled date (line 721 of source)
- OpenRouter attribution headers (lines 679 and 820)

Not present anywhere in the doc:
- AttractorBench claim
- Dan Shapiro essay claim
- 2389.ai claim
- ZFC origin attribution (the doc cites local SKILL.md, not Yegge directly)

**Lesson**: always run Phase 0 before chasing external verification. Half the work in this audit was confirming the claims were not even in the source — surfacing that up front saved time and gave the user a more useful verdict than pretending the claims were sourced from the doc.

## Tool chain that worked

1. `curl -sSL -o /dev/null -w "%{http_code} %{url_effective} %{size_download}\n" -A "Mozilla/5.0 (Macintosh)" <URL>` — existence + redirect + size
2. `python3 ex.py <URL>` with the strip-script-style-head-nav-footer extractor — grep-friendly text
3. `curl -sSL "https://web.archive.org/web/<TS>/<URL>"` — Cloudflare-blocked sources
4. `curl -s "http://archive.org/wayback/available?url=<URL>"` — Wayback probe (returns JSON with closest capture)
5. `curl -sSL "https://raw.githubusercontent.com/<OWNER>/<REPO>/main/README.md"` — GitHub repo content, bypasses HTML
