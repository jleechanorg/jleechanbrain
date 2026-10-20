# Foreground-Arming a Babysit from a Hermes Gateway Session

The skill covers the *tick loop*. This reference covers the *arming* — the first call that launches the babysit from an interactive Hermes session (Slack wake-up, MCP gateway, direct CLI prompt). The two failure modes below are the ones you'll hit first, before any tick has fired.

## Failure mode 1 — foreground timeout kills the babysit immediately

`bash ~/.smartclaw/skills/hermes-imports/dispatch-task/scripts/babysit-one-session.sh <session> <phenotype> <channel> <thread_ts>` runs a 300s polling loop. If you call it from a `terminal()` foreground call with the default 180s timeout, the shell returns exitcode 124 ("timed out") after 180s. The bash child is SIGKILLed. The babysit is dead.

The first poll usually fires before the timeout (you'll see it echo "babysit started" + "poll #1" in the OUT-OF-BAND channel), so the operator does see the arm message — but every subsequent tick is also dead.

**The fix:** use `terminal(background=true, notify_on_complete=false)` and read the session_id back. Then verify with `process(action='poll')`:

```bash
# Don't:
terminal(command="bash .../babysit-one-session.sh ...")  # 180s timeout → SIGKILL

# Do:
terminal(background=true, notify_on_complete=false,
         command="bash .../babysit-one-session.sh <session> <pheno> <chan> <ts>")
# → returns session_id immediately, script keeps running detached
process(action='poll', session_id='<returned_id>', timeout=5)  # confirm alive
```

`notify_on_complete=true` is the WRONG choice for a long-lived polling loop — the "completion" you're notified of is the babysit exiting, which by design is hours later. The runtime will spam you with one notification per babysit arm. Use `false` and rely on the in-thread Slack messages the script itself posts.

Top-level `nohup ... &` is also blocked by the runtime:
```
Error: Foreground command uses shell-level background wrappers
(nohup/disown/setsid). Use terminal(background=true) so Hermes can
track the process, then run readiness checks and tests in separate
commands.
```
The `&` + `> log 2>&1` + `disown` pattern is right for a Linux box but not here.

## Failure mode 2 — env-stripped subprocess can't reach Slack

`bash .../babysit-one-session.sh` reads `SLACK_BOT_TOKEN` from the env. The script's token resolution chain is `$OPENCLAW_SLACK_BOT_TOKEN → $SLACK_MCP_XOXB_TOKEN → $SLACK_BOT_TOKEN`. If all three are unset in the babysit's env, the script posts nothing.

`SLACK_BOT_TOKEN` is normally sourced from `~/.bashrc`. The Hermes gateway bashrc is loaded into the interactive shell. But `terminal(background=true)` spawns a child via the shell's job-control machinery, which can inherit the env in a way that depends on the runtime. If the first poll fires and posts nothing, suspect this.

**Verification recipe (run once at arm time, before trusting the loop):**

```bash
# After terminal(background=true) returns the session_id, capture & verify env:
PROCESS_ID=$(process action=poll session_id=<id> | jq -r '.pid')
ps eww -p $PROCESS_ID | tr ' ' '\n' | grep -E 'SLACK|HERMES' | head -5
# Should show SLACK_BOT_TOKEN=xoxb-... AND/OR SLACK_MCP_XOXB_TOKEN=...
# If empty: launch with env explicitly:
SLACK_BOT_TOKEN="$SLACK_BOT_TOKEN" \
  bash .../babysit-one-session.sh <session> <pheno> <chan> <ts>
```

Or pre-flight: `terminal(command='bash -c "source ~/.bashrc && env | grep -E SLACK | head -3"')` from the gateway shell to confirm the vars are exported before you detach.

## Failure mode 3 — diagnostic chatter lands in the operator thread

The arming dance includes per-step `process` polls, intermediate token-resolution checks, and (very commonly) several `execute_code` blocks each printing Python stdout. If those echoes go to Slack on the same channel, the operator sees 4-8 noisy "Snake: Running code..." messages BEFORE the load-bearing reply.

**The fix:** don't post intermediate diagnostic chatter to the operator's Slack thread. If you must `chat.postMessage` while arming, post a single arm-notification ("*Babysit armed for session X, 5-min polls, 120-min budget*") and stop. Use `conversations_replies` (local debug) instead of `chat.postMessage` (operator-visible) for everything else.

If intermediate chatter has already landed, do NOT post a corrective "sorry for the noise" message — that just adds more noise. The operator's load-bearing reply at the bottom of the thread is the only thing they read.

## The 4-step arming recipe (foreground gateway, single-session)

```bash
# 1. Confirm pre-conditions (read-only, no Slack posts)
ps -ef | grep -E "babysit-one-session" | grep -v grep    # zero matches → safe to arm
tail -3 /tmp/<pheno>-babysit.log 2>/dev/null || echo "no prior log"  # make sure stale log not overwriting

# 2. Spawn detached (does NOT post yet)
SESSION="<session-id>"            # from `ao session ls`
PHENO="<short-slug>"              # controls /tmp/<pheno>-babysit.log path
CHAN="<channel-id>"
THREAD="<thread_ts>"
BGBT="${SLACK_BOT_TOKEN:-}"  # explicit export, don't rely on inherit
terminal(background=true, notify_on_complete=false,
         command="SLACK_BOT_TOKEN='$BGBT' bash ~/.smartclaw/skills/hermes-imports/dispatch-task/scripts/babysit-one-session.sh '$SESSION' '$PHENO' '$CHAN' '$THREAD' 24 300")

# 3. Wait ~5s, verify detached process is alive (not the kernel killing it via SIGKILL on timeout)
sleep 5
ps -ef | grep babysit-one-session | grep -v grep | head -1
# Should show a row with the bash PID. If empty: re-arm with env pre-sourced.

# 4. ONE chat.postMessage to the operator thread (galaxy-brain default — keep the
#    arm ping)*not* a multi-message diagnostic dump. Then stop.
```

## Anti-patterns

- ❌ Foreground `terminal()` call with default timeout — dead-loop after 180s.
- ❌ `nohup ... &` / `disown` — runtime blocks shell-level background wrappers.
- ❌ `notify_on_complete=true` on a long-lived polling loop — abandonment notification, not status.
- ❌ Multi-message diagnostic chatter in the operator thread during arm.
- ❌ Relying on env inheritance without verifying — first poll may silently no-op.
- ❌ Calling `ao status --json` expecting per-session detail. It returns only daemon status (state, pid, port, ready). For per-session state use `ao session ls --project <name>` or `tmux capture-pane -t <session> -p`.

## Reference

Verified 2026-08-05 on AO worker `worldarchitect-195` (dispatch `wa-funnel-diag`). First-arm timeout burned ~30s of CEO recovery window; 4 intermediate diagnostic messages landed in the operator thread before the load-bearing reply. Recovery: detached polling script + explicit env + single arm-ping.
