---
name: ao-dispatch-mechanics
description: "AO spawn flags, model-switch, partial-work recovery."
---

# AO Dispatch Mechanics

The canonical `dispatch-task` skill covers intent and workflow. This skill captures the **actual CLI mechanics** that the dispatcher hits on every spawn — the flags that are wrong on the live CLI, the environment quirks, and the recovery recipes that aren't documented elsewhere.

## When to load

- Before any `ao spawn` call (to use the verified-correct flags)
- When a worker is stuck on API errors, weekly limit, or model-rejected
- When the operator asks to switch model mid-flight ("use claude minimax why are you using sonnet")
- When a babysit is firing polls for a dead session
- When you need to recover partial work from a killed worker

## `ao` CLI flag corrections (verified 2026-08-06)

The previously-documented `ao spawn -p <project>` and `ao send --file <path>` are wrong on the current `ao` CLI:

| Flag | Correct | Wrong (previously documented) |
|---|---|---|
| Project flag | `--project` | `-p` (returns `unknown shorthand flag: 'p' in -p`) |
| Agent flag | `--harness` | `--agent` (outdated) |
| Model flag | NOT a spawn flag — use `ao project set-config --project <id> --model <name>` | `--model` (no such flag) |
| Initial prompt | `--prompt "<text>"` (flag) | positional arg |
| Project ID | cwd-inferred or `--project <id>` | `-p <id>` |

| `ao send` flag | Correct | Wrong |
|---|---|---|
| Send body | `--session <id> --message "<text>"` (inline only) | `--file <path>` (no such flag) |
| Working directory | Must be a git repo cwd | any cwd (fails with `fatal: not a git repository`) |

**Long task briefs (>4 KB) for fresh spawns:** write to `<worktree>/AO-TASK-BRIEF.md` after spawn, do NOT pass via positional arg. The positional arg is truncated for branch derivation (~64 chars). Pass a short task slug as the positional arg.

## Spawn wrapper (macOS env -i)

The gateway shell's `~/.bashrc` exports ~245 vars that exceed macOS 256KB `ARG_MAX` when bash concatenates them into the `tmux new-session` command. The fix is to wrap the spawn in `env -i` and pass only the four vars `ao` needs.

```bash
GH_TOKEN_VAL="$(gh auth token)"
AO_TOKEN_VAL="$(gh auth token)"
cd <project-repo> && env -i HOME="$HOME" \
    PATH="${HOME}/.local/bin:${HOME}/.bun/bin:/opt/homebrew/bin:/usr/bin:/bin" \
    GH_TOKEN="$GH_TOKEN_VAL" \
    AO_BOT_GH_TOKEN="$AO_TOKEN_VAL" \
    bash -c '~/bin/ao spawn --project <project> --harness <harness> --branch <branch> --prompt "<short task summary>"'
```

The tmux session itself inherits the full env via `~/.bashrc` once it spawns, so the worker inside the tmux still has every secret.

## Model-switch workflow (Sonnet → MiniMax mid-flight) — verified 2026-08-06

When a Sonnet worker hits the Anthropic weekly limit and the operator says "use claude minimax why are you using sonnet":

1. **Recover partial work BEFORE killing the worker.** Read `git -C <worktree> log --oneline origin/main..HEAD` — the worker's commits are on the local branch and survive branch deletion. SHAs like `14110d2f2a` and `f23faf3ee7` are still reachable in the git object database, even after `git branch -D`.
2. **Find the worktree branch stash.** Each worker adds the branch to `<repo>/.git/worktrees/<session-id>/`. After `git worktree prune`, the worktree admin dir may still be there — remove it manually: `rm -rf <repo>/.git/worktrees/<session-id>`.
3. **Configure MiniMax routing** via project config + provider settings:

```bash
# Set the model to one Claude CLI accepts (NOT 'minimax-M3' — Claude CLI rejects unknown names)
ao project set-config <project> --model claude-sonnet-4-5

# Layer in env vars so requests route to MiniMax's Anthropic-compatible endpoint
KEY=$(python3 -c "import json; print(json.load(open('${HOME}/.ao/provider-settings.json'))['minimaxApiKey'])")
ao project set-config <project> --config-json "$(python3 -c "import json; print(json.dumps({'agentConfig':{'model':'claude-sonnet-4-5'},'env':{'ANTHROPIC_BASE_URL':'https://api.minimax.io/anthropic','ANTHROPIC_API_KEY':'$KEY','ANTHROPIC_AUTH_TOKEN':'$KEY'},'worker':{'agentConfig':{}},'orchestrator':{'agentConfig':{}},'trackerIntake':{}}))")"
```

