---
name: hermes-streaming-cut-diagnosis
description: Diagnose Hermes `[response interrupted]` cuts.
version: 1.0.0
author: hermes-agent
license: MIT
triggers:
  - response interrupted
  - hermes stopped
  - hermes went silent
  - "didn't do that before"
  - hermes cut me off
  - /research hermes upstream
  - is this an upstream hermes bug
metadata:
  hermes:
    tags:
      - hermes
      - slack
      - streaming
      - gateway
      - bug-diagnosis
      - upstream-bug
    related_skills:
      - hermes-health-check
      - dropped-messages
      - meta-autonomy-violation-handler
---

# Hermes Streaming-Cut Diagnosis

## When to Use

**Use when ANY of the following match the symptom:**
- A Slack thread message body reads `response interrupted` or `[response interrupted]` or `response interrupted by a tool result` (sent by hermes bot `U0AEZC7RX1Q` / `@hermes`)
- The user reports "Hermes stopped", "Hermes went quiet", "Hermes didn't do that before", "Hermes cut me off mid response"
- The user types `/research` to ask whether other Hermes users are seeing the same symptom
- The user asks `is this an upstream hermes bug`
- A Hermes Slack turn ends with a single-line stub containing the literal token and the agent loop does not re-prompt on its own

**Do NOT use for:**
- Launchd / Hermes gateway health failures (use `hermes-health-check`)
- Dropped messages / unanswered threads (use `dropped-messages`)
- Slack routing races / wrong-thread misroutes (use the slack-misroute skills)
- Any symptom where `curl http://localhost:8643/health` actually fails — that's a gateway fault, not a streaming cut

## TL;DR

