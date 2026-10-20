---
name: pr-fleet-rollup
description: Cross-repo N-day PR snapshot, kind-classified.
---

# PR fleet rollup — N-day cross-repo merge snapshot

## When to load

- "Give me a 14d / 48h / 7d PR report across the repos"
- "What shipped this week?" / "what's pending?" / "what got merged recently?"
- "Top bug fixes and feature requests from PR titles"
- "Compliance sweep of recent merges"
- A user asks to read existing `*-14d*.md`, `recent_pr_compliance_report*.md`, `*-48h-sweep*.md`, `*-pr-review-last-*days*.md` reports from `~/roadmap/` and refresh them
- Building evidence feeds for `code-review`, `repo-agents-evidence-contract`, or weekly Slack digests

This skill is the *aggregation* layer. Use `github-pr-workflow` for one PR at a time, and `agento_report` for agento-managed PRs only.

## Inputs you must have

- **Window**: N days (default 14). Express as `merged:>=YYYY-MM-DD` or `merged:>YYYY-MM-DD` in `gh pr list --search`. Decide `>` vs `>=` based on whether the boundary day is itself under audit.
- **Repo list**: pass a deterministic list. Default Jeffrey-org fleet under `jleechanorg/`: `worldarchitect.ai, agent-orchestrator, jleechanbrain, dark-factory, cmux, ai_universe, ai_universe_frontend, ralph, browserclaw, mcp_mail, cindil-health, hermes-agent, ez-gh-actions, disk_magician, worldai_claw, llm_inspector, jleechanbrain, heretic-lab`. Confirm `gh auth status` shows owner `jleechanorg` before assuming the prefix — `gh pr list` without the prefix returns a parse error.
- **Limit**: 200 per repo covers 14 days at current merge velocity; raise to 500 if any repo exceeds ~80 PRs in window.

## Core workflow (verified 2026-08-18)

1. **Probe local clones first.** `gh pr list` is fine but a local clone offloads rate-limit risk and gives you SHA/diff for free. For the jleechanorg fleet, local clones live in `${HOME}/<repo>` or `${HOME}/{projects,repos,code}/<repo>`. Skip missing repos quietly — `gh` will return 0 results, that's signal not error.

2. **Batch the queries.** Run all repos in one Python loop over `terminal()`. 18 repos run in ~10s when authenticated; no need for `--paginate` against `gh api`. Each result is JSON; parse with `json.loads`. Surface repo-by-repo counts first to flag the 13-of-18 repos that have zero merged PRs in the window.

3. **Classify with conventional-commit + agent-prefix tolerance.** Repo titles look like:
   - `[agento] feat(daemon): configure default reviewer queue`
   - `[claude/MiniMax-M3] fix(rewards): populate progress fields`
   - `gemini/gemini-3.7-flash: perf(ci): gate test.yml utility jobs`
   - `fix(dice): Strategy 4 recovery tracks last '}' anchor`

   Regex that handles every variant:

   ```python
   CONVENTIONAL_RE = re.compile(
       r"(?:^\[[^\]]+\]\s*)?"         # optional leading [agento] / [claude/MiniMax-M3] / [antig]
       r"(?:[A-Za-z0-9._/-]+:\s?)?"   # optional "model/ModelName:" leading tag (gemini/gemini-3.7-flash:)
       r"(?P<type>[a-zA-Z]+)"         # conventional-commit type word
       r"(?:\([^)]*\))?"              # optional (scope)
       r"(?P<sep>!?:|!|\s)"           # separator
   )
   TYPE_TO_KIND = {
       "feat":"feature","fix":"bug","revert":"bug",
       "chore":"chore","refactor":"chore","docs":"chore","test":"chore","style":"chore",
       "perf":"infra","ci":"infra","build":"infra","harness":"infra",
   }
   ```

   Heuristic fallback (no prefix match): first-word check on `fix(`, `feat(`, `chore`, `perf`, `docs`. Anything still unknown defaults to `chore`.

