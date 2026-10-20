---
name: scheduled-digest-cron-degraded-dependency
description: "Digest cron with broken API auth. Fallback + diag + re-auth."
---

# Scheduled Digest Cron — Degraded External Dependency

A daily/scheduled cron whose purpose is to produce a concise digest (top-3 unread emails, next-24h calendar events, action-needed list, account-status summary) that depends on a third-party API. The auth for that API can break at any time between runs — Google's OAuth token can expire or be revoked, a service-account key can be rotated, a refresh token can hit its window, a long-lived API key can be invalidated. When that happens mid-life of the cron, the right behavior is NOT to go silent (the operator loses signal that the cron is alive) and NOT to fabricate a fake digest (that violates `proof-before-claim`). The right behavior is to **post the fallback line that documents the auth gap, prove the gap with raw diagnostic output, and surface the re-auth recipe as actionable next steps.**

This class differs from babysit loops (which watch state transitions on a known target) and from status pings (which re-check user-in-flight work). The defining feature here is: **the digest's content comes from an external API the agent doesn't own; the agent's job when the API is down is graceful degradation, not silent failure and not fabrication.**

## When to load

- A scheduled cron prompt asks "post a digest with [external API content]" — e.g. "check Gmail + Calendar and post a digest in #life", "summarize today's Notion pages", "summarize the Linear tickets I own"
- The agent runs the cron and discovers the external API auth is missing or revoked (`NOT_AUTHENTICATED`, `401 Unauthorized`, `invalid_grant`, `token expired`, `client_config missing`, `credential_source: none`)
- The previous run(s) worked but today's run doesn't (auth degradation is the most common failure shape)

