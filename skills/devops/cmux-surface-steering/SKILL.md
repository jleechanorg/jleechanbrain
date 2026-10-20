---
name: cmux-surface-steering
description: "Drive cmux panes from Hermes. Use to send commands."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [macos]
---

# cmux Surface Steering (curator-managed)

The user-owned `cmux` and `cmux-find-workspace-by-topic` skills are excellent at **finding** the right workspace and **reading** its screen, but they do not encode the **focus/send/wait** half of the loop, and their CLI tables lag the dev-fork build (verified 2026-08-19: they list `cmux focus-surface` as the focus verb; the actual CLI on the dev-fork build is `cmux focus-pane --pane <id>`).

This skill is the **canonical steering recipe** — discover → focus → send → wait → read. It is build-aware: every focus/send command goes through a one-time `cmux --help` probe so we use the verbs that exist on the running binary.

## When to load

- "Check the X terminal in cmux" / "what is the Y surface doing" / "have the Z pane run W"
- "Read the screen of the agent on workspace:N"
- "Send `/web-advice` (or any slash command / natural language) to a surface"
- Multi-socket cmux sessions (prod + dev) coexisting
- After any `cmux <verb>` returns `Error: Unknown command` — re-probe the verb set

## The 5-step recipe (always run, always in this order)

### Step 1 — Probe the live socket set

The shim's default socket may be dead. Enumerate ALL live sockets first:

```bash
for s in /tmp/cmux*.sock /private/tmp/cmux*.sock \
         ~/.local/state/cmux/cmux.sock; do
  [ -S "$s" ] && echo "SOCK: $s"
done
# Then ping each
for s in /tmp/cmux*.sock /private/tmp/cmux*.sock \
         ~/.local/state/cmux/cmux.sock; do
  [ -S "$s" ] || continue
  r=$(printf '{"id":"q","method":"system.ping","params":{}}\n' | nc -U -w 2 "$s" 2>&1)
  [ -n "$r" ] && echo "LIVE: $s"
done
```

The shim's hardcoded default often differs from the live set. Verified 2026-06-25 + 2026-08-19: shim pointed at `/tmp/cmux-debug-*.sock` but the workspace the user cared about was in `/private/tmp/cmux-debug-*.sock` (same dev fork, two socket files — macOS resolves `/tmp` and `/private/tmp` to the same dir but the shim hardcodes one path).

### Step 2 — Lock down the CLI verb set for THIS build

CLI verbs drift between dev and shipped builds. One-time `cmux --help` probe per session:

```bash
SOCK=/tmp/cmux-debug-dev-fork.sock
cmux --help 2>&1 | grep -iE "focus|pane|surface|send|read" | head -20
# Record: which verb works? (focus-pane, focus-surface, focus-window?)
# Record: does the verb take --pane, --surface, or --window?
```

Caveat discovered 2026-08-19: `cmux focus-surface` returns `Error: Unknown command 'focus-surface'` on the dev-fork build. The actual verb is `cmux focus-pane --pane <id> --workspace <id> --window <id>`. The socket-level `surface.focus` (via JSON-RPC) still works regardless. **If the CLI verb is wrong on the running build, fall back to JSON-RPC over the socket directly.**

JSON-RPC fallback example:
```bash
SOCK=/tmp/cmux-debug-dev-fork.sock
printf '{"id":"f1","method":"surface.focus","params":{"workspace_ref":"workspace:34","surface_ref":"surface:123"}}\n' \
  | nc -U "$SOCK"
```

### Step 3 — Find the workspace, list its surfaces

```bash
SOCK=/tmp/cmux-debug-dev-fork.sock
# List workspaces, find the topic keyword in titles
cmux --socket "$SOCK" list-workspaces 2>/dev/null | grep -iE "<topic-keyword>"
# Then list surfaces in that workspace
cmux --socket "$SOCK" list-pane-surfaces --workspace=workspace:N --json
```

`list-pane-surfaces` returns one entry per surface with a `selected: true` flag for the focused one. **Always read the focused surface first** — `read-screen` returns blank for non-focused surfaces on some builds, even with `--surface` set.

### Step 4 — Focus (if needed) + send text/keys

```bash
SOCK=/tmp/cmux-debug-dev-fork.sock
WS=workspace:34
TARGET_PANE=pane:67
TARGET_SURFACE=surface:123

# 4a. Focus (only if target surface is NOT the focused one)
cmux --socket "$SOCK" focus-pane --workspace="$WS" --pane="$TARGET_PANE"

# 4b. Send text
cmux --socket "$SOCK" send --workspace="$WS" --surface="$TARGET_SURFACE" "/web-advice"

# 4c. Press Enter
cmux --socket "$SOCK" send-key --workspace="$WS" --surface="$TARGET_SURFACE" enter
```

**Build-dependent gotchas:**
- Some builds treat `cmux send` as global (no `--surface`); others require it. If your text goes to the wrong surface, you forgot the focus step in 4a.
- `cmux send-key` keys: `enter`, `tab`, `escape`, `backspace`, `delete`, `up`, `down`, `left`, `right`. No `ctrl+*` combinations are accepted in dev builds — use a literal `enter` after the text.
- Long input strings (>500 chars) get truncated on dev builds. For `/web-advice` prompts with full evidence citations, send the prompt in two halves if needed.