4. **Emit TWO artifacts** at the canonical paths:
   - `/tmp/gh-prs-14d.json` — shape `[{"repo","number","title","mergedAt","kind","url"}]`, sorted `mergedAt` desc. This is the machine-readable contract.
   - `/tmp/gh-prs-14d-summary.md` — human-readable: total count, by-kind breakdown, repo×kind pivot table, top-15 of each kind, top-10 chore. Companion to the JSON, not a replacement.
   - (Optional) `/tmp/gh-prs-raw.json` for the raw `gh pr list` payloads, in case downstream wants unsorted originals.

5. **No `repo:` prefix in URLs.** When `gh pr list` returns each PR's `url` field, use it directly. When it doesn't (some `gh` versions omit it in JSON), synthesize `https://github.com/<owner>/<repo>/pull/<number>`.

## Pitfalls

- **`gh` parse error with empty output.** If you forget the `owner/` prefix on a repo not in your default owner (e.g. `agent-orchestrator` without `jleechanorg/`), `gh` returns nothing — but with the owner it works fine. Always confirm `gh auth status` first.
- **Conventional-commit regex fails on `[agent] chore(...)`.** Make the leading `[xxx]` block optional and non-capturing — see step 3 regex.
- **Lowercased `feat` vs capitalized `Feat`.** Lower-case the `type` group before lookup.
- **`ui(` / `test(` prefixes with no conventional word.** These fall into the heuristic fallback or to `chore`. Don't try to over-classify.
- **Window boundary off-by-one.** `merged:>=2026-08-05` includes the boundary day; `merged:>2026-08-05` excludes it. Always use `>=` for a "last N days" report that should include today-ish.
- **Reports cited in the prompt often exist under different names.** When the user references `2026-08-18-latency-telemetry-defects.md`, the actual file may be `nextsteps-2026-08-18-latency-telemetry-defects.md`. `ls` + `grep` the prefix before declaring a file missing.
- **Limit too low.** A repo merging 100+ PRs in 14 days (worldarchitect.ai at the moment: 144) will silently truncate at `--limit 80`. Set 200 by default, 500 for any repo with 7d counts > 60.

## Cross-repo coverage in this user's fleet

| Repo                                | 14d merges | Typical focus                                                   |
|-------------------------------------|-----------:|-----------------------------------------------------------------|
| `jleechanorg/worldarchitect.ai`     |        144 | WA product: prompts, dice, sharing, CI, level-up, MCP            |
| `jleechanorg/dark-factory`          |         42 | Auto-factory daemon, reviewers, intake                          |
| `jleechanorg/worldai_claw`          |         27 | iOS / mobile parity, beads sync                                  |
| `jleechanorg/jleechanbrain`          |          8 | Launchd routines, BQ watcher, Slack handoff                     |
| Others (cmux, ai_universe, browserclaw, mcp_mail, cindil-health, hermes-agent, ez-gh-actions, disk_magician, llm_inspector, jleechanbrain, heretic-lab) | 0 | Quiet in this window — recheck in next 14d sweep |

Use the repo×kind pivot to spot emerging themes: e.g. surge in `chore` on `worldai_claw` usually indicates a docs-parity sweep; surge in `infra` on `worldarchitect.ai` indicates CI trim work.

## Verification checklist before declaring done

- [ ] `/tmp/gh-prs-14d.json` exists and parses; total record count matches the per-repo sum
- [ ] All records have `repo`, `number`, `title`, `mergedAt`, `kind`, `url` populated
- [ ] Repo breakdown sums match the per-`gh`-call results printed in the summary
- [ ] At least the top-15 lists per kind show in the markdown companion
- [ ] The prompt's specific reports (`*-14d*.md`, `nextsteps-2026-08-XX-*` etc.) were read for context — call out any that are missing under the requested name

## Companion artifact

- `references/gh-pr-list-recipes.md` — query variants (open vs merged, label filters, JSON field lists) and a worked sample from the 2026-08-18 14d sweep.
