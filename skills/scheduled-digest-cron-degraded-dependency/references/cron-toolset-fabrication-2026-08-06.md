# Cron Toolset-Fabrication Failure Mode — 2026-08-06 (slack-digest)

This is a **sibling** of the auth-degradation pattern in `references/auth-degradation-pattern-2026.md`, not an instance of it. Both produce the same observable symptom (a cron that "succeeds" but delivers a misleading response), but the root cause is different:

| Dimension | Auth-degradation | Toolset-fabrication |
|---|---|---|
| Cause | OAuth/API token expired or revoked | LLM has no platform tools in its toolset, fabricates an "X not set" response |
| LLM behavior | Detects auth failure, posts Shape C fallback | Fabricates a refusal without trying any tool call |
| `last_status` record | `error` (auth was caught) | `ok` (no exception) — the misleading response is the **content** |
| Diagnostic signal | `[ERROR] cron.scheduler: HTTP 401`, `[WARNING] marking X unhealthy` | `agent.log` shows the LLM called zero tools before producing the response |
| Fix surface | Re-auth the external API | Edit `platform_toolsets.<platform>` in `config.yaml` to include the platform's toolset (e.g. `cron: [hermes-slack]`), OR add `enabled_toolsets` to the cron job itself |
| Detection knob | Auth probe at Phase 0 | Read the LLM's tool-call count in `agent.log` for the cron session_id |

## The 2026-08-06 incident — `slack-digest` on jeff-ubuntu (hermes_pc)

**Cron:** `slack-digest` (job_id `dbbbf6a173b5`, schedule `0 9 * * *`, on `hermes_pc` Linux box)

**Prompt:** "Generate a Slack Digest for the last 24 hours. Scan the following channels: ..."

