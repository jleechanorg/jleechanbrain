# Local Continuation-Prompt Patch (mirrors upstream PR #75004)

Apply the upstream #75004 prompt fix **locally** without waiting for a Hermes `pip upgrade`. This is a one-line, easily-reversible change to the running venv. Use when the user is reporting that the cut is blocking them in real time.

## Verified paths on this host (2026-08-19)

- Hermes CLI symlink: `${HOME}/.local/bin/hermes`
- Real venv: `${HOME}/projects_other/hermes-agent`
- Source tree: `${HOME}/projects_other/hermes-agent/`
- Currently installed version: `Hermes Agent v0.20.0 (2026.8.3)` at commit `v2026.7.30-2225-g715d26cdf4`

## Find the prompt generator

```bash
grep -rn "_get_continuation_prompt\|is_partial_stub\|Finish the answer directly" \
  ${HOME}/projects_other/hermes-agent/hermes_agent/ 2>/dev/null
```

Likely files (confirmed via Grep semantics in 2026-08-19 source tree):
- `hermes_agent/agent/chat_completion_helpers.py` (function `_get_continuation_prompt`)
- `hermes_agent/agent/run_agent.py` (callsite)

## Apply the patch

```bash
cd ${HOME}/projects_other/hermes-agent

# Backup first (always)
cp hermes_agent/agent/chat_completion_helpers.py \
   /tmp/chat_completion_helpers.py.bak.$(date +%s)

# Apply the patch (single sed; matches both single and double-quoted forms)
# Per upstream PR #75004:
#  BEFORE: "Finish the answer directly."
#  AFTER:  "You may still use tool calls if needed — all tools remain available."
# Use Python in-place edit for safety (sed on Python source is fragile):
python3 - <<'PY'
import pathlib, re
target = pathlib.Path("hermes_agent/agent/chat_completion_helpers.py")
src = target.read_text()
old = '"Finish the answer directly."'
new = '"You may still use tool calls if needed \\u2014 all tools remain available."'
if old not in src:
    print("PATCH FAILED: literal not found; inspect _get_continuation_prompt manually.")
    raise SystemExit(2)
src = src.replace(old, new)
target.write_text(src)
print("PATCH OK")
PY

# Sanity check: confirm the new prompt is present and the old one is gone
grep -n "Finish the answer directly" hermes_agent/agent/chat_completion_helpers.py && echo "OLD STILL PRESENT" || echo "OLD REMOVED"
grep -n "all tools remain available" hermes_agent/agent/chat_completion_helpers.py && echo "NEW PRESENT"
```

## Why the patch is safe

- One literal string change in one file. No Python control-flow touched.
- The patch mirrors the upstream open PR exactly (verified by reading #75004 body).
- It restores the exact behavior the upstream maintainers intend to ship as the canonical fix.
- Reversible: `cp /tmp/chat_completion_helpers.py.bak.<ts> hermes_agent/agent/chat_completion_helpers.py`

## Why you do NOT need to restart the gateway

- The `_get_continuation_prompt` function is imported by the agent loop at message-handler import time.
- A gateway restart IS cheap (~3 seconds), but if you want to be minimal, you can leave the gateway running — Hermes re-imports modules on its next `python3 -c` invocation (e.g., `hermes version` triggers a fresh shell).
- Recommendation: just restart for clarity:
  ```bash
  launchctl kickstart -k gui/$(id -u)/ai.smartclaw.gateway 2>/dev/null  # or
  launchctl bootout gui/$(id -u)/ai.smartclaw.gateway && \
    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.smartclaw.gateway.plist
  ```

## Verification recipe

Trigger the bug pattern on purpose:
1. Open a Slack thread with the bot.
2. Send a multi-part turn that ends with a deliberate tool call.
3. From a separate window, send a second message that arrives mid-tool-call.
4. Watch the next assistant turn.

Before the patch:
- The next assistant turn is a short stub ending in `[response interrupted by a tool result]`. No further tool call.

After the patch:
- The next assistant turn emits the same tool call the user requested (resumed mid-stream), preserves the previous context, and produces a complete response.

If both branches look the same → the patch did not land. Re-check the `grep` checks above.

## When to undo

Undo the local patch when any of these become true:
- Upstream PR #75004 is merged (`merged_at` field populated in the GH API response)
- `pip install --upgrade hermes-agent` was run AND verified to include the prompt fix
- The user explicitly asks to revert to upstream-default behavior

Reversal:
```bash
cp /tmp/chat_completion_helpers.py.bak.<ts> ${HOME}/projects_other/hermes-agent/hermes_agent/agent/chat_completion_helpers.py
launchctl kickstart -k gui/$(id -u)/ai.smartclaw.gateway
```
