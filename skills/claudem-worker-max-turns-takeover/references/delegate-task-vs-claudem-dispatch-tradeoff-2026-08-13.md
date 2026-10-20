# `delegate_task` 600s timeout vs `claudem --bg` no-cap — verified 2026-08-13

## TL;DR

`delegate_task` is convenient but has a hard **600s timeout** that silently kills any worker that hasn't returned a final answer in that window. For any coding dispatch that includes commit + push + PR-creation (typically 5-15 min wall-clock on a clean worktree), `delegate_task` will timeout mid-cycle. Use `claudem --bg` via `terminal(background=true, notify_on_complete=true)` instead.

## Verified evidence (2026-08-13, REVISIT backlog sweep)

Two coding `delegate_task` dispatches died at the 600s wall during this session:

| Subagent ID | Task | API calls at timeout | Status |
|---|---|---|---|
| `deleg_1516dfd1/task-0` | Fix dice natural-1/natural-20 bug (RED-GREEN-REFACTOR + push + PR) | 5 | timeout |
| `deleg_1516dfd1/task-1` | /web-advice UI redesign: inventory screenshots, batch by surface, fold into PR | 47 | timeout |

Both tasks were mid-cycle when killed — neither pushed a branch, neither opened a PR. Recovery: I re-dispatched both as `terminal(background=true)` claudem workers with the same prompt + 50 turns. Both are now running with no timeout cap.

## Why `claudem --bg` doesn't hit this

`terminal(command="bash -lic 'claudem --bg \"<task>\"'", background=true, notify_on_complete=true)` returns a `session_id` immediately and runs the worker in the background without any wall-clock cap. The worker is a real shell process (`bash` → `claudem` → `claude --dangerously-skip-permissions`) that runs until the worker explicitly exits, the model returns a final answer, or you `process(action='kill')` it.

`claudem --max-turns <N>` is the per-turn ceiling (default 100, this session used 50 for PR cycles). That's the **turn** budget, not wall-clock. A PR cycle takes ~50-120 turns (~30-60 min wall-clock on M3).

## Rule of thumb

| Work shape | Dispatch primitive | Why |
|---|---|---|
| ≤5-min lookup (search, summarize, file scan) | `delegate_task` | quick return, transcript path for tail-f |
| ≥5-min OR pushes to remote OR commits code | `claudem --bg` via `terminal(background=true, notify_on_complete=true)` | no timeout cap |
| Multi-hour babysit (CI loop, cron-style) | launchd plist + bashrc wrapper | survives session restart |
| User-explicit /af or /auto-factory | `ao spawn` | AO is opt-in only |

## When a `delegate_task` times out — retry pattern

Don't re-dispatch the same prompt. Identify the slow API call from the transcript at `~/.smartclaw/cache/delegation/live/<deleg_id>/task-N.log`, then retry with TIGHTER SCOPE:

1. **Skip slow paths.** For firestore / DB queries, hit local cache first (`~/llm_wiki/`, `~/roadmap/`, `~/.claude/projects/*/memory/`).
2. **Reorder sources by latency.** Local files > FTS5 > REST API > firestore.
3. **Bound the slow path explicitly** ("firestore is last-resort with bounded timeout").

Verified: hanji Stevens research subagent (#114) timed out at 600s on a slow firestore WA campaign query. Re-dispatched with the reorder pattern → 45s return with full triangulation.

## Companion pitfalls

- Always pass `notify_on_complete=true` to `terminal(background=true)` for bounded tasks. Default = silent.
- For live worker observation, poll the worktree state (`git log origin/main..HEAD`) or the Claude Code JSONL at `~/.claude/projects/-Users-jleechan-*/<session>.jsonl`. Don't rely on stdout/tee (Ink TUI is buffered).
- If `claudem` itself times out via `--max-turns`, this skill applies — see the takeover recipe.
