---
name: bashrc-shell-function-dispatch-recipes
description: "Calling bashrc shell functions non-interactively."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [bashrc, shell-function, subprocess, dispatch, claudem]
    related_skills: [claude-code-claudem, claude-code, dispatch-task]
---

# Bashrc Shell-Function Dispatch Recipes

## Why this skill exists

Bashrc-defined shell functions (`claudem`, `claudeminimax`, `claudeaf`, `claudewa`, `sym`, `ao`, `hermes`, `mcp`, `gog`, `gws`, etc.) are **not binaries on `$PATH`** — they are shell functions that only exist inside a bashrc-sourced interactive shell. Every non-interactive caller (Python subprocess, wrapper script files, launchd, GitHub Actions runners, AO workers) must explicitly source `~/.bashrc` to make them visible.

Three concrete silent failures this skill prevents (verified 2026-08-25, Dragon Knight wizard PR):

1. **`bash -lic '/tmp/dispatch.sh'` where the script body calls `claudem`** → fails with `claudem: command not found`. The script runs in a non-interactive subshell; bashrc is not sourced.
2. **`subprocess.run(['claudem', '-p', '...'])` from Python** → same failure, same reason.
3. **`bash -lic '...'` with a `tee | tail -300` pipeline** → exits 0 and the log stays empty because `tail -300` buffers until stdin closes. Looks like a hung worker when the worker never started.

The fix in all three cases: inline the actual command into the `bash -lic 'cmd'` string. Smoke-test the wrapper form BEFORE the real dispatch.

## The canonical caller-form × result-row table

| Caller form | bashrc sourced? | Function visible? | Verdict |
|---|---|---|---|
| `bash -lic 'claudem -p "…" --max-turns N'` (inline, short prompt) | ✅ yes (login flag) | ✅ yes | **CANONICAL for short prompts (<2KB)** |
| `bash -lic 'cd /tmp/wt && claudem -p "$(cat /tmp/brief.md)" --max-turns N'` | ✅ yes (login flag) | ✅ yes | **CANONICAL for multi-KB briefs** |
| `cat /tmp/brief.md \| xargs -0 -I {} bash -lic 'claudem -p "{}" --max-turns N'` | ⚠️ yes | ⚠️ yes | **BROKEN — silent exit 1 in 8s.** `xargs -I {}` mangles quoting; brief >4KB trips `xargs: command line cannot be assembled, too long`. See anti-pattern below. |
| `bash -lic '/tmp/dispatch.sh'` (script file) | ❌ NO in script subshell | ❌ NO | **BROKEN — silent `claudem: not found`, exit 0** |
| `subprocess.run(['claudem', '-p', '…'])` from Python | ❌ NO (no parent shell) | ❌ NO | **BROKEN — silent `claudem: not found`, exit 1** |
| `subprocess.run(['bash', '-lic', 'claudem -p "…"'])` from Python | ✅ yes | ✅ yes | **CANONICAL from Python** |
| `subprocess.run('bash -lic "claudem -p \\"…\\""', shell=True)` | ✅ yes | ✅ yes | **CANONICAL from Python** (shell=True) |

### Anti-pattern: `xargs -I {}` for passing a multi-KB brief

The form `cat /tmp/brief.md | xargs -0 -I {} bash -lic 'claudem -p "{}" --max-turns N'` looks reasonable but fails in two distinct ways (verified 2026-09-14, daily-levelup-cron dispatch to two parallel lanes):

1. **`xargs -0 -I {}` strips newlines** so the brief lands as a single huge arg with embedded literal `\n` markers. Claude receives the brief with literal `\n` in the prompt string instead of actual line breaks — every LLM turns spends budget "re-parsing" the mangled prompt.
2. **`xargs -I {}` substitution strips the inner quoting** — any single-quote or backtick in the brief breaks argument assembly. Concrete failure: `xargs: command line cannot be assembled, too long` (brief >4KB on macOS `ARG_MAX`) or silent exit 1 with the worker dying at the bash startup banner.
3. **Lie-detector trap**: both `xargs` failures exit cleanly with a 4-line log (bash banner + claude.ai connectors warning + `unrecognized_model` + nothing else). Looks identical to "worker is in early exploration phase" — agent thinks workers are alive for 30+ seconds before noticing the PIDs are gone.