The model string `claude-sonnet-4-5` is what Claude CLI accepts; the env vars route the call to MiniMax.

4. **Why `minimax-M3` doesn't work as the model string:** `providersettings/ClaudeEnvForModel` only sets the env vars when the model name starts with `minimax-`. But Claude CLI rejects unknown model names at the catalog check (before the API call). The workaround: pick a model name Claude CLI accepts (like `claude-sonnet-4-5`) and rely on env vars for routing. The MiniMax endpoint accepts Claude-model names.
5. **Spawn the new worker.** Claude CLI may prompt "Do you want to use this API key?" — send `1` then Enter via `tmux send-keys -t <session> "1" Enter` to accept.
6. **First steer for the new worker:** include `git cherry-pick <sha1> <sha2>` to recover the prior partial work. Don't expect the worker to know about the prior commits.
7. **Kill the orphaned babysit** that was tracking the dead worker — the babysit doesn't auto-repoint:

```bash
ps -ef | grep -E "babysit-one-session.*<old-session-id>" | grep -v grep | awk '{print $2}' | xargs kill
```

Then spawn a fresh babysit for the new session.

## Common worker errors + fixes

| Symptom | Cause | Fix |
|---|---|---|
| `unknown shorthand flag: 'p' in -p` | Using `-p` instead of `--project` | Use `--project` |
| `unknown flag: --file` | Trying `ao send --file <path>` | Use `ao send --session <id> --message "<text>"` |
| `fatal: not a git repository` | `ao send` from non-git cwd | cd into worktree or repo first |
| `There's an issue with the selected model (minimax-M3). It may not exist or you may not have access to it.` | Claude CLI rejects unknown model names | Use `claude-sonnet-4-5` + env vars to route to MiniMax |
| `Waiting for API response · will retry in 2m 40s · check your network` | Weekly limit hit on Anthropic Claude | Switch to MiniMax via the model-switch workflow above |
| `lifecycle polling is inactive` | `running.json` not yet written (gap after `ao session ls` shows healthy) | Wait 30s, then re-spawn |
| `tmux new-session: command too long` | ARG_MAX overflow without `env -i` wrapper | Use the env -i wrapper recipe above |
| `branch is already checked out in another worktree: "<branch>" is checked out at "<path>" (BRANCH_CHECKED_OUT_ELSEWHERE)` | `--branch` is currently checked out in another worktree (a prior AO session on the same branch, or a stale user worktree on the PR branch) | Free the branch before spawn: `git -C <existing-worktree> checkout --detach <head-sha>` — moves that worktree to detached HEAD on the same commit, freeing the branch ref. Verified 2026-08-05 with `fix/pr8139-clean-replay` locked in `worldarchitect-188`; detach freed the branch and the next spawn on `--branch fix/pr8139-clean-replay` succeeded. **Note**: this leaves the prior worktree with whatever uncommitted mods were there — preserve or stash first if they matter. |
| `failed to claim PR <N>: SCM unavailable (SCM_UNAVAILABLE)` | Transient GitHub API failure on `--claim-pr <N>` — AO rolls back the session and surfaces the error | Retry without `--claim-pr`; let the worker self-claim after spawn via `gh pr edit <N> --add-assignee @me`. Verified 2026-08-05 PR #8561: first spawn with `--claim-pr` rolled back with `SCM_UNAVAILABLE`; second spawn without `--claim-pr` succeeded. |
| `agent "<harness>" is not supported by this daemon` | Harness name spelled wrong — `claudem` is NOT a valid `--harness` value | Run `ao agent ls` to get the canonical list. For the Claude CLI routed through minimax, the harness is **`claude-code`** (NOT `claudem` — `claudem` is a wrapper function name in `~/.claude/`, not an AO harness). Verified 2026-08-05 with `worldarchitect-202`. |
| `Message is too long (MESSAGE_TOO_LONG)` from `ao send` | The `--message` payload exceeds the AO inline-message cap (~4 KB based on 2026-08-05 cutoff). Earlier sections of this skill said "long briefs go in `<worktree>/AO-TASK-BRIEF.md` post-spawn" but didn't show the full inline-message size limit. | Verified 2026-08-05: a 7.6 KB brief was rejected with `MESSAGE_TOO_LONG [request jeffreys-macbook-pro.local/xuXc4hdW4J-017412]`. **Recipe for long briefs** (proven end-to-end on PR #8787 → `worldarchitect-203`): (1) spawn with a short slug (≤64 chars) as the positional arg / `--prompt`; (2) post-spawn, copy the brief to `~/.ao/data/worktrees/<project>/<session-id>/AO-TASK-BRIEF.md` (the worker will land on this exact path — verify with `git -C <worktree> status` showing `?? AO-TASK-BRIEF.md`); (3) send a SHORT steering message via `ao send --session <id> --message "Read <full path> AO-TASK-BRIEF.md for full task brief. Branch: <branch> @ <sha>. PR #<N>. Slack thread <ts> for status. Begin: <first concrete step>. Post progress every 5 min."` Keep the steering message under ~500 chars. The worker reads the file on its first turn and acknowledges. |
| Worker tmux is "alive" but the prompt is still waiting at the `❯` prompt after 30s | The brief file was written but the worker is sitting idle because the steering message wasn't sent, or `ao send` failed silently | Verify with `tmux capture-pane -t <session> -p | tail -30`. If the worker shows the previous tool results but no `❯` prompt input, your `ao send` did not land. Re-send the short steering message. Also check `~/bin/ao session ls --project <project>` — a `state: spawning` row means the worker isn't ready yet; wait 30s. |
| `tmux send-keys -t <session> "..."` queues text in the worker's input but Enter does NOT submit — the worker's pane shows `Press up to edit queued messages` and a `❯` prompt with no movement. Bare `Enter`, `C-m`, `C-j`, and the heredoc-style compound `send-keys ... ; send-keys Enter` all fail to flush. | Claude Code's input buffer holds pasted/typed text in a queued state until an explicit flush event happens. The flush event in Claude Code's TUI is **`Escape` then `Enter`** in that order. Verified 2026-08-05 on `worldarchitect-202` for PR #8561: bare `Enter` was absorbed by the bash tool that was still running; after it finished, multiple Enter / C-m / C-j attempts all kept the message in the queue; `Escape` then `Enter` immediately submitted and the worker started processing the steer. | When steering via `tmux send-keys -l` or `tmux load-buffer + paste-buffer`, **always follow with `Escape` then `Enter`** (sequentially, not as a single `;`-joined compound). The bare `Enter` is silently consumed by whatever bash tool is currently running, and once the bash exits, the queued message is sticky. Detection: pane shows `paste again to expand` (bracketed paste mode) or `Press up to edit queued messages` — both mean the message is queued and needs the `Escape` → `Enter` flush. `tmux load-buffer` + `paste-buffer` is more reliable than `send-keys -l` for multi-line text, but BOTH paths need the same flush sequence at the end. |
| `ao send --message "..."` got intercepted — bash executed embedded `gh run rerun --failed` as a real command, returning `\`gh: <run-id> or --job required when not running interactively\`` | The steer message contained shell metacharacters (backticks, or a `gh ...` literal). When wrapped in `bash -c "..." ... --message "$MSG"`, the inner `$MSG` expands but if the message itself contains backticks or unescaped patterns, the outer shell re-parses them. Verified 2026-08-05 PR #8787 — first steer said "(2) DO NOT keep trying to rerun the queued jobs" and contained `gh run rerun --failed` as a literal; bash interpreted it as a real command. The `ao send` itself never ran. | **(a) Write the steer to a file via `write_file` or `subprocess`**, then pass via `shlex.quote(open(...).read())` to `bash -c`. (b) NEVER inline `ao send --message "..."` with backticks or `gh`/`git`/`cd`/`rm` literals in the message body — the outer shell will re-parse them. (c) If you must use inline, run via `python3 -c "import subprocess; subprocess.run(['~/bin/ao','send','--session',ID,'--message',open(FILE).read()])"` so the shell never sees the message content. (d) Detect: if `ao send` returns instantly with **empty stdout AND no `MESSAGE_TOO_LONG` error**, the bash command itself was repurposed — re-run via python. |

