# Hermes Skills Resolver

Routes user phrases to skill entries. Each section is a skill with its canonical trigger phrases.

---

## skillify — skillify this, make this proper, add tests and evals, run skillify workflow

**File:** `skills/skillify/SKILL.md`

## sk — /sk, /skillify, skillify this, alias for skillify

**File:** `skills/sk/SKILL.md`
**Triggers:** /sk, /sk this, /sk the workflow, /sk the recipe, skillify alias
**Note:** Thin pointer to the canonical `skillify` skill. Resolves to the same 10-item checklist and the same Hermes self-mod Phase 0 contract.

## agento

**File:** `skills/agento/SKILL.md`
**Triggers:** agento, ao, agent orchestrator

## agento_report

**File:** `skills/agento_report/SKILL.md`
**Triggers:** agento report, ao report, agent orchestrator status

## antigravity-computer-use

**File:** `skills/antigravity-computer-use/SKILL.md`
**Triggers:** antigravity, control google, automate google

## bidi-cmux-alignment

**File:** `skills/bidi-cmux-alignment/SKILL.md`
**Triggers:** steer ao-primary, bidi cmux, bidirectional alignment, operator prompts

## browser-headless-default

**File:** `skills/browser-headless-default/SKILL.md`
**Triggers:** headless browser, hide browser, browser mode, chrome mode, headed mode forbidden, show browser denied, browser headless policy, no visible chrome

## browserclaw

**File:** `skills/browserclaw/SKILL.md`
**Triggers:** browserclaw, capture browser traffic, playwright

## read-gemini-share-link — read this gemini link, capture this gemini share, gemini.google.com/share, share.gemini.google