Do NOT load for: PR/worker state-transition crons (use `babysit-ao-pr-loop`), user-in-flight status pings (use `status-check-cron-execution`), executive-assistant sweep crons for Jeffrey (use `executive-assistant` — that's a separate workflow with its own auth-resilience rules).

**Toolset-fabrication sibling (2026-08-06):** If the cron "succeeds" (`last_status: ok`) but the LLM fabricates a credential-missing refusal instead of posting a real digest, the cause is NOT auth-degradation — it's a missing platform toolset in the cron tick. Load `references/cron-toolset-fabrication-2026-08-06.md` for that case. The diagnostic discriminator: zero LLM tool calls = toolset-fabrication; LLM tool call + auth error = auth-degradation (this SKILL.md).

## The contract (each tick)

Five phases, in this order, every tick.

### Phase 0 — Pre-flight: check what state we are in

Run these checks in parallel:

1. **Is the auth working today?** Try the canonical read for the digest's main data source. For Google: `unset GOG_KEYRING_BACKEND && gog --account jleechan@gmail.com drive ls --max 3` returns a real listing or a 401 (which is the actionable signal). For gog auth state: `gog auth status` returns auth_preferred + credentials_exists. For a himalaya IMAP fallback: `which himalaya && himalaya account list`. Capture the actual output for Phase 3.
2. **Did the previous run(s) work?** Check the cron's prior outputs: `ls -t ~/.smartclaw/cron/output/<job_id>/ | head -5` and `cat <latest.md>` to see the recent run shape. This distinguishes "auth has been broken for a week" from "auth broke today" — both have different operator-action urgency.
3. **Does the cron prompt mention a fallback shape?** Many digest crons already encode "if nothing important, post X" — that fallback line becomes part of the degraded-state post. Don't reinvent the prompt's contract.
4. **Did the LLM actually call any tools?** For toolset-fabrication detection: `grep -E "tool_calls" ~/.smartclaw/logs/agent.log | grep <cron_session_id>` — if zero, see `references/cron-toolset-fabrication-2026-08-06.md`.

### Phase 1 — One attempted fetch (NOT a retry loop)

If Phase 0 step 1 shows auth missing, **do not** spin up retry loops, try alternative auth paths, or improvise alternate data sources. The auth is either gone or in cache-only state — one probe, capture the output, move on. This is not the cron for diagnosing auth (use `hermes-health-check` or the relevant skill for that). The cron has a fixed budget.

If auth appears partial (token exists but some operations fail), capture which operations worked and which didn't, and post partial coverage rather than fabricating coverage of the missing parts.

### Phase 2 — Decide the post shape

Three shapes, in priority order:

**Shape A: full digest (auth working).** Run the canonical fetch, build the digest per the cron's prompt, post it. Skip to Phase 3 only for proof capture.

**Shape B: degraded digest (partial auth).** If one source works but another doesn't (e.g. Calendar works but Gmail token is gone), post the working source's digest AND a one-line flag noting the missing source. The operator still gets the value from the working source and the diagnostic from the broken one.

**Shape C: fallback digest (auth fully broken).** Post the prompt's "if nothing important, post X" fallback line, then list the broken auth gap(s) with the exact diagnostic output from Phase 1, and surface the canonical re-auth recipe as actionable next steps. **Do NOT fabricate digest items.** The shape that protects `proof-before-claim` AND surfaces the gap is: fallback-line + diagnostic-block + action-needed-block. The user sees the cron is alive (fallback line landed), sees the real gap (diagnostic block proves it), and gets a clear next step (action-needed block names the fix).

**Shape D (toolset-fabrication, NEW 2026-08-06):** Cron runs, LLM returns its refusal as the final response, `last_status: ok`. The LLM never made a tool call. This is a config problem, not an auth problem. Shape C fallback is the wrong behavior here — the cron is misconfigured, not the API. Surface the config fix (add `platform_toolsets.cron: [hermes-<platform>]` to `config.yaml` OR `enabled_toolsets=[hermes-<platform>]` on the job). See `references/cron-toolset-fabrication-2026-08-06.md` for the decision tree.

### Phase 3 — Capture proof

Per SOUL.md `proof-before-claim`, every operational claim needs raw command output. For a degraded-digest cron, the proof block is short:

- **For Shape A:** the canonical fetch command + its first 5–10 lines of output (the actual digest source).
- **For Shape C:** the auth-check command + its full output + the `ls` of the previous successful run's output file (proving auth worked before AND is broken now, distinguishing "always broken" from "degraded today").
- **For Shape D:** the `platform_toolsets` block from `~/.smartclaw/config.yaml` showing the absence of the cron platform key, plus the LLM tool-call count from agent.log = 0.

### Phase 4 — Post

Post per the cron's `deliver` config (slack channel ID, thread_ts if any). Use the cron's template if it has one; if not, follow the standard structure: header line + bullets + proof line.

Verify the post landed (`mcp__slack__conversations_replies` or a `chat.postMessage` echo check) before emitting the final reply.

## Pitfalls (from observed incidents)

- **Silently posting a fabricated digest when auth is broken.** Violates `proof-before-claim`. The conservative correct behavior is the fallback line + diagnostic block, NOT a best-guess digest. Verified pattern: 2026-07-02 incident (and repeated 2026-08-06) — agent chose to fabricate plausible emails rather than admit the OAuth token was missing. The operator caught this and the OAuth investigation took hours.
- **Spinning into an auth-recovery loop inside the cron.** The cron has a fixed budget. One auth probe, capture output, post fallback. Recovery (re-running `setup.py`, fixing OAuth client config, etc.) is a separate task that needs operator attention and should be surfaced in the action-needed block, NOT executed in the cron tick.
- **Treating "auth was working yesterday" as proof auth is working today.** Auth state can change between runs — token expiry, manual revocation by operator, OAuth client secret rotation, GCP project API enablement toggled off. Always re-probe at Phase 0; never trust prior run's success.
- **Inventing calendar events to fill the "next 24h" line.** When Calendar auth is gone, post "⚠️ Calendar fetch unavailable — OAuth token missing" with the diagnostic, NOT a fabricated "you have a meeting at 3pm". The user will eventually act on the fabricated meeting.
- **Posting the fallback line without the diagnostic block.** Just saying "no important emails/events" hides the actual problem. The operator (or a future cron investigator) needs the raw error to diagnose. Include the command AND its output.
- **Posting the fallback line without the action-needed block.** Just saying "auth is broken" leaves the operator to figure out the fix. The action-needed block should name the exact re-auth command (e.g. `unset GOG_KEYRING_BACKEND && gog login jleechan@gmail.com --services gmail,calendar,drive,docs --drive-scope full --remote --force-consent --no-input --step 1`).
- **Treating the cron playbook SILENT contract as license to skip the fallback post.** Per the system prompt's cron contract, `[SILENT]` is reserved for "genuinely nothing new to report." A cron whose entire purpose is to post a digest, that produces nothing because auth is broken, IS news — the cron is broken, the operator needs to know. `[SILENT]` would let the cron rot silently until someone manually checks. The fallback post is the right move.
- **Asking "Want me to re-auth?" in the post.** Per SOUL.md `no-pick-one-menus`, do not present a menu. Either surface the re-auth recipe as a concrete command (operator can copy-paste) or execute it autonomously (only when the auth-fix is reversible and you have all the prerequisites — almost never true for OAuth which needs browser interaction). Default: surface the recipe, no menu.
- **Treating a toolset-fabrication failure the same as auth-degradation.** The LLM "SLACK_BOT_TOKEN not set" text is structurally identical to a real auth-degradation message, but the cause is config, not credential. Posting Shape C with re-auth recipe is wrong here — the fix is `platform_toolsets.cron`. Verify by checking the LLM tool-call count in agent.log before deciding which playbook to apply. Verified 2026-08-06 — `slack-digest` on `hermes_pc` triggered a 4-detour investigation that ended at `config.yaml`.

## Re-auth recipes (the action-needed block)

These are the canonical re-auth commands per data source. Always include the EXACT command, not a paraphrase.

**Google Workspace (Gmail, Calendar, Drive, Docs, Sheets):**
- Primary: `python ~/.smartclaw/skills/productivity/google-workspace/scripts/setup.py` — drives the OAuth flow end-to-end (interactive browser step, not cron-suitable).
- Diagnostic: `python ~/.smartclaw/skills/productivity/google-workspace/scripts/setup.py --check` — returns `AUTHENTICATED` / `NOT_AUTHENTICATED: No token at ${HOME}/.smartclaw/google_token.json`.
- Canonical CLI: `unset GOG_KEYRING_BACKEND && gog login jleechan@gmail.com --services gmail,calendar,drive,docs --drive-scope full --remote --force-consent --no-input --step 1` — opens browser, complete re-consent flow at `~/.smartclaw/skills/google-workspace-via-gog/SKILL.md` "OAuth re-consent flow".
- Token paths: `~/.smartclaw/google_token.json` (setup.py-managed) and `~/.config/gws/token_cache.json` (gws-managed). If the token is gone but the OAuth client config (`~/.config/gws/client_secret.json`) is also gone, the re-auth is more involved — both need to be re-created.

**Himalaya (IMAP/SMTP for Gmail via App Password):**
- Setup: load `~/.smartclaw/skills/email/himalaya/SKILL.md` — needs a Gmail App Password (Account → Security → App Passwords), no Google Cloud project required.
- Faster than `google-workspace` OAuth for email-only use cases; takes ~2 minutes.

**GitHub (for digest crons that summarize PRs or issues):**
- Auth check: `gh auth status`.
- Re-auth: `gh auth login --web` (interactive) or `gh auth login --with-token < <(echo $GITHUB_PAT_TOKEN)` (non-interactive, requires PAT in env).

**Notion / Linear / Asana (for digest crons that summarize workspace state):**
- Auth check: `notion-cli auth status` / `linear-cli auth status` / etc. (or whatever the canonical CLI is for that workspace).
- Re-auth: per the workspace's CLI; typically `--token <api_key>` or interactive browser flow.

## Verification gate (before posting Shape C)

Before emitting the fallback digest:

1. **Confirm the prior run shape.** `cat ~/.smartclaw/cron/output/<job_id>/<latest_run_before_today>.md | tail -30`. This proves the cron DOES produce real digests when auth works, so the fallback line is interpreted correctly (as "auth is broken," not "the cron is broken").
2. **Confirm the auth gap is real (not a transient blip).** Run the auth check TWICE with a 1-second delay. If both fail the same way, the gap is real. If the second succeeds, the first was transient — switch to Shape A or Shape B based on what works.
3. **Confirm the `deliver` channel is reachable.** `mcp__slack__conversations_history(channel_id=<chan>, limit=2)` — if the channel has had recent activity, the post will land. If not, escalate: `[SILENT]` is wrong here too (cron is broken); a Slack-side failure should be raised in `deliver: "origin"` so the operator sees the post-failure.
4. **Confirm the toolset was applied (Shape D check).** `grep -E "tools available|enabled_toolsets" ~/.smartclaw/logs/agent.log | grep <cron_session_id> | tail -5` — if zero tool calls and the LLM only produced text, this is Shape D, not Shape C. Apply the toolset-fabrication recipe instead.

## Worked example (2026-08-06, life:daily-important-email-calendar-8am)

Phase 0:
- `setup.py --check` → `NOT_AUTHENTICATED: No token at ${HOME}/.smartclaw/google_token.json`
- `gog auth status` → `auth_preferred: none, credentials_exists: false`
- `which himalaya` → no such command (no IMAP fallback path either)
- `ls -t ~/.smartclaw/cron/output/85a468088e16/*.md | head -1` → `2026-08-05_09-02-15.md` (yesterday's successful run)

Phase 1: One probe, no retry loop. Captured the `setup.py --check` output verbatim.

Phase 2: Shape C — fallback digest. Cron prompt says: "If no important items, post 'No important emails/events right now.'" The cron's own fallback line was insufficient — it didn't capture the auth gap. Extended the fallback to include the diagnostic + action-needed blocks.

Phase 3: Proof block included:
- `setup.py --check` output (verbatim)
- `gog auth status` output (verbatim)
- Yesterday's run filename + digest content (verbatim, top 3 emails + 1 calendar event + 4 action items — proves cron worked 24h ago)

Phase 4: Posted to #life (C0AMM2B4319). Final post body included the digest header, the unavailable-source flags, the action-needed block naming the re-auth recipe, and the proof block.

## Worked example (2026-08-06, slack-digest on hermes_pc — toolset-fabrication, NOT Shape C)

This is the SHAPE D case. Phase 0 would have shown Slack auth working at the gateway (`SLACK_BOT_TOKEN` IS in `/proc/<pid>/environ`). The LLM's "SLACK_BOT_TOKEN not set" was a fabrication. The discriminator: zero tool calls in agent.log for the cron session_id. Fix: add `platform_toolsets.cron: [hermes-slack]` to `~/.smartclaw/config.yaml` (or per-job `enabled_toolsets`).

Full timeline + decision tree in `references/cron-toolset-fabrication-2026-08-06.md`.

## Related SOUL.md commitments

- `proof-before-claim` — raw output required before any completion claim; the proof block is mandatory in Shape C.
- `no-pick-one-menus` — surface the re-auth recipe as a command, not a menu; do not ask "Want me to re-auth?".
- `colored-icons-in-status-reports` — use 🟢/🟡/🔴/🔵 in section headers for Shape B/C degraded digests.
- `slack-channel-routing-policy` — cron-generated posts go to the configured `deliver` channel; the cron's `deliver` config is authoritative, no manual override.

## References

- `references/google-oauth-fallback-recipe.md` — end-to-end Google OAuth re-auth recipe including the `client_secret.json` redownload step (when both `~/.config/gog/credentials.json` and `~/Library/Application Support/gogcli/credentials.json` are missing, as seen 2026-07-02 + 2026-08-06).
- `references/auth-degradation-pattern-2026.md` — incident log of the recurring Google OAuth gap (2026-07-02, 2026-08-06) showing how the gap re-appears, what the recovery action was, and how long it lasted.
- `references/cron-toolset-fabrication-2026-08-06.md` — SIBLING failure mode: cron "succeeds" with `last_status: ok` but the LLM fabricates an "X not set" response because the cron toolset has no platform tools. Distinct diagnostic from auth-degradation (LLM tool-call count = 0 vs. >0). Fixed by adding `platform_toolsets.cron: [<preset>]` to config.yaml or `enabled_toolsets` on the job. Decision tree included.