## Long-brief delivery recipe (verified 2026-08-05, PR #8787)

The single highest-friction part of the spawn flow is getting the brief into the worker. The proven sequence — copy-paste safe:

```bash
# 1. Write the brief to a known location
cat > /tmp/ao_brief_<ticket>.md <<'EOF'
<full task brief, target 4-15 KB>
EOF

# 2. Detach stale worktree first if needed (see BRANCH_CHECKED_OUT_ELSEWHERE row above)
# 3. Spawn with short slug only
SHORT_SLUG="<ticket>: <one-line summary>"  # ≤64 chars
GH_TOKEN_VAL="$(gh auth token)"
env -i HOME="$HOME" \
  PATH="${HOME}/.local/bin:${HOME}/.bun/bin:/opt/homebrew/bin:/usr/bin:/bin" \
  GH_TOKEN="$GH_TOKEN_VAL" AO_BOT_GH_TOKEN="$GH_TOKEN_VAL" \
  bash -c "cd ~/worldarchitect.ai && ~/bin/ao spawn --project worldarchitect --harness claude-code --branch <branch> --prompt \"$SHORT_SLUG\""

# 4. Wait for the worktree to appear at ~/.ao/data/worktrees/<project>/<session-id>/
sleep 8
ls -la ~/.ao/data/worktrees/<project>/<session-id>/

# 5. Copy the brief into the worktree root
cp /tmp/ao_brief_<ticket>.md ~/.ao/data/worktrees/<project>/<session-id>/AO-TASK-BRIEF.md

# 6. Send a short steering message pointing the worker at the file
#    SAFE pattern (avoids shell-injection of backticks / gh / git literals in the message):
#    Write the steer to a file, then pipe through shlex.quote so the outer bash never
#    re-interprets the message body. Verified 2026-08-05 PR #8787 (inline pattern failed
#    when the steer contained `gh run rerun --failed` — bash executed it as a real command).
python3 -c "import shlex,subprocess,sys; \
  m=open('/tmp/ao_steer_<ticket>.md').read(); \
  subprocess.run(['~/bin/ao','send','--session','<session-id>','--message',m])"
#    UNSAFE pattern (do NOT use): inline the message text in `bash -c "... --message \"<text>\""` —
#    if the message contains backticks or `gh`/`git`/`cd`/`rm` literals, the outer shell
#    re-interprets them as real commands. Use the python wrapper above instead.

# 7. Verify the worker picked it up
sleep 5
tmux capture-pane -t <session-id> -p | tail -20
```

