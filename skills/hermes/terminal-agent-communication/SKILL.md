---
name: terminal-agent-communication
description: "Send instructions or status checks to cmux-managed coding agents (Claude Code, Codex, etc.). Use when directing work to cmux workspaces, asking terminals for status, or dispatching next steps to agent subprocesses. Covers: composing Hermes-identification messages, meta-check patterns, response routing, and anti-patterns (one-way fire-and-forget)."
when_to_use: "Use when sending instructions, status checks, or nudges to cmux terminal agents. Triggers: any message asking terminals to do something, check status, or take next steps. Also use proactively before giving directives to verify instructions match the terminal's actual state."
arguments:
  - workspace_ref
  - surface_ref
  - message_type
  - task_context
argument-hint: "[workspace_ref] [surface_ref] [message_type] [task_context]"
context: inline
---

# Terminal Agent Communication — Hermes → cmux Agent Norms

## Core Principle

**Every directive to a cmux terminal agent must include a meta-check.** Fire-and-forget creates context drift. The agent in the terminal knows more about its actual state than you do from outside. Always give it room to push back.

## The Mandatory Hermes Introduction

Every message to a terminal agent must identify Hermes and distinguish Hermes from a human:

```
Quick meta-check from Hermes (your orchestrator): [instruction]. I'm Hermes, an AI agent, not a human. If my instructions don't match what you're actually working on, or if anything's unclear, please push back or ask. What are you currently looking at?
```

## Trigger Conditions (when to use this skill)

- Sending any task/instruction to a cmux terminal
- Asking a terminal to "check status", "run next steps", or "do X"
- Dispatching work after reading terminal state from the outside
- Nudging a stuck or looping agent

## Message Types

### 1. Directive (task assignment)

```
Quick meta-check from Hermes (your orchestrator): I'm asking you to [specific task]. Does that match what you're actually looking at right now? I'm Hermes, an AI agent — not a human. If my instruction doesn't fit your actual state, please push back. What are you currently working on?
```

### 2. Status check (no directive)

```
Quick check from Hermes (your orchestrator): Can you give me a one-line status on [PR/branch]? I'm checking in from outside your terminal. I'm Hermes, an AI agent. Anything blocking or unexpected I should know about?
```

### 3. Nudge (agent stuck/looping)

```
Quick nudge from Hermes (your orchestrator): It looks like you may be stuck/looping on [symptom]. I'm Hermes, an AI agent. If the fix is already applied, just [concrete next action]. If something else is wrong, tell me what you actually need. Do not keep searching for fixes that aren't there.
```

### 4. Clarification request

```
Quick question from Hermes (your orchestrator): You mentioned [observation from terminal]. I'm Hermes, an AI agent reading your terminal from outside. Can you confirm: [specific question]?
```

## Anti-Patterns

- **One-way fire-and-forget**: Don't send directives without the meta-check intro. The agent's actual state will drift from what you think it's doing.
- **Human identification**: Never imply Hermes is a human. Always say "I'm Hermes, an AI agent."
- **Vague nudges**: "Are you stuck?" is less useful than "It looks like you're looping on [specific symptom] — if fix is already applied, just [concrete action]."
- **Assuming terminal state**: Don't say "I can see you're working on X" unless you actually read the terminal content. Read first, then speak.

## cmux send Command — TWO-STEP REQUIRED: send THEN Enter

**`cmux send` types text into the terminal buffer but does NOT execute it.** The text sits at the prompt inert. This is the #1 failure mode when steering terminals remotely — discovered through repeated missed keystrokes.

**Every `cmux send` MUST be followed immediately by `cmux send-key enter`:**

```bash
export CMUX_SOCKET_PATH=/private/tmp/cmux-debug-appclick.sock

# WRONG — text typed but never submitted
cmux send --workspace <workspace_ref> --surface <surface_ref> "<message>"

# CORRECT — two commands, one right after the other
cmux send --workspace <workspace_ref> --surface <surface_ref> "<message>"
cmux send-key --workspace <workspace_ref> --surface <surface_ref> "enter"
```

**Multi-line commands:** Send each line separately with Enter after each:
```bash
cmux send --workspace $ws --surface $surf "git add -A"
cmux send-key --workspace $ws --surface $surf "enter"
cmux send --workspace $ws --surface $surf "git commit -m 'fix: description'"
cmux send-key --workspace $ws --surface $surf "enter"
```

**Finding the correct surface ref for a workspace:**
```bash
# List all surfaces in a workspace — the [selected] marker shows the focused surface
cmux list-pane-surfaces --workspace <workspace_ref>
# Example output:
# * surface:3  Terminal  [selected]   ← surface:3 is the focused pane
#   surface:2  Terminal
```

**Preview-Before-Send Pattern:** When asked to show messages before sending (e.g. "show me what you'll send first"), compose all messages and print them for user review. Send only after user confirms. Always send + Enter within ~10s of each other while the terminal is still focused.

**Multi-Workspace Broadcast (driving N agents):**
1. Read all relevant workspaces' scrollback first (one round of reads)
2. Compose one message per workspace tailored to what each agent is actually doing
3. Print all messages to user for review (preview step)
4. Send + Enter to each workspace in sequence, waiting ~3-5s between each
5. Wait 5-10 min, then read updated terminal states to verify agents responded

## Workflow

1. **Read the terminal first** — `cmux read-screen --workspace X --lines 50 --scrollback` to see what the agent is actually working on
2. **Find the focused surface** — `cmux list-pane-surfaces --workspace X`, use the `* [selected]` surface
3. **Compose message** — include Hermes ID + meta-check + specific task/statement
4. **Preview** — show user the messages before sending (if requested)
5. **Send + Enter** — `cmux send ...` immediately followed by `cmux send-key ... "enter"`
6. **Wait for response** — check terminal after sending for the agent's reply
7. **If agent pushes back** — adjust the instruction based on what the agent reports

## Skill Completeness Checklist

- [x] SKILL.md — this file
- [ ] Code — none (pure LLM communication pattern)
- [ ] Unit tests — N/A (communication pattern)
- [ ] Integration tests — N/A
- [ ] LLM evals — N/A
- [ ] Resolver trigger — add to RESOLVER.md: "send to terminal", "message terminal", "nudge agent", "terminal check"
- [ ] Resolver trigger eval — N/A
- [ ] check-resolvable — N/A
- [ ] E2E test — manual verification
- [ ] Brain filing — N/A

## Related Skills

- `cmux` — for reading terminal content before speaking
- `bidi-cmux-alignment` — for Slack↔cmux bidirectional alignment loops
- `dispatch-task` — for AO-dispatched work (different from cmux terminal direct)