**File:** `skills/read-gemini-share-link/SKILL.md`
**Triggers:** read this gemini link, capture this gemini share, gemini.google.com/share, share.gemini.google, what does this gemini.google.com link say, get the content from gemini share, save this gemini chat
**Note:** Gemini share pages are PUBLIC — no auth gate. Capture challenge is JS hydration, not auth. Plain Playwright Chromium with a 12s wait works.
**Companion:** `skills/browserclaw/SKILL.md` (used as the headless-Chromium harness for `cookies inject`)
**Verified:** 2026-08-10 against `share.gemini.google/hZXboZihmwYc` and `gemini.google.com/share/1a3d2d1f2753` → both URLs serve the same conversation; ~50K chars captured each → [jleechanorg/llm-wiki PR #24](https://github.com/jleechanorg/llm-wiki/pull/24)

## read-grok-shared-link — read grok share link, capture grok conversation, grok.com/share

**File:** `skills/read-grok-shared-link/SKILL.md`
**Triggers:** read grok share link, capture grok share, grok.com/share, what does this grok link say, fetch grok conversation, grok share url
**Note:** Grok share pages are Next.js / Turbopack React SPAs where the conversation renders client-side. Uses Aside REPL (`openTab` + 8s wait + `body.innerText`) or Playwright headless Chromium.
**Companion:** `skills/aside-browser-default/SKILL.md`, `skills/read-blocked-public-content/SKILL.md`
**Verified:** 2026-07-31 in Slack thread C0AUXSVFSA2/1785551502.183539 for Warcraft 3 D&D Campaign bible extraction.

## vendor-share-link-reader — vendor share links, ai share url, read share link, don't ask user

**File:** `skills/vendor-share-link-reader/SKILL.md`
**Triggers:** vendor share link, ai share url, grok share, chatgpt share, gemini share, perplexity share, read share url, extract share link, fetch shared chat
**Note:** Umbrella skill for reading public SPA/React AI vendor share pages. Mandates running local extraction recipes (Aside REPL / headless Playwright) rather than asking the user to copy/paste.
**Companion:** `skills/read-grok-shared-link/SKILL.md`, `skills/read-gemini-share-link/SKILL.md`
**Verified:** 2026-08-20 in Slack thread C0AUXSVFSA2/1787226134.658509.

## claude-code-claudem

**File:** `skills/claude-code-claudem/SKILL.md`
**Triggers:** claudem, claudem coding, claudem delegation, claude code via claudem, claude code via minimax, claude code minimax, MiniMax claude code, M3 coding worker, delegate coding to minimax, run claudem in tmux, claudem -p, claudemc, claudeme, claudeminimax, claudeminimaxc, claude minimax, use MiniMax M3, MiniMax M3 coding
**Note:** Thin wrapper over the bundled `claude-code` skill. Same two modes (print + tmux) but binary = `claudem` (alias `claudeminimax`, the bashrc-routed MiniMax M3 variant) instead of `claude`. `claudem` is a bashrc shell function (NOT a binary on $PATH); for non-interactive callers (pytest, launchd, GitHub Actions), use `bash -lic 'claudem …'`. **This is the default skill for ordinary coding delegation** in `workspace/SOUL.md` (`Agent Dispatch Policy`); AO via `agento`/`dispatch-task` is explicit opt-in only via `/af` or `/auto-factory`. No other slash command, alias, or natural-language override routes to AO by default. The full skill lives on PR #800 (`feat/claude-code-claudem-wrapper`).
**Common Confusions:**
- **vs `claude-code`** — `claude-code` is the bundled general skill (binary = `claude`, routes to Anthropic first-party, real Claude Opus/Sonnet quality). This wrapper exists only to swap the binary. Use `claude-code` when you need real Claude judgment; use this skill as the default for routine coding delegation routed through MiniMax.

## cmux

**File:** `skills/cmux/SKILL.md`
**Triggers:** cmux, terminal multiplexer, send to terminal, send key, workspace surface, capture pane, read screen, list workspaces

## cmux-codex-autoapprove

**File:** `skills/cmux-codex-autoapprove/SKILL.md`
**Triggers:** autoapprove, approval worker, scan approvals, cmux approval

## cmux-surface-report-4h

**File:** `skills/cmux-surface-report-4h/SKILL.md`
**Triggers:** cmux surface report, cmux 4h report, cmux inventory, cmux health digest, 4h cmux check, what is cmux doing, cmux status

## claude-code-claudem

**File:** `skills/claude-code-claudem/SKILL.md`
**Triggers:** claudem, claudem coding, claudem delegation, claude code via claudem, claude code via minimax, claude code minimax, MiniMax claude code, M3 coding worker, delegate coding to minimax, run claudem in tmux, claudem -p, claudemc, claudeme, claudeminimax, claudeminimaxc, claude minimax, use MiniMax M3, MiniMax M3 coding
**Note:** Thin wrapper over the bundled `claude-code` skill. Same two modes (print + tmux) but binary = `claudem` (alias `claudeminimax`, your bashrc-routed MiniMax M3 variant) instead of `claude`. `claudem` is a bashrc shell function (NOT a binary on $PATH); for non-interactive callers (pytest, launchd, GitHub Actions), use `bash -lic 'claudem …'` to source the bashrc. Confirmed 2026-07-24: `claudem -p` round-trips to MiniMax M3 in ~6-8s. Verified 2026-07-27: `claudem -p --output-format=json --verbose` reports `MiniMax-M3` in `modelUsage` with `canonicalModel=minimax-m3, provider=firstParty`. **This is the DEFAULT coding-delegation skill** (`workspace/SOUL.md` Agent Dispatch Policy) — when in doubt, delegate to `claudem` on a clean worktree. AO via `agento`/`dispatch-task` is explicit opt-in only via `/af` or `/auto-factory`. No other slash command, alias, or natural-language override routes to AO by default.
**Common Confusions:**
- **vs `claude-code`** — `claude-code` is the bundled general skill (binary = `claude`, routes to Anthropic first-party, real Claude Opus/Sonnet quality). This wrapper exists only to swap the binary. Use `claude-code` when you need real Claude judgment; use this skill as the default for routine coding delegation routed through Minimax.
- **vs `agento` / `dispatch-task`** — `agento` and `dispatch-task` spawn AO workers (tmux-managed, hermes-supervised) for multi-hour PR remediation. `claudem` (this skill) is the DEFAULT for ordinary coding delegation — single-shot print mode, or tmux PTY for multi-turn — and is the right answer for new code, refactors, PR-sized work, and inline-coding-then-PR flows. Reach for AO only when the user typed `/af` or `/auto-factory`. Multi-step coding work does NOT default to AO.
- **Anti-pattern: `claude -p` with `ANTHROPIC_BASE_URL` set manually** — never override env vars by hand to force MiniMax routing. Always call `claudem`, which sets the env vars at the right scope and exits cleanly.

## humanizer

**File:** `skills/humanizer/SKILL.md`
**Triggers:** humanize, remove ai writing, make it sound human

## llm-narration-format-clarifier

**File:** `skills/llm-narration-format-clarifier/SKILL.md`
**Triggers:** llm dropped, llm invents the format, narration drift, show both, show all, format hint needed, add a worked example, prompt is too vague, llm paraphrase, never abbreviate, the narrative is missing, the roll is missing, narration too terse, format hint, make the llm consistently format, /narration-clarify

## meeting-prep

**File:** `skills/meeting-prep/SKILL.md`
**Triggers:** meeting prep, prepare for meeting, briefing for meeting, who is meeting

## sym

**File:** `skills/sym/SKILL.md`
**Triggers:** sym, symphony daemon

## todoist-due-drafts

**File:** `skills/todoist-due-drafts/SKILL.md`
**Triggers:** todoist due, due drafts, process email tasks

## dark-factory — slash command aliases (/f, /factory)

**File:** `~/.claude/skills/dark-factory/SKILL.md`
**Triggers:** /f, /factory
**Note:** Resolve this before generic dispatch and follow the canonical rule in `~/.claude/CLAUDE.md`.

## finish-the-job

**File:** `skills/finish-the-job/SKILL.md`
**Triggers:** finish the job, finish it, finish this, finish that, drive to conclusion, see this through, take it all the way, don't stop halfway, why did you stop, hands off mode, hands-off mode, fullsend, full send, take it from here, i started but didn't finish, work started but didn't finish, stalled thread, threads that stalled, threads i started but didn't finish, skillify hermes to be hands off, make hermes hands off, /finish, /auto, auto, automate this, do it autonomously, your call, handle it, ship it, merge it

## finish — slash command (/finish)

**File:** `.claude/commands/finish.md`
**Triggers:** /finish, /finish <goal>

## auto — slash command alias (/auto)

**File:** `.claude/commands/auto.md`
**Triggers:** /auto, /auto <goal>, auto, make it autonomous, hands off

## launchd-autonomy-report — slash command (/launchd-autonomy-report)

**File:** `.claude/commands/launchd-autonomy-report.md`
**Triggers:** /launchd-autonomy-report, score hermes on the left/right-shift tenet, tenet violation detector, autonomy report run, signals A–F, 48h lookback + slack search + /ms cross-reference


## always-pr-never-local-edit

**File:** `skills/workflow/always-pr-never-local-edit/SKILL.md`
**Triggers:** make a PR, open a PR, create a PR, where is the PR, did you make the PR, push the branch, stop doing local changes, never leave local changes, always PR, open the PR, ship it, local edits hanging, dangling commit, push and open the PR, local commit ask then push, stop doing stuff without making a PR

## drive-pr-to-green

**File:** `skills/workflow/drive-pr-to-green/SKILL.md`
**Triggers:** green this PR, /green, green up, drive to green, stop stopping halfway, why did you stop halfway, dont ask me just finish, next time finish the work, actually fix and then merge, do it directly, self merge the PR, fix coderabbit and merge, fix PR comments and merge, finish the PR

## ao-babysit

**File:** `skills/ao-babysit/SKILL.md`
**Triggers:** babysit, watch ao worker, monitor agent, ao session died, keep watch on agent, steer agent

## ao-spawn-minimax-worker

**File:** `skills/ao-spawn-minimax-worker/SKILL.md`
**Triggers:** spawn minimax worker, use minimax CLI, use M3 model, use MiniMax M3, ao spawn minimax, minimax agent, use minimax for AO, M3 worker, minimax PR, minimax branch

## x-to-skill

**File:** `skills/x-to-skill/SKILL.md`

## slack-thread-routing-investigation

**File:** `skills/devops/slack-thread-routing-investigation/SKILL.md`
**Triggers:** slack thread, wrong thread, self-rooted, self threaded, thread routing, thread_ts broken, slack mcp, conversations_add_message, use slack mcp, post not in thread, reply went to wrong thread, /learn slack, /skillify slack mcp, slack formatting broken, emoji fragmented, block kit fragment
**Triggers:** x-to-skill, turn tweet into skill, tweet to skill, share tweet

## wa-prod-data-query

**File:** `skills/wa-prod-data-query/SKILL.md`
**Triggers:** wa prod data, wa retention, wa real users, wa last week, wa this week, who played wa, wa active users, wa signup to first turn, wa engagement, review wa real users, analyze wa retention, real user firestore wa, wa campaigns from real users, real user activity wa, find real wa users, wa user count, wa bounce rate, wa funnel, last week real users

## reddit-competitor-complaints

**File:** `skills/reddit-competitor-complaints/SKILL.md`
**Triggers:** reddit competitor monitor, track reddit complaints, reddit sentiment, daily reddit digest, monitor ai dungeon on reddit, launchd reddit job, competitor reddit intel, pullpush.io, pullpush monitor, reddit complaint digest, ai text rpg reddit, friends and fables reddit, voyage reddit, set up daily reddit digest, /learn reddit monitor

## test-tui-claude-feature-via-cmux

**File:** `skills/test-tui-claude-feature-via-cmux/SKILL.md`
**Triggers:** test claude code feature, verify /, does / work, is the slash command working, slash command test, claude code picker, advisor picker, model picker, --print isnt available, /advisor isnt available, /feature isnt available, tui feature, interactive feature, test tui, cmux test claude, dialog picker, claude code dialog, claude code menu, status indicator, advisor model, opus advisor, sonnet advisor
**Common Confusions:**
- **vs `cmux`** — `cmux` is the general TUI multiplexer skill; this one is specifically for testing Claude Code TUI features (slash commands, pickers, dialogs). Load `cmux` to learn the primitives; load this when the question is "does Claude Code feature X work in the TUI."
- **vs `claude-code`** — `claude-code` is the general Claude Code skill; this one is the narrow "TUI test path" skill, with a script (`scripts/test-tui-feature.sh`) and the rule that `--print` is invalid evidence for TUI features.
- **Anti-pattern: `claude --print "/feature"`** — always returns "isn't available in this environment" for TUI slash commands, which is a non-interactive mode response, NOT a feature-gate failure. The only authoritative test is a real interactive session spawned in cmux.

## qa-test-failure-dismissal-anti-pattern

**File:** `skills/qa-test-failure-dismissal-anti-pattern/SKILL.md`
**Triggers:** pre-existing on main, pre-existing check, is this pre-existing, not blocking, this also fails on main, the suite is already red, flaky test, related failure, same component, ci dismissal, pre-existing verification, pr-introduced vs pre-existing, dismiss a ci failure, bring-to-green dismissal, same test name rule, same-name check, category error dismissal
**Common Confusions:**
- **vs `pr-bring-to-green-inline-cookbook`** — the cookbook has the recipe (`references/pre-existing-vs-pr-introduced-diagnostic.md`); this skill is the anti-pattern card that any agent should load BEFORE writing a dismissal. Use the cookbook to do the work; load this skill to gate the dismissal.
- **vs `production-vs-main-drift`** — the drift skill is for "PR is merged but the bug still reproduces in production"; this skill is for "this PR has a CI failure that looks pre-existing" — the entry point is the PR failure, not a production observation.
- **Anti-pattern: "this also fails on main, not the PR's fault"** — without the four same-name checks, this is a category error. Load this skill before writing that sentence.

## github-api-fallback
GitHub API rate-limit fallback — switch between GraphQL and REST buckets (which drain independently at 5000/hr each), diagnose which bucket is exhausted, avoid the false 'rate-limited' trap when one still has headroom. Triggers: "rate limit exceeded", "HTTP 403", "API rate limit exceeded for user ID", "gh dual-bucket", "fallback to REST", "quota exhausted", "gh api rate_limit", "polling-heavy PR fan-out".

## harness-postmortem
**File:** `skills/harness-postmortem/SKILL.md`
**Triggers:** autonomy violation, hermes refused, agent refused, agent stopped halfway, stopped halfway, why did hermes stop, why did the agent stop, agent didn't do its job, hermes didn't do its job, you didn't do your job, fix the agent, fix hermes behavior, fix the harness not the task, meta skill, /meta, run meta, harness postmortem, harness retro, harness audit, harness fix, agent failure analysis, run harness postmortem on
**Slash alias:** `/meta` (file: `~/.claude/commands/meta.md`). Internal skill name is `harness-postmortem` to avoid collision with `meta-prompting` (Anthropic/LangGPT/SkillMD), `meta-harness` (ruflo, Nx), and `MetaGPT`. Both names resolve to the same skill file at `skills/harness-postmortem/SKILL.md`.
**Note:** Scope-locked to agent-behavior failures. NEVER investigates the underlying task. Phase 0 anchored on MAST taxonomy (Cemri et al., arXiv:2503.13657) + ETCLOVG layer model (Chen et al., arXiv:2606.06324). Phase 1 uses Observe → Isolate → Simulate → Evaluate 4-step spine (5-Whys retained as Simulate-phase heuristic). Lands fix in SOUL.md / new skill / new test, not the project code path the agent was attempting. Auto-fires on user correction phrases; manual invocation via `/meta <input>` (Slack URL, pasted conversation, or freeform description).
**Common Confusions:**
- **vs `finish-the-job`** — `finish-the-job` drives the *original* task to a verifiable conclusion (green PR / local state / dry-run). `harness-postmortem` is meta: it analyzes the agent's failure to do `finish-the-job`-style work and patches the harness so the failure class stops recurring.
- **vs `harness-engineering`** — `harness-engineering` is the umbrella / reference (SOUL.md rules, never-rewrite pitfalls, verify-CLI-before-quoting). `harness-postmortem` is the per-incident executor: input → MAST+ETCLOVG → Observe→Isolate→Simulate→Evaluate → fix. `harness-postmortem` calls `/harness` (`~/.claude/commands/harness.md`) for the protocol steps.
- **vs `Refinex-Space harness-fix`** — Refinex's `harness-fix` covers bug/regression/incident debugging in general software; `harness-postmortem` is Hermes-runtime-specific (SOUL.md/skills/tests). Prior art is cited in the SKILL.md body, not duplicated.
- **Anti-pattern: "fix the underlying task too while I'm at it"** — `harness-postmortem` is scope-locked. The underlying task is a separate `dispatch-task` job. Do not absorb it under any framing.

## wa-narrative-schema-required-fields-contract
**File:** `skills/wa-narrative-schema-required-fields-contract/SKILL.md`
**Triggers:** empty dice_rolls, dice_rolls [], action_resolution absent, missing planning_block, PLANNING_BLOCK_FALLBACK, narrative_response_schema drift, prompt schema drift, served prompt contract, narrative_response_schema required fields
**Note:** Contract-test skill added by the /harness postmortem on issue #9021 (StoryModeAgent dice_rolls[] empty + planning_block absent + action_resolution missing on 315,988-prompt-token turn). Verifies the served `request_json` for a real StoryModeAgent turn contains worked examples for every Required structured-output field (dice_rolls[], action_resolution, planning_block). Auto-loads when the user reports a WA bug with the symptom pattern "LLM emitted empty structured-output fields while the audit-event source is populated," or when reviewing a PR that touches `mvp_site/prompts/**`, `mvp_site/agent_prompts.py`, or `mvp_site/narrative_response_schema.py`.
**Common Confusions:**
- **vs `wa-daily-dice-audit-fix`** — `wa-daily-dice-audit-fix` is the GCP cron-side integrity audit (Class A compound notation / Class B non-dice content / Class C brand-new campaigns). It operates on the audit-event source and does NOT check the LLM-output-side field. `wa-narrative-schema-required-fields-contract` is the served-prompt contract that catches the LLM-side regression BEFORE the cron would. A passing cron is NOT evidence the LLM-side emission works.
