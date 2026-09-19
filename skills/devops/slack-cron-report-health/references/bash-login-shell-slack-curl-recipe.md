# bash login-shell + SLACK_USER_TOKEN from terminal — verified pattern

**Trigger:** you need to curl Slack's REST API from a `terminal` tool call (no
launchd context, no `SLACK_BOT_TOKEN` preloaded), and `bash -lic '...'` alone
prints `cannot set terminal process group / Inappropriate ioctl for device`.

Verified 2026-08-18 during a 7-thread dropped-thread diagnostic run: needed this
recipe on every call to fetch `conversations.replies` for cited thread_ts values
because the MCP `conversations_replies` tool returned `thread_not_found` for the
compact-form ts and the bot token didn't have access to the DM (`${SLACK_CHANNEL_ID}`)
thread.

## The pattern (single line, copy-pasteable)

```bash
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  SLACK_USER_TOKEN="$(bash -lic 'echo $SLACK_USER_TOKEN')" \
  bash -c 'curl -fsS -H "Authorization: Bearer $SLACK_USER_TOKEN" "https://slack.com/api/conversations.replies?channel=C0AH3RY3DK6&ts=1786914650.236939&limit=10"'
```

## What each layer does

1. `env -i HOME=... PATH=...` — clears inherited shell state (the parent
   `terminal` tool spawned from a non-PTY context). Setting only `HOME` and
   `PATH` keeps the minimum needed for `bash -lic` to find its `~/.bashrc`
   and for `curl` to run.
2. `SLACK_USER_TOKEN="$(bash -lic 'echo $SLACK_USER_TOKEN')"` — runs a
   login shell so `.bashrc` gets sourced, which is where `SLACK_USER_TOKEN`
   is exported. Capture its stdout into the env var.
3. `bash -c 'curl -fsS ...'` — the actual work. The outer `bash -c` runs
   in the now-clean env with the token available.

## Why `bash -lic` alone is not enough

`bash -lic` in a non-PTY parent process prints the ioctl warning but **still
succeeds in sourcing `.bashrc`** and exporting the token. The warning is
cosmetic; the captured `SLACK_USER_TOKEN` is real. The warning appears because
the parent process group can't be set when there's no controlling terminal —
that's a benign side-effect of `terminal` running under Hermes's process
supervisor, not a setup failure.

If the warning bothers you, redirect stderr:

```bash
SLACK_USER_TOKEN="$(bash -lic 'echo $SLACK_USER_TOKEN' 2>/dev/null)"
```

But the `2>/dev/null` swallows genuine `.bashrc` errors too. Better: keep
stderr visible and just ignore the ioctl line visually.

## When this is the right tool

- ✅ Reading Slack state from `terminal` (no launchd context)
- ✅ Diagnosing a Slack-bound cron without disrupting the live one
- ✅ Reaching a DM channel the bot token doesn't have access to (use
  `SLACK_USER_TOKEN` which is the user `xoxp` token, cross-workspace)
- ❌ Running a Slack-bound cron itself — use `launchd-env-wrapper.sh`
  per `slack-cron-report-health` Section 6 instead

## Pitfalls

- **`SLACK_USER_TOKEN` is the XOX-P user token**, not the bot token. The
  user token crosses workspace boundaries where bot tokens are scoped to
  home workspace. Per SOUL.md `## COMMIT: slack-cross-workspace-fallback-xoxp`,
  this is the canonical fallback when `chat.postMessage` returns
  `missing_scope` or `not_in_channel` and the channel ID is not in the
  bot's home workspace.
- **Source the token at runtime, not in `~/.bashrc`** if you intend to
  use it from launchd — per memory `bashrc-profile-xapp-drift-blocks-launchd`,
  launchd env-wrapper must read `.bashrc` explicitly because `.profile`
  can overwrite the same var from `.bash_profile`.
- **Don't `echo` the token to a public artifact.** Per SOUL.md
  `## COMMIT: outbound-secret-publication-gate`, never paste
  `git remote -v` or `env | grep SLACK` output to a Slack thread or PR.

## Related

- `slack-cron-report-health` Section 6 — the launchd equivalent pattern
  via `launchd-env-wrapper.sh`
- `dropped-thread-cron-loop` — the bug class this recipe was used to
  diagnose (7 already-closed threads cited in one daily escalation thread)
- `slack-thread-routing-investigation` — when the bot token is unavailable
  and you need to fall back to xoxp cross-workspace