**Why the steering message beats pushing the full brief inline:** `ao send` rejects messages above ~4 KB with `MESSAGE_TOO_LONG`. Inline positional args are truncated at ~64 chars for branch derivation. The worker is fully capable of reading a file from disk on its first turn — the steering message is just the breadcrumb.

## Reference

- `~/.smartclaw/skills/finish-the-job/SKILL.md` — the upstream intent + workflow
- `references/half-stop-user-re-ping-signal.md` — the verified 2026-08-05 pattern: when the user re-sends their own prior message verbatim, you stopped at status, not at action. Detection recipe + 4-arm self-audit + correct response sequence.
- `references/worker-timeout-salvage-recipe.md` — the verified 2026-08-06 recovery pattern: when an AO worker hits the 600s hard timeout, the worktree + uncommitted files survive — 10-step salvage recipe (inventory → rebase → fix remaining → drop debug artifacts → commit with provenance → push → PR) is almost always cheaper than re-spawning. Decision tree for salvage vs. fresh spawn vs. hybrid.
- `references/pr-preview-rotating-pool.md` — the verified 2026-08-05 pitfall: `pr-preview.yml` is a "Rotating Pool" (shared `mvp-site-app-s1`..`s10` Cloud Run services, not per-PR). Empty-commit retrigger pattern + the `SERVICE_NAME_OVERRIDE` aspirational-comment finding.
- `references/self-hosted-runner-systemic-saturation.md` — the verified 2026-08-05 same-name-rule pattern: when Self-Hosted MVP Shards + pr-preview.yml both queue >30min with 14/16 runners busy, the issue is the pool, not the PR. Decision tree: wait / empty-commit retrigger / partial-stack proof + retry-cron handoff.
- `references/skeptic-system-deleted.md` — the verified 2026-08-05 finding: Skeptic system was deleted 2026-07-09 (PR #8217); the "trigger Skeptic Self-Verify as alternative runner path" recipe in `drive-pr-to-green` Step 7a is dead. What the 2-gate /green definition actually is, why workers must refuse to invent a Skeptic VERDICT, and the recommended brief template post-deletion.
- `~/.smartclaw/skills/dispatch-task/SKILL.md` — the (now-stale) flag list, useful for intent
- `~/projects/agent-orchestrator/backend/internal/skeptic/llmeval/minimax.go` — `TryMinimax` recipe
- `~/projects/agent-orchestrator/backend/internal/providersettings/providersettings.go` — `ClaudeEnvForModel` logic
- `~/projects/agent-orchestrator/backend/internal/adapters/agent/claudecode/claudecode.go` — how `claude --model` is constructed
