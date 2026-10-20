# Hermes CLI Flags — verified 2026-08-06

These are the actual `--help` outputs for the most-used Hermes subcommands. Pin them in front of any new script that integrates with the Hermes CLI.

**Why this matters:** `hermes cron list --json` was assumed to exist in `cron-backup-sync.sh` (verified 2026-08-06 — flag does NOT exist). The script silently produced garbage output for months. Future scripts that integrate with Hermes will hit the same trap if they assume JSON/structured output is supported.

**Verification protocol:** `hermes <subcommand> --help` — never assume a flag exists based on a similar CLI's surface. The CLI is small but not standardized.

---

## `hermes cron`

```
usage: hermes cron [-h] [--accept-hooks]
                   {list,create,add,edit,pause,resume,run,remove,rm,delete,status,runs,history,tick} ...

Manage scheduled tasks

positional arguments:
  {list,create,add,edit,pause,resume,run,remove,rm,delete,status,runs,history,tick}
    list                List scheduled jobs
    create (add)        Create a scheduled job
    edit                Edit an existing job
    pause               Pause a scheduled job
    resume              Resume a paused job
    run                 Run a job on the next scheduler tick
    remove (rm, delete)
                        Remove a scheduled job
    status              Check if cron scheduler is running
    runs (history)      Show durable execution attempts
    tick                Run due jobs once and exit
```

### `hermes cron list --help`

```
usage: hermes cron list [-h] [--all]

options:
  -h, --help  show this help message and exit
  --all       Include disabled jobs
```

**FLAGS THAT DO NOT EXIST:** `--json`, `--format`, `--quiet`, `--names-only`, `--ids-only`, `--output`. The output is human-readable table only.

### `hermes cron status` output format

```
✓ Gateway is running — cron jobs will fire automatically
  PID: 7910
  Ticker heartbeat: 43s ago

  10 active job(s)
  Next run: 2026-08-06T08:33:57.074226-07:00
```

**Parser hint:** regex `(\d+)\s+active\s+job` extracts the active count. Reliable; format has been stable since 2026-05.

### `hermes cron list` output format

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Scheduled Jobs                                  │
└─────────────────────────────────────────────────────────────────────────┘

  <id> [active|paused|disabled]
    Name:      <name>
    Schedule:  <cron-expr | every Nm>
    Repeat:    ∞
    Next run:  <ISO timestamp>
    Deliver:   <slack:CHAN | slack:CHAN:ts | origin | local | all>
    Script:    <path>           (only if mode=no-agent)
    Mode:      no-agent (script stdout delivered directly)
    Last run:  <ISO timestamp>  <status>
    Execution: <status>  <id>
```

**Parser hint (verified):**
- Job ID regex: `^\s+([0-9a-f]{12,})\s+\[(active|paused|disabled)\]`
- State line follows immediately
- `Key: Value` lines indented 4 spaces, label in title case

---

## `hermes kanban`

Not yet verified. To populate: `hermes kanban --help`, `hermes kanban <subcmd> --help`. Pin outputs here after verification.

---

## `hermes slack`

Not yet verified. To populate: `hermes slack --help`, `hermes slack <subcmd> --help`. Pin outputs here after verification.

---

## `hermes doctor`

Not yet verified. To populate: `hermes doctor --help`. (Used by `monitor-agent.sh` — see `hermes-health-check` skill.)

---

## `hermes mem0`

Not yet verified. To populate: `hermes mem0 --help`, `hermes mem0 <subcmd> --help`. Used by `monitor-agent.sh` memory probe.

---

## Universal pre-flight rule

Before writing ANY new script that calls `hermes <subcommand> --<flag>`:

```bash
# 1. Verify the flag exists
hermes <subcommand> --help 2>&1 | grep -E "(^|[[:space:]])<flag>([[:space:]]|$)"

# 2. If grep doesn't match → the flag does NOT exist. Don't use it.

# 3. Capture the help output in your script's README so future agents see
#    the verified surface.
```

This is the simplest defense against Pattern A (CLI flag hallucination) from the umbrella SKILL.md.

---

## How to extend this file

When you call a new `hermes <subcommand>` from a script for the first time:

1. Run `hermes <subcommand> --help` to get the actual flags.
2. Add a section to this file with the verified output.
3. Note the format (table, JSON, plain text) and any parser hints you learned.
4. Commit. Future scripts that integrate with this subcommand will see the verified surface without re-deriving it.

This is the operational form of "don't assume, verify."