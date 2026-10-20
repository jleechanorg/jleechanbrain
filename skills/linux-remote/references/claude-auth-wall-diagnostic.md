---
name: claude-auth-wall-diagnostic
description: "Diagnose 'claude -p <cmd>' OAuth failures on macOS + jeff-ubuntu — distinguish auth-wall from install-break using a 4-step cheap probe."
---

# Claude Code Auth-Wall Diagnostic — 4-Step Cheap Probe

When `claude -p "<cmd>"` fails with `Failed to authenticate: OAuth session expired and could not be refreshed` (or any auth-shaped error), the install may still be correct — the failure could be a user-side OAuth state issue, not a file issue. **Do NOT report "install verified" without first proving the runtime auth is dead AND non-recoverable without user action.**

## Symptom (what you see)

```
$ claude -p "/plan-micro test scope"
Failed to authenticate: OAuth session expired and could not be refreshed
```

Exit code non-zero. Same error on both machines is a STRONG signal it's the user's session, not the install.

## Step 1 — `claude auth status` (fastest, definitive)

```bash
/opt/homebrew/bin/claude auth status
```

| Output | Meaning |
|---|---|
| `{"loggedIn": false, "authMethod": "none"}` | User must re-auth — OAuth truly dead |
| `{"loggedIn": true, ...}` | Something else is wrong (env var, network, model name) — keep digging |

This single command resolves 80% of cases in <1 second.

## Step 2 — Keychain probe (macOS only)

```bash
security find-generic-password -s "Claude Code-credentials" -w | python3 -c "
import sys, json, datetime
d = json.load(sys.stdin)
o = d['claudeAiOauth']
rt_exp = o.get('refreshTokenExpiresAt', 0) / 1000
print(f'accessToken empty: {not o.get(\"accessToken\")}')
print(f'refreshToken empty: {not o.get(\"refreshToken\")}')
if rt_exp > 0:
    print(f'refreshTokenExpiresAt: {datetime.datetime.fromtimestamp(rt_exp)} ({\"ALIVE\" if rt_exp > datetime.datetime.now().timestamp() else \"EXPIRED\"})')
"
```

- Empty `accessToken` AND empty `refreshToken` → logged out cleanly (keychain entry not cleaned up)
- `refreshTokenExpiresAt` in the past → refresh token truly dead, no programmatic recovery
- Both empty + expiry past → user must re-auth interactively

## Step 3 — Check for non-interactive login flag

```bash
/opt/homebrew/bin/claude auth login --help
```

If `--non-interactive` (or any equivalent: `--token`, `--headless`, `--device-code`) is **not** in the help output, the OAuth login flow requires a browser session the agent cannot complete autonomously. Stop trying to "push past" auth — the wall is real.

## Step 4 — Bashrc fallback audit (CRITICAL — don't auto-flip)

```bash
grep -E "^(export|# export) (ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN)=" ~/.bashrc
```

If both are present but commented out with a comment like *"Commented out to use Claude Code subscription instead of API credits"*, the user explicitly chose subscription auth over API credits. **Do NOT uncomment without explicit permission** — that violates `~/.claude/CLAUDE.md` "Authorization and scope" rule.

If commented out WITHOUT explanatory comment, you may ask the user: *"Your bashrc has commented ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN. Want me to uncomment one to bypass the OAuth wall, or do you prefer to re-auth via `claude auth login`?"*

## Reporting the blocker honestly

When you've finished steps 1-4 and confirmed it's a real auth wall:

:white_check_mark: Install verified by hash parity + file integrity + YAML validation
:warning: Runtime smoke test blocked on OAuth refresh — proof: (paste step 1-4 evidence)

**To finish (1 minute):** `claude auth login` (browser flow)

**NOT acceptable**: "Install verified, you'll need to log in" without the step 1-4 evidence. That's a punt dressed as a handoff. The dropped-thread-followup script flags it as a missed execution.

## Bug-ref + provenance

- 2026-08-13 Slack thread `${SLACK_CHANNEL_ID}/p1786685383.836009` — `/plan-micro` install was correctly verified by md5 hash parity, but the OAuth-wall handoff was insufficient. Dropped-thread followup correctly flagged "you admitted to not executing, please do so now." The 4-step recipe above is the response: re-attempt the diagnostic with cheaper probes, name the exact blocker (refresh token expired 2026-07-31, no non-interactive login flag, bashrc explicitly subscription-prefers-API-credits), and offer the 1-minute user-action fix.
- Companion to: `linux-remote/SKILL.md` "Hash parity proof when auth blocks the runtime smoke test" section — that section covers the *result* (what to say to user); this reference covers the *diagnostic process* (how to prove the wall is real).