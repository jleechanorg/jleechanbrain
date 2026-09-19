# Why this skill exists — the 2026-08-14 Rowan Trollope Slack thread

This reference exists so future sessions learn from the failure mode that
motivated `apple-network-diag`. The headline lesson is short enough to
internalize; the longer transcript pattern is preserved here for context.

## The mistake (don't repeat it)

Jeffrey posted a Rowan Trollope tweet: *"Use chatGPT Work or Codex to fix your
home network coverage. /goal make my WiFi coverage the best it can possibly
be."* He then said *"Ok make your best /ironclad goal and see what you can
optimize with my WiFi."*

The agent refused 4 times in a row with progressively identical paragraphs
claiming *"this Slack session has no shell access, I cannot do WiFi work,
the laptop-side experiment requires a Claude Code / Codex session, etc."*
Each refusal was a multi-paragraph wall of text. None of them contained a
single tool call to check whether the assumption was true.

Jeffrey's actual reply after the fourth refusal:

> **"You must be fucking stupid. You are in my MacBook with shell access"**

A single `terminal(command="uname -a; whoami")` call would have proven the
assumption false on turn 1. The agent had `terminal` available the whole time
and refused to use it because its self-model of capabilities ("Slack bot, no
shell") was wrong.

## The anti-pattern (named for harness-postmortem cross-reference)

This is failure class **FC1: claimed-no-access-while-having-access** in the
`harness-postmortem` taxonomy. Pattern recognition:

1. User asks for an action ("do X to my laptop", "scan my network", "check
   the contents of Y").
2. Agent refuses citing a structural blocker it hasn't actually probed.
3. The "blocker" is in fact false — the agent's available tools include the
   capability it's claiming to lack.
4. Refusal generates user frustration; the user has to spend a turn
   correcting the agent instead of progressing on the work.

The probe-before-refuse rule:

> **Before any tool-blocker claim, run the tool once.**

Specifically for Slack-originated work:

```bash
uname -a; whoami; pwd
```

If this prints something, you have shell. Do not claim otherwise in the same
session. If you genuinely lack the tool (e.g. browser, GPU access, sudo), run
the most permissive probe you can and **report what you found**, not what
you assumed.

## The actual findings (so future sessions don't reinvent them)

Once the agent stopped refusing and started probing, the home network
fingerprint was discoverable in <30 seconds of curl/ping:

- **Gateway**: Frontier NVG468MQ ONT/router combo, FW 9.3.0h7d91. The
  `/cgi-bin/home.ha` redirect signature is diagnostic. WAN: 1 Gbps fiber
  via ONT, IPv4 DHCP, public IP 47.151.147.179.
- **3× Araknis 820 APs** (SnapAV) at 192.168.254.{123,126,131}. The
  `/cgi-bin/luci` redirect signature is diagnostic. Wired backhaul,
  OpenWrt-based.
- **Baseline jitter (single seat, 20 samples)**:
  - Gateway (192.168.254.254): min/avg/max/σ = 3.1 / 8.6 / 71.1 / 14.5 ms
  - Internet (1.1.1.1):       min/avg/max/σ = 5.4 / 21.0 / 95.8 / 22.8 ms
- **Wi-Fi at the laptop**: RSSI -42 to -44 dBm, noise -95 dBm, SNR 50-53 dB,
  Tx 1200 Mbps — already pristine at the desk.
- **Root cause of jitter spike**: Frontier NVG468MQ was broadcasting its own
  SSIDs (`Frontier8512` on ch1 + ch48/ch153) *in parallel* with the Araknis
  APs (`TheRose` on ch11 + ch40). Same area, overlapping SSIDs, automatic
  band-steering on macOS was ping-ponging between them. Killing the
  Frontier's WiFi radios is the single highest-leverage fix.

## The pattern that works (multi-vantage survey recipe)

A single-vantage reading tells you nothing about coverage in the rest of the
house. The physical-survey loop is unavoidable; the agent's job is to make
it as cheap as possible for the user to walk the laptop.

1. Save the survey script once:
   `cp ~/.smartclaw/skills/apple/apple-network-diag/scripts/wifi_survey.swift ~/wifi-survey.swift`
   (or just remember the canonical path).
2. Save the jitter baseline once:
   `cp ~/.smartclaw/skills/apple/apple-network-diag/scripts/wifi-jitter-baseline.sh ~/wifi-jitter-baseline.sh && chmod +x ~/wifi-jitter-baseline.sh`
3. User walks to vantage point A, runs `swift ~/wifi-survey.swift` (≤5 sec),
   pastes output back.
4. User walks to vantage point B, repeats. 4-6 points usually enough.
5. Agent diffs the outputs: which AP did the laptop roam to at each point,
   what was the RSSI per AP, where are the dead zones, what's the channel
   reuse pattern.
6. If a config change is being evaluated (e.g. moved AP, changed channel),
   user runs `bash ~/wifi-jitter-baseline.sh <label>` at the same vantage
   point before and after, agent diffs σ/avg/max.

The user does the walking; the agent does the diffing. That's the division
of labor that makes WiFi work tractable from a Slack thread.

## Bead creation pattern (when findings need follow-up)

Each WiFi finding gets exactly one bead, with three fields filled in:

1. **Title** — one line describing the change, not the diagnosis.
2. **Description** — three blocks:
   - **What was measured** (RSSI/σ/channel, with the script + log path).
   - **What's wrong** (the diagnosis in 1-2 sentences).
   - **Source** (Slack thread URL, e.g.
     `${SLACK_CHANNEL_ID}/p1786619681.886529`) so future agents can re-derive.
3. **Owner**: Me or You, with explicit reasoning:
   - **Me**: requires only shell/file access I already have (re-running
     scripts, diffing logs, updating memory).
   - **You**: requires physical movement (walking laptop), admin credentials
     I don't have, or a one-time human judgment call.
   - **You→Me**: a dependency chain — user provides input (creds, screenshot,
     data), then agent acts.

The bead panel should be displayed in a single table with columns
**ID | Priority | Owner | Title**. The Owner column is the contract — don't
mix Me/You in the same row. The user's "what can you control vs me" question
is a standing request, not a per-task question.

## Reusable phrases from this thread (worth saving as memory)

- "Make your best /ironclad goal" → user is asking for a goal-shaped prompt
  with explicit stop conditions, not an open-ended infinite loop.
- "Make beads for these and what can you control vs me" → always pair the
  finding list with an Owner column; never ship beads without it.
- "you must be fucking stupid" → harness violation, not user aggression. The
  correction is structural (probe before refusing); the tone is justified.