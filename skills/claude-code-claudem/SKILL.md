---
name: claude-code-claudem
description: "Delegate coding work to Claude Code CLI routed through the user's bashrc `claudem` (alias `claudeminimax`) wrapper that points at a non-Anthropic provider (typically MiniMax M3). Thin wrapper around the bundled `claude-code` skill — same two modes (print + tmux), but the default binary is `claudem`, not `claude`."
version: 1.5.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
changelog:
  - "1.5.0 (2026-07-28): Bashrc-only wrapper. Removed the `~/bin/claudem` binary shim (and `claude_minimax` / `claude_minimaxc` symlinks) because it drifted from the bashrc function. Added `claudeminimax` (no underscore, matches the `claudeg`/`claudek`/`claudeds`/`claudegz` family form) as a pure bashrc alias of `claudem`. Updated all skill docs, contract tests, and references to use `bash -lic 'claudem …'` for non-interactive callers (pytest, launchd, AO workers, GitHub Actions)."
  - "1.4.0 (2026-07-26): Three new pitfalls. (1) subprocess.run cannot see bashrc shell functions — ship the binary at ~/bin/claudem + symlink claude_minimax / claude_minimaxc to it. Full install recipe + 3-command verification included. (2) M2.5/M2.7 audit one-liner when adding a new wrapper binary: rg --hidden -l 'MiniMax-M(2.5|2.7)' ~/.smartclaw ~/.bashrc ~/project_agento ~/bin | head -40 — zero hits in ~/.smartclaw is the clean state. (3) Live claude_minimax M3 identity probe with a timestamped marker: claudem -p 'Output exactly: HERMES_CLAUDEM_TEST_<ts>' --output-format text --max-turns 1 (round-trips verbatim on M3)."
  - "1.3.0 (2026-07-26): Two new pitfalls. (1) tmux send-keys paste handler splits long bodies into two [Pasted text #N] blocks; the trailing Enter only submits the FIRST block — always issue a second literal Enter after sleep 2. Verified PR #8629 (~20KB brief). (2) gh pr create is GraphQL-backed and fails when that bucket is exhausted even though REST is fine; worker recovery is file-edit-then-push via git (no API), then POST /repos/.../pulls via REST with $GH_TOKEN. Verified PR #8629. The companion one-shot skill long-task-claudem-tmux has been consolidated into this umbrella's pitfall section; the leaf was deleted (curator guidance: class-level skills, not flat one-session leaves)."
  - "1.2.0 (2026-07-26): Verified-case pitfall added for claudem bashrc function vs binary, with --agent minimax not-on-ao-go-daemon fallback via existing scoped worktree + claudem -p background + verify-remote-SHA + cron verify-after-rate-limit reset. Full transcript + verified PR #24 (jleechanorg/agent-orchestrator, commit 7e97d91e1)."
  - "1.1.0 (2026-07-22): Added claude_minimax alias contract (zero-churn pure alias of claudem); idempotent installer recipes; new pitfalls (wrapper-model quality vs Claude; --chrome-dropped variance; CLAUDEM_MODE=1 export)."
metadata:
  hermes:
    tags: [Coding-Agent, Claude, Provider-Routing, Coding, Refactoring, PTY, Automation, Wrapper]
    related_skills: [claude-code, codex, hermes-agent, opencode]
    replaces_default_binary_for: [claude-code]
    binary_aliases: [claudem, claudeminimax]
    invocation_pattern_non_interactive: "bash -lic 'claudem …'"
---

# Claude Code via `claudem` — Hermes Orchestration Guide

> **What this skill is:** a thin wrapper over the bundled [`claude-code`](https://hermes-agent.nousresearch.com/docs) skill. The bundled skill is the source of truth for everything Claude-Code-CLI-related (flags, modes, error handling, session resumption, JSON output, cost controls, tmux orchestration). This wrapper exists to swap the **binary** invoked by your coding work from `claude` to a user-defined `claudem` bashrc function (the convention used in `~/.claude-codex-provider-routing`) without forking the upstream skill.
>
> **Read the bundled `claude-code` skill first** for the comprehensive guide. Then come back here for the differences.
>
> **Alias convention:** `claudem` and `claude_minimax` resolve to the same wrapper. Use whichever the operator prefers; both are first-class on this skill.

## When to use this skill

Use `claude-code-claudem` (this skill) when:

- You want to delegate coding work to Claude Code CLI but **routed through a custom `claudem` binary/shell function** that overrides the upstream API endpoint, model, and auth (commonly a MiniMax/Anthropic-compatible proxy with model `MiniMax-M3`).
- You explicitly want to avoid hitting Anthropic first-party (rate-limit isolation, cost routing, fallback to a different provider).
- You're working in a session where the wrapper is the active LLM and you want the delegated worker to use the same provider family.

Use the bundled `claude-code` skill (NOT this one) when:

- You need Anthropic first-party routing (real Claude Opus/Sonnet) and have OAuth or a separate `ANTHROPIC_API_KEY` you want to honour.
- The task is in a worldarchitect.ai PR review context where dark-factory `/er` / `/advice` comments must come from the real Anthropic identity (see `wa-green-gate-pr-shape/SKILL.md`).
- The user explicitly says "use Anthropic" / "real Claude" / "not the wrapper" / "not claudem".

## What `claudem` is

`claudem` is a **bashrc shell function** (NOT a binary on `$PATH`) that wraps `claude` with overridden environment variables. It is defined in `~/.bashrc` (typically near line 1063, alongside the other `claudeg` / `claudek` / `claudeds` / `claudegz` family functions) and sets `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL="MiniMax-M3"`, and `ANTHROPIC_API_KEY` (from `$MINIMAX_API_KEY`) before `exec claude --dangerously-skip-permissions --effort high "$@"`.

> **There is no `~/bin/claudem` binary by design.** A binary shim existed from 2026-07-22 to 2026-07-28 and was removed because (a) it drifted from the bashrc function (default-if-unset vs force), and (b) every non-interactive caller on this host can use `bash -lic 'claudem …'` to source the bashrc. See `references/subprocess-vs-interactive-shell.md` for the full failure-mode table.

### Alias: `claudeminimax`

The bashrc family uses no-underscore naming: `claudeg` (GLM), `claudek` (Kimi), `claudeds` (DeepSeek), `claudegz` (Z.AI direct), and `claudem` (MiniMax). The spelled-out form `claudeminimax` is a pure bashrc alias that delegates to `claudem`. Both names resolve to the same wrapper — same env vars, same flags, same model. The recipe (already in `~/.bashrc`, shown here for reference):

```bash
# In ~/.bashrc, alongside the claudem family:
claudeminimax() { claudem "$@"; }
claudeminimaxc() { claudem --continue "$@"; }
```

The two functions are pure aliases — no second wrapper, no second source-of-truth. Same env vars, same flags, same model. Either name works in print mode, tmux orchestration, and AO worker contexts.

Companion aliases commonly shipped alongside: `claudeme` (typo fix → `claudem`), `claudemc` (= `claudem --continue`).

## The three differences vs the bundled `claude-code` skill

1. **Binary name is `claudem`, not `claude`.** Every `claude` invocation in the skill body becomes `claudem`. Print mode: `claudem -p '...'`. Interactive: `tmux send-keys ... 'source ~/.bashrc && claudem ...'`.
2. **`--dangerously-skip-permissions` and `--effort high` are usually baked in** by the wrapper. You do NOT need to pass them yourself. Passing them again is harmless (Claude Code accepts the duplicate).
3. **The wrapper env (`ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `ANTHROPIC_API_KEY`) must reach the child process.** For print mode (a subprocess of a bashrc-sourced shell) this is automatic. For tmux interactive mode, **the tmux pane is a separate process tree** — see the hardened guidance below. For non-interactive callers (`subprocess.run`, launchd, AO workers, GitHub Actions runners), use `bash -lic 'claudem …'` so the bashrc is sourced.

## Two orchestration modes (mirrors the bundled skill)

### Mode 1 — Print Mode (`claudem -p`) — non-interactive, PREFERRED for most tasks

**Interactive shell (bashrc already sourced):**
```bash
terminal(command="claudem -p 'Add error handling to all API calls in src/' --allowedTools 'Read,Edit' --max-turns 10", workdir="/path/to/project", timeout=120)
```

**Non-interactive caller (pytest, launchd, AO workers, GitHub Actions):**
```bash
terminal(command="bash -lic 'claudem -p \"Add error handling to all API calls in src/\" --allowedTools Read,Edit --max-turns 10'", workdir="/path/to/project", timeout=120)
```

The `-l` (login) flag forces `~/.bashrc` to source inside the spawned bash, making the `claudem` function visible. This is the canonical pattern for any non-interactive caller — see `references/subprocess-vs-interactive-shell.md` for why a binary shim is no longer needed.

The wrapper sets `--dangerously-skip-permissions` itself, so you don't need to repeat it. If you pass it again, Claude Code silently accepts the duplicate.

### Mode 2 — Interactive PTY via tmux — multi-turn (HARDENED)

> **Critical tmux detail:** `tmux send-keys` does **not** carry the caller's environment into the existing pane. If the pane was started by a non-login shell (launchd, AO worker, any daemon that strips env) the three `ANTHROPIC_*` vars will be missing, and `claudem` inside the pane will fall through to Anthropic first-party. **Always source the shell-rc that defines the wrapper before launching `claudem` inside the pane.**

```bash
# Start a tmux session
terminal(command="tmux new-session -d -s claudem-work -x 140 -y 40")

# Launch claudem inside it — ALWAYS source the shell-rc first so the
# wrapper's ANTHROPIC_* env vars are defined in the pane.
terminal(command="tmux send-keys -t claudem-work 'source ~/.bashrc && cd /path/to/project && claudem' Enter")

# Wait for startup, then send your task (~3-5s for the welcome screen)
terminal(command="sleep 5 && tmux send-keys -t claudem-work 'Refactor the auth module to use JWT tokens' Enter")

# Monitor progress
terminal(command="sleep 15 && tmux capture-pane -t claudem-work -p -S -50")

# Exit when done
terminal(command="tmux send-keys -t claudem-work '/exit' Enter")
```

If you want to avoid the `source` step, set the three `ANTHROPIC_*` env vars on the tmux server itself before any pane is created:

```bash
tmux new-session -d -s claudem-work -x 140 -y 40
tmux set-environment -t claudem-work ANTHROPIC_BASE_URL "https://api.minimax.io/anthropic"
tmux set-environment -t claudem-work ANTHROPIC_MODEL    "MiniMax-M3"
tmux set-environment -t claudem-work ANTHROPIC_API_KEY   "$MINIMAX_API_KEY"
tmux send-keys -t claudem-work 'claude --dangerously-skip-permissions' Enter
```

Either approach is valid; pick the one that matches your launch context.

## Prerequisites

- `claudem` (or its alias `claudeminimax`) must be defined in `~/.bashrc`. Verify: from a bashrc-sourced shell (`bash -lic 'type claudem'`) you should see `claudem is a function`. For non-interactive callers (AO workers, launchd, `subprocess.run`, Go PATH shims, GitHub Actions), use `bash -lic 'claudem …'` so the function is visible. See `references/subprocess-vs-interactive-shell.md` for the failure-mode table.
- The auth-token env var (`MINIMAX_API_KEY`) must be exported in the shell that runs `claudem` (the wrapper reads it at call time). For launchd-driven invocations, use `launchd-env-wrapper.sh` to inject it (see `hermes-deploy-pipeline/references/launchd-env-injection-and-wrapper.md`).
- Claude Code v2.x+ (`bash -lic 'claudem --version'` should report `2.x.y (Claude Code)`).
- The local `or-anthropic-proxy` at `127.0.0.1:8767` is **NOT** used by `claudem` in the standard setup — `claudem` calls the configured `ANTHROPIC_BASE_URL` directly. If your environment has the proxy on a different port, double-check the wrapper's `ANTHROPIC_BASE_URL` doesn't accidentally point at it.

## Gotchas

- **`claude.ai connectors disabled` warning** at the top of every response: expected, because the wrapper exports `ANTHROPIC_API_KEY` (or `ANTHROPIC_AUTH_TOKEN`) which takes precedence over a `claude.ai` OAuth login. Not a failure.
- **First call takes ~3-5s** for the model warmup. Print-mode `--max-turns 1` round-trips in ~6-8s end-to-end.
- **Wrapper-model quality ≠ Claude quality.** Outputs come from the model named in the wrapper's `ANTHROPIC_MODEL` (commonly a MiniMax-family model), not from Claude Opus/Sonnet. Use the bundled `claude-code` skill when you need real Claude judgment (e.g. adversarial design review, code review of sensitive PRs). Use `claudem` / `claudeminimax` for routine coding delegation.
- **Some wrappers drop `--chrome`**, unlike the Agnt-F `claudeaf` variant which adds it. Don't expect browser automation from a session started by a minimal `claudem`.
- **`CLAUDEM_MODE=1` is exported into the child shell** by the canonical wrapper. If a downstream tool checks this var, it will know it's running under `claudem`. Don't clear it manually. `claudeminimax` inherits the same `CLAUDEM_MODE=1` since it is a pure bashrc alias, not a second wrapper.
- **Wrapper composability**: `claudemc` = `claudem --continue`; `claudeminimaxc` = `claudeminimax --continue`. There is no `claudem --resume` alias — pass `--resume <id>` directly.
- **Subprocess vs interactive-shell behaviour** is the #1 gotcha. `subprocess.run(['claudem', …])` from Python fails with `claudem: command not found` because subprocesses don't inherit the parent shell's function table. The canonical pattern is `subprocess.run(['bash', '-lic', 'claudem …'])`, which forces `~/.bashrc` to source inside the spawned bash. This is what the contract tests in `tests/test_claude_code_claudem.py` do. See `references/subprocess-vs-interactive-shell.md` for the full failure-mode table.
- **`claudeminimax` vs other CLI patterns.** The `claude<family>` convention (no underscores, no separator) is consistent across the family: `claudeg`, `claudek`, `claudeds`, `claudegz`, `claudem`, and now `claudeminimax` as the spelled-out alias. If a future provider needs its own wrapper, the recipe is a bashrc function in the same family form, NOT a binary. The recipe in `~/.claude-codex-provider-routing/SKILL.md` is the canonical source for adding new provider wrappers.

## vs `claude-code`

- **`claude-code`** — the bundled Hermes skill. Binary = `claude`, routes to Anthropic first-party. Use for real Claude judgment, worldarchitect PR review, anything that needs Claude Opus/Sonnet quality or `claude.ai` OAuth.
- **`claude-code-claudem`** (this skill) — wrapper skill. Binary = `claudem` (or its alias `claudeminimax`), routes to whatever provider your bashrc function configures (commonly MiniMax M3). Use for routine coding delegation where you want wrapper-based routing (rate-limit isolation, cost, fall-through behaviour).
- Both share the same two-mode structure (print + tmux) and the same flag semantics. Switching between them is a 6-character diff (`claude` ↔ `claudem` or `claudeminimax`).