**Always use the brief-file form** for any prompt >2KB: write the brief to `/tmp/<name>.md`, then dispatch with `bash -lic 'claudem -p "$(cat /tmp/<name>.md)" --max-turns N --output-format text'`. The `$(cat …)` substitution is evaluated by the bashrc-sourced login shell, which is the correct layer for argument assembly.

The two forms are equivalent functionally — both source bashrc and pass the brief to claudem — but only the brief-file form survives briefs >4KB and briefs containing single-quotes / backticks / dollar-signs.

The pattern is uniform: **the `bash -lic` form is the canonical wrapper for ALL non-interactive callers** because the `-l` (login) flag forces `~/.bash_profile` / `~/.bashrc` to source inside the spawned bash, making every shell function visible.

## The canonical 3-step dispatch protocol

```bash
# Step 1 — write the brief to a file (separate from the dispatch command)
cat > /tmp/brief.md <<'BRIEF'
…full task brief here, multi-line OK…
BRIEF

# Step 2 — smoke-test the wrapper form BEFORE the real dispatch
bash -lic 'claudem -p "smoke test — respond with one word" --max-turns 1 --output-format text'
# Expected: prints "ok" (or whatever Claude returns to a smoke prompt) in 6-8s.
# If it hangs >15s, or prints "claudem: command not found", STOP — wrapper is wrong.

# Step 3 — dispatch the real worker, INLINE the brief path in the bash -lic string
bash -lic 'cd /tmp/worktree && claudem -p "$(cat /tmp/brief.md)" --max-turns 200 --output-format text'
```

## Smoke-test the wrapper BEFORE the real dispatch — and again on subsequent dispatches

The canonical pre-dispatch smoke test:

```bash
bash -lic 'claudem -p "smoke test — respond with one word" --max-turns 1 --output-format text'
```

**Expected:** prints a one-word reply in 6-8s.

**What this catches:**
- `claudem: command not found` → bashrc not sourced. STOP — wrong wrapper form.
- `unrecognized_model: MiniMax-M3` + empty output → model rejected; the wrapper may still print empty stdout before falling through to fallback. Verify with `bash -lic 'claudem -p "say hi" --max-turns 1 --output-format text' | head -5`.
- Exit 1 in <10s with empty log → brief-quoting bug (likely `xargs -I {}` mangling; see anti-pattern above).
- Hangs >15s → wrapper is wrong OR provider is overloaded. Re-test with `--effort low` to disambiguate.

**For each new dispatch shape** (different brief length, different flags, different working directory): smoke-test once before the real dispatch. The cost of a 6-second smoke test is much smaller than the cost of waiting 30+ seconds to discover the worker died silently.

## Monitoring the worker (don't trust stdout)

`tee | tail -300` only emits output AFTER stdin closes (worker exits). For long-running dispatches, **read the Claude session JSONL directly** to verify real progress:

```bash
# Find the session directory (sanitized path under ~/.claude/projects/)
ls -lat ~/.claude/projects/-<sanitized-worktree-path>/ | head -5

# Tail the most recent JSONL and parse the last few turns
tail -3 ~/.claude/projects/-<sanitized-worktree-path>/<uuid>.jsonl | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        ts = d.get('timestamp', '')
        msg = d.get('message', d)
        role = msg.get('role', d.get('type', '?'))
        content = msg.get('content', '')
        if isinstance(content, list):
            parts = []
            for c in content[:2]:
                if isinstance(c, dict):
                    if c.get('type') == 'text': parts.append('TEXT: ' + c.get('text', '')[:300])
                    elif c.get('type') == 'tool_use': parts.append(f\"TOOL: {c.get('name','?')}({json.dumps(c.get('input',{}))[:120]})\")
                    elif c.get('type') == 'tool_result':
                        rc = c.get('content', '')
                        if isinstance(rc, list): rc = str(rc)[:120]
                        parts.append('RESULT: ' + str(rc)[:200])
            content = ' || '.join(parts)
        elif content: content = str(content)[:300]
        if content: print(f'[{ts}] {role}: {content[:500]}')
    except: pass
"
```