When a Slack turn shows `[response interrupted by a tool result]` and Hermes appears to stop mid-task, **do NOT restart the gateway**. It is almost always the upstream Hermes continuation-prompt bug class (issue [#74990](https://github.com/NousResearch/hermes-agent/issues/74990)): `_get_continuation_prompt(is_partial_stub=True)` lacks the "tools remain available" clause, so the resumed model refuses tool calls and emits a single-line stub.

**Recovery is typing `continue` (or any new user prompt)** ~minutes after the cut. Verified in production: user typed `continue` 11 minutes after `response interrupted` and the original task resumed correctly.

**Permanent fix:** upstream PR [#75004](https://github.com/NousResearch/hermes-agent/issues/75004) (one-line prompt change) + `pip install --upgrade hermes-agent`. Local one-liner patch recipe available when the user needs the cut to be invisible today.

## When to load this skill

Triggers (regex):
- User message contains `response interrupted`, `hermes stopped`, `didn't do that before`, `it didnt do that before`, `went quiet`, `went silent`, `cut me off`, `is this an upstream hermes bug`, `/research hermes`
- Slack thread shows `msg <ts> text="response interrupted"` or `msg <ts> text="response interrupted by a tool result"` for hermes bot (`U0AEZC7RX1Q` / `@hermes`)
- The user shares a `slack.com/archives/.../p<ts_no_dot>` link AND the symptom is a streaming cut, not a routing or auth issue

**Do NOT load for:** dropped messages (use `~/.smartclaw/skills/dropped-messages`), Slack routing races (use the Slack-misroute skills), launchd-down (use `hermes-health-check`), or any symptom where `curl http://localhost:8643/health` actually fails.

## Diagnostic order — 5 layers

> Verified 2026-08-19 against deployed `Hermes Agent v0.20.0` (commit `v2026.7.30-2225-g715d26cdf4`).

### Layer 1 — Confirm the gateway itself is alive (eliminate the easy layers first)
```bash
curl -s --max-time 3 http://localhost:8643/health
launchctl list | grep hermes | grep -v grep
ps -p $(launchctl list | grep hermes | awk '{print $1}' | head -1) -o pid,stat,command 2>/dev/null
hermes version | head -3   # records build SHA, may be the smoking gun
```
If any of these fails → hand off to `hermes-health-check`, not this skill. **Streaming cut ≠ gateway-down.**

### Layer 2 — Confirm the user's exact interruption timestamp + shape
The bug has two distinct shapes that map to two upstream issues:
- `[response interrupted]` literal token → partial-stub path → issue [#74990](https://github.com/NousResearch/hermes-agent/issues/74990) (prompt lacks tool re-assertion)
- `response interrupted by a tool result` → mid-tool-result injection → same family, may also touch [#89765](https://github.com/NousResearch/hermes-agent/issues/89765) / [#89760](https://github.com/NousResearch/hermes-agent/issues/89760) (Slack-side streamed-attachments silent rejection on 2026-08-19)

```bash
# Find the canonical interrupt message in this channel via Slack MCP
mcp__slack__conversations_replies channel_id=<chan> thread_ts=<thread_root> limit=50
# Filter: BotName=hermes AND Text contains "response interrupted" OR "[response interrupted]"
```

### Layer 3 — Pull prior incidents from roadmap + Hermes state DB
```bash
grep -h "response interrupted" ${HOME}/roadmap/2026-08-1*.md 2>/dev/null | head -10
sqlite3 ~/.smartclaw/state.db "SELECT m.timestamp, m.role, substr(coalesce(m.content,m.tool_calls),1,200) FROM messages_fts f JOIN messages m ON m.id=f.rowid WHERE messages_fts MATCH 'response interrupted' LIMIT 10 ORDER BY m.timestamp DESC" 2>/dev/null
```
A history of `response interrupted` events across multiple days + commits = confirmed ongoing bug class, not a one-off flake.

### Layer 4 — Cross-reference upstream GitHub issues
```bash
# Find open issues with the matching symptom in NousResearch/hermes-agent
curl -fsSL "https://api.github.com/search/issues?q=repo:NousResearch/hermes-agent+mid-stream+OR+'partial+stub'+OR+'continuation+prompt'+OR+'finish_reason'" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(f'[{i[\"number\"]}] {i[\"state\"]:8} cmts:{i[\"comments\"]} {i[\"created_at\"][:10]} {i[\"title\"][:120]}') for i in d.get('items',[])[:15]]"
```
Reference issue numbers (verified 2026-08-19):
| Issue | Status | Title |
|---|---|---|
| [#74990](https://github.com/NousResearch/hermes-agent/issues/74990) | open 2cmts | "[Bug]: after a mid-stream transport cut, the model refuses to call tools on continuation" |
| [#75004](https://github.com/NousResearch/hermes-agent/issues/75004) | open 1cmt | "fix(agent): clarify tool availability in continuation prompt after transport cut (#74990)" |
| [#75801](https://github.com/NousResearch/hermes-agent/issues/75801) | open 6cmts | "4 fake 'network mid-stream' continuations when finish_reason missing" |
| [#89765](https://github.com/NousResearch/hermes-agent/issues/89765) | open | `fix(slack): surface rejected streamed attachments` |
| [#89760](https://github.com/NousResearch/hermes-agent/issues/89760) | open | `[Bug]: Streamed Slack MEDIA path rejection is silent after a delivery claim` |
| [#80151](https://github.com/NousResearch/hermes-agent/issues/80151) | open 1cmt | "Desktop: switching away and back mid-stream loses earlier streamed content" |

**Always cite these inline by URL** in the user-facing reply so they can verify.

### Layer 5 — Decide action path

**Path A — Default (no user impact, recovery is `continue`).** Used 95% of the time. Tell the user:
- It's an open Hermes bug, not local config or Anthropic
- Type `continue` (or any new message) to resume; the original task picks up
- Upstream fix is PR #75004 (one-liner)
- This skill has the local-patch recipe if needed

**Path B — Apply local patch.** Used when the user reports this is now blocking them and they want silence restored. Recipe in `references/local-continuation-prompt-patch.md`.

**Path C — Track upstream + wait.** Used when the user is OK with the `continue` workaround and wants the canonical fix path. Set `cronjob action=create` daily-morning watch on issues #74990 + #75004 → merge state, then `pip install --upgrade hermes-agent` to resolve.

## Pitfalls

- **Do NOT restart the gateway for this symptom.** The gateway is alive; this is an agent-loop continuation-prompt issue. Restarting adds deployment disruption and exposes "spurious restart" in audit logs without changing the symptom.
- **Do NOT call `hermes setup` / `hermes config set`** for this — config does not affect the continuation prompt; it's a Python code path.
- **Do NOT switch providers** (Anthropic ↔ OpenRouter ↔ MiniMax) as a workaround. The bug is in the Hermes loop, not the provider. Provider switching wastes config + auth cycles and may break caching elsewhere.
- **Do NOT blame Anthropic** when the symptom is "response interrupted by a tool result" — the SSE stop_reason is correct; Hermes's loop misclassifies it as a transport cut.
- **Do NOT trigger a quick-resume protocol** or blindly send a `Z` keystroke. Wait for the user to type `continue` or any new turn.
- **Do NOT cite "user sees it for the first time" as evidence of regression.** The bug has been latent since at least 2026-07-30 (issue #74990 opened that day); it just became user-visible when Slack streaming changes (~2026-08-17) exposed the partial-stub termination as the literal `[response interrupted]` token.
- **If user said `/research` explicitly, do include the upstream issue numbers inline** — they want to be able to click through. Cite them as markdown links per the project's PR-hyperlink rule (issues use `/issues/<N>`).
- **Companion rules to follow:** `slack-never-hand-post-your-own-reply` (gateway threads replies — don't hand-post to the channel), `proof-before-claim` (cite the actual deployed commit SHA, not a guess).
- **Anti-pattern from prior session:** I initially framed this as "Anthropic stop_reason hitting `interrupted`" — that is wrong. It is the Hermes continuation-prompt, NOT the Anthropic SSE stop_reason. The SSE signals correctly; the Hermes loop misclassifies the partial-stub as a transport cut.

## File locations (verified paths on this host)

```bash
# Hermes CLI symlink → venv at ${HOME}/projects_other/hermes-agent
which hermes
# → ${HOME}/.local/bin/hermes (symlink)
# → real: ${HOME}/projects_other/hermes-agent/.venv/bin/hermes

# Hermes version + commit
hermes version
# → Hermes Agent v0.20.0 (2026.8.3) / Install directory: ${HOME}/projects_other/hermes-agent / OpenAI SDK: 2.24.0

# Hermes installed source
${HOME}/projects_other/hermes-agent/

# Where the continuation prompt lives
grep -rn "_get_continuation_prompt\|is_partial_stub" ${HOME}/projects_other/hermes-agent/hermes_agent/ 2>/dev/null | head
# Likely path: hermes_agent/agent/chat_completion_helpers.py or hermes_agent/agent/run_agent.py

# Roadmap audit trail of past incidents
ls -lt ${HOME}/roadmap/2026-08-*.md | head
grep -h "response interrupted" ${HOME}/roadmap/2026-08-*.md 2>/dev/null
```

## References

- `references/upstream-issue-map.md` — full table of all known streaming-cut issues with links, statuses, and the latest comment summaries.
- `references/local-continuation-prompt-patch.md` — recipe to apply the upstream #75004 fix locally without waiting for `pip upgrade`, plus verification steps.
- `references/diagnostic-recipe.md` — copy-paste 5-layer diagnostic shell block tuned for a single-message user reply (no separate shell need).