**Symptom (operator's view):** Cron job entries in Slack thread showed `last_status: error` with the LLM refusal text "I am unable to generate the Slack digest because the required `SLACK_BOT_TOKEN` or `OPENCLAW_SLACK_BOT_TOKEN` environment variable is not set." This pattern repeated across multiple manual triggers.

**What actually happened:**

1. The gateway *did* have `SLACK_BOT_TOKEN` in its env (verified via `cat /proc/<pid>/environ | tr '\0' '\n' | grep SLACK_BOT_TOKEN`).
2. The cron tick ran, the LLM was invoked, the LLM produced the "SLACK_BOT_TOKEN not set" text — and **never called any tool**.
3. The cron tick resolved `last_status: ok` because the LLM returned a non-empty response (no exception).
4. The Slack thread relayed the refusal as the "digest."

**Phase 0 missed it** because the standard auth/degradation probes (Gmail OAuth, etc.) don't apply to a Slack channel-history task. The auth state was fine; the issue was on the agent side.

**Root cause:**

The cron tick resolves its toolset via:

```yaml
# ~/.smartclaw/config.yaml
platform_toolsets:
  ...
  slack: [hermes-slack]
  # NOTE: nothing for cron
```

The `cron` platform key was absent, so cron jobs ran with the default cron toolset (`hermes-cron`), which is defined as `_HERMES_CORE_TOOLS` only — no Slack platform tools. The LLM received a prompt that asked it to "scan Slack channels" but had **no Slack tools** to call. The LLM (Gemini 2.5 Pro via OpenRouter) chose to fabricate a refusal rather than say "I have no tool to do this."

**The fix (the recipe):**

Two options, in priority order. **However** — note that even with the right toolset, an LLM-driven cron that needs to call the Slack Web API directly (e.g. via curl) will still fail because `_sanitize_subprocess_env` strips `SLACK_BOT_TOKEN` from cron subprocesses. If the cron needs the LLM to *call* Slack (not just receive messages), the more durable fix is to convert the cron to **no-agent script mode** that reads the token from the gateway env file. See `cron-jobs-and-messaging-credentials` SKILL.md for that recipe. Use Option A or B below when the LLM just needs Slack platform tools (read/write via MCP) but isn't calling the Web API itself.

### Option A: per-job `enabled_toolsets` (recommended for one-off jobs)

```bash
# Via the cronjob tool API (the CLI doesn't expose --enabled-toolsets on edit):
/home/$USER/.smartclaw/hermes-agent/venv/bin/python -c "
import sys
sys.path.insert(0, '/home/$USER/.smartclaw/hermes-agent')
from tools.cronjob_tools import cronjob
print(cronjob(action='update', job_id='dbbbf6a173b5', enabled_toolsets=['hermes-slack']))
"
```

The job will now load the slack platform tools in addition to the default core tools. The LLM can call `slack_diag`, `slack_history`, etc. and produce a real digest.

### Option B: global `platform_toolsets.cron` in `config.yaml` (recommended for all cron jobs)

```yaml
# ~/.smartclaw/config.yaml
platform_toolsets:
  cli: [hermes-cli]
  ...
  cron: [hermes-slack]    # ← applies to ALL cron jobs that don't have a per-job override
```

This way every cron job (current + future) gets the Slack tools. Trade-off: any cron job that touches Slack will now have those tools, which is usually what you want.

**Verification gate (use before posting "fixed"):**

Two probes, run in parallel:

```bash
# 1. Job resolved toolset (after the fix)
#    Look for "MCP tool discovery" or "tools available" lines in agent.log
#    for the cron session_id (e.g. cron_dbbbf6a173b5_20260806_091411)
grep -E "tools available|slack|MCP" /home/$USER/.smartclaw/logs/agent.log \
  | grep -E "cron_dbbbf6a173b5" | tail -10

# 2. LLM tool-call count for the run
#    If >0, the LLM actually called Slack tools. If 0, the toolset is still wrong.
grep -E "tool_calls" /home/$USER/.smartclaw/logs/agent.log \
  | grep -E "cron_dbbbf6a173b5" | tail -5
```

If the tool-call count is 0, the fix didn't land (config not reloaded, or `enabled_toolsets` was rejected by the resolver). Re-check the agent.log for the exact error.

## Why this trap is hard to detect

The cron tick has **two failure paths** that look similar to the operator:

1. **Auth-degradation path** (the "Shape C" this skill covers): the LLM honestly reports the gap, the cron posts a fallback, and `last_status` is `error`. Recovery is re-auth.

2. **Toolset-fabrication path** (this document): the LLM fabricates a refusal that looks like an auth error, the cron posts the fabricated refusal, and `last_status` is `ok`. Recovery is platform_toolsets config.

The only way to distinguish them without re-running the cron is:

- **Check the LLM's tool-call count in the agent.log.** Zero tool calls = toolset-fabrication. Any tool call attempt + auth error = auth-degradation.
- **Check the env vars visible to the gateway process.** If `SLACK_BOT_TOKEN` is set in the systemd/gateway env but `last_status: ok` and the LLM says "no token" → toolset-fabrication, not auth-degradation.

## What this skill does NOT change

The OAuth-degradation pattern in `references/auth-degradation-pattern-2026.md` still applies when the OAuth token is genuinely missing. The Shape C fallback in the SKILL.md is still the right behavior for that case. This document adds a new sibling failure mode to the diagnostic checklist, not a replacement for the existing playbook.

**Decision tree when a cron delivers a misleading response:**

1. **Does the LLM's response mention a specific missing credential/token?** Continue to next.
2. **Is that credential actually in the gateway's env?** (Check `/proc/<pid>/environ` or `cat /home/$USER/.config/hermes/hermes-gateway.env`.) If YES → toolset-fabrication (this document). If NO → auth-degradation (the existing playbook).
3. **Did the LLM call any tool before refusing?** If YES → auth-degradation (the tool returned the auth error). If NO → toolset-fabrication (the LLM never tried).

When in doubt, run a **scripted probe** that exercises the platform tools directly (e.g. `curl -X POST https://slack.com/api/conversations.history -H "Authorization: Bearer $SLACK_BOT_TOKEN"`). If the platform works fine at the curl level, the cron is misconfigured, not the platform.

## How to prevent recurrence

Two durability options:

1. **Per-platform toolset default in `config.yaml`** (Option B above). One-line config change covers all current and future cron jobs that touch Slack.
2. **Pre-tick toolset probe** in the cron tick dispatcher. Add a 5-line check that verifies the resolved toolset for the cron platform includes the expected tools BEFORE invoking the LLM. If the toolset is empty, post a "Cron X is misconfigured — platform_toolsets missing" alert instead of letting the LLM fabricate. This is the same idea as the auth watchdog in `references/auth-degradation-pattern-2026.md` § "What would prevent recurrence" but for toolset instead of OAuth.

The pre-tick toolset probe is the more durable fix (catches the problem at the cron layer, not when the user notices). It's a one-liner added to `cron.scheduler.py` near the `_resolve_cron_enabled_toolsets` call.