The JSONL is the source of truth. A worker that prints "Let me set up tasks to track this work properly." and then exits 0 has crashed — the JSONL will be missing the expected `assistant: TOOL: Edit(...)` / `TOOL: Bash(...)` lines that show real work in progress.

## Stale-completion lie detector

When you receive a background-completion notification (`Background process proc_X completed normally (exit code 0)`), the worker DID exit 0 — but that does NOT mean it actually ran. A worker that crashed at "claudem: command not found" inside a script file exits 0 because the parent `bash -lic` itself succeeded (the script body's `claudem` failure happened inside the subshell and was swallowed).

### Lie-detector signals:

- Exit code 0 + empty/near-empty log + no JSONL session file under `~/.claude/projects/-<sanitized-worktree-path>/` → worker never started, wrapper is wrong.
- Exit code 0 + log contains only the boilerplate "Let me set up tasks to track this work properly." and nothing else → worker crashed on the first tool call, fix the wrapper.
- Exit code 0 + JSONL shows `assistant: TOOL: Edit(...)` lines and a `git diff --stat` shows real file edits → worker really ran.
- Exit code 0 + JSONL shows ~200 turns of `assistant: TOOL: ...` and final `assistant: TEXT: ...` (summary) → worker finished successfully.

### Output timing gotcha — `[claude-code:unrecognized_model]` is benign, not a failure

When `claudem` runs with the M3 model against a provider that doesn't recognize the slug, Claude Code prints `[claude-code:unrecognized_model] {"model":"MiniMax-M3","query_source":"sdk"}` and falls through to a fallback model. **The worker is NOT dead** — it's running on the fallback. The warning is just noise.

How to disambiguate "fallback model running" vs "worker crashed":

- `[unrecognized_model]` + `Hi!` (or any 1-3 word reply to a smoke prompt) → fallback model active, worker is fine.
- `[unrecognized_model]` + nothing else for >30s → worker died at startup, NOT a fallback. Re-test with `--max-turns 1` and look for ANY stdout.
- `[unrecognized_model]` + `Error: Reached max turns (1)` → worker ran out of budget on the first turn (smoke test with `--max-turns 1`); safe to dispatch the real worker with `--max-turns 80+`.

Verified 2026-09-14, daily-levelup-cron dispatch: two workers showing only `[unrecognized_model]` for 30+ seconds looked dead; smoke test with `--max-turns 1` returned `Hi!` — workers were alive on the fallback model the whole time.

## Related pitfalls

- **`set -euo pipefail` in wrapper scripts fails on `set -u` against unset env vars** that bashrc would normally define (`$ANTHROPIC_AUTH_TOKEN`, `$MINIMAX_API_KEY`). Drop `-u` (or guard with `${VAR:-}`) if you must use a script.
- **`tee | tail -300` pipeline** is fine for short dispatches but blocks output for long ones. For multi-minute dispatches, redirect to a file (`> /tmp/dispatch.log 2>&1`) and `tail -f` it instead.
- **`background=true` in `terminal()` requires `notify_on_complete=true`** for completion notification — without it the process runs silently and you'll never get the "Background process completed" hook message.

## Cross-references

- `claude-code-claudem` — the canonical use case (M3 wrapper). Note: this skill is user-owned, so the wrapper-script pitfall cannot be patched into its SKILL.md from background curation. Run `hermes curator adopt claude-code-claudem` to opt in.
- `dispatch-task` — the orchestration layer that may use these forms
- `hermes-deploy-pipeline/references/launchd-env-injection-and-wrapper.md` — for launchd-driven invocations (different problem: env vars, not bashrc functions)