### Step 5 — Wait + poll for response

The user said "have the terminals all run /web-advice." That requires a response, not just a send. **You cannot `wait` for an LLM-driven response over cmux — there is no completion signal.** You must poll.

Standard poll recipe:

```bash
SOCK=/tmp/cmux-debug-dev-fork.sock
WS=workspace:34
TARGET=surface:123
MAX_WAIT_S=60
INTERVAL=5

for i in $(seq 1 $((MAX_WAIT_S / INTERVAL))); do
  sleep "$INTERVAL"
  TAIL=$(cmux --socket "$SOCK" read-screen --workspace="$WS" --surface="$TARGET" --lines 200 2>/dev/null | tail -3 | tr -d ' \n')
  # Liveness heuristic: is the surface still "Working / Running / Thinking"?
  if echo "$TAIL" | grep -qiE "running|working|thinking"; then
    echo "t=$((i*INTERVAL))s  still-active"
    continue
  fi
  echo "t=$((i*INTERVAL))s  IDLE — response received"
  break
done
```

**60-second hard-fail rule** (from `review/web-advice` SKILL §1): a poll cycle that exceeds 60s without an observed response is a hard-fail signal. Do not keep polling hoping for the next iteration to work — surface the partial state to the user and ask for direction. Verified 2026-08-19: a Cursor/Grok 4.6 surface running `/web-advice` against a real PR can sit at "Thinking 8.26k tokens" for 90+ seconds without emitting a verdict; that's a real failure, not a near-miss.

## What NOT to do

- **Don't `killall` / `osascript quit` the user's Chrome to "fix" cmux surfaces.** If a surface is hung, ask the user. Verified dead-end from memory: bouncing Chrome doesn't unstick cmux either, and the user loses state in unrelated tabs.
- **Don't trust the shim's `--socket` default.** Always enumerate `/tmp/cmux*.sock` + `/private/tmp/cmux*.sock` + `~/.local/state/cmux/cmux.sock` first.
- **Don't `read-screen` a non-focused surface without re-running `list-pane-surfaces` first.** Surface IDs rotate when panes are recreated.
- **Don't send a Hermes-specific slash command (e.g. `/web-advice`, `/ms`, `/meta`) to a non-Hermes surface.** Antigravity/Gemini-3.7-Flash and Cursor/Grok-4.6 surfaces will respond with `Unknown command: /web-advice` and treat it as a failed user input. Use natural-language equivalents for non-Hermes surfaces ("Run a multi-model review (ChatGPT/Gemini/Grok/Perplexity) on this PR...").
- **Don't declare a workspace "frozen" based on a static status bar alone.** A workspace with active time-on-task labels ("Churned for Xm", "Sautéed for Xm") is working, regardless of the status bar. Verified heuristic from user-owned `cmux` SKILL §"Status Bar Interpretation".

## Pitfalls (verified 2026-08-19 nocturne workspace task)

1. **Title ≠ topic keyword.** The user said "nocturne" but the actual workspace title was `nocturne cannot load`. Always grep the full title column, not just the topic substring.
2. **Two surfaces, two tool stacks.** A single workspace can host Claude Code, Antigravity, AND Cursor surfaces simultaneously — they have different slash-command support and different response shapes. Identify the tool stack from the status bar (e.g. `Gemini 3.7 Flash · high`, `Cursor Grok 4.6 High · 51.2%`) before sending commands.
3. **`/web-advice` is Hermes-only.** Cursor/Antigravity/Claude Code surfaces don't know it. Detect by the first response: `Unknown command: /web-advice` means send a natural-language equivalent.
4. **Cursor's "Working" spinner can stay on for 90s+.** Don't treat 60s as failure for Cursor specifically — give it 90-120s, but per `review/web-advice` §1, **60s without a verdict is a hard-fail for the panel review itself** (the panel was supposed to be parallel + fast).
5. **Worktrees behind cmux surfaces can be in 3+ canonical locations.** See the `cmux-find-workspace-by-topic` skill for the worktree-scan fallback when no surface matches a topic.
6. **Evidence files attached to a cmux-driven worktree may live in a reaped `/tmp/wt-<id>/evidence/` path.** Always `git status` + `git log` the worktree's branch to see what's actually committed before citing a local path.

## Cross-references

- `cmux` (user-owned) — CLI / socket reference, status-bar interpretation, multi-session pattern
- `cmux-find-workspace-by-topic` (user-owned) — 3-step recipe for finding a workspace by topic keyword
- `review/web-advice` — multi-model review command; defines the 60s hard-fail rule and the panel-truthfulness contract
- `coding-wave-liveness-check` (curator-managed) — liveness verification for claudem worker waves (different machinery: workers, not cmux surfaces)
- `bidi-cmux-alignment` — bidirectionally steering cmux lanes (opt-in, not default)

## Suggested verification after a steering run

After sending a command and reading the response, post a single concise status block to the user:

```text
Surface <id> sent `<cmd>`. Status: <🟢 verdict-received | 🟡 still-thinking | 🔴 hung-past-60s>.
Verdict: <1-line summary if available>.
Next: <single concrete action for the user, or "none — auto-cleanup in <cron-id>">.
```

Avoid multi-option menus on steering tasks — the user wants to know the state of one thing, not a fork.
