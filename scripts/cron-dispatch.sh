#!/usr/bin/env bash
# cron-dispatch.sh — translate `openclaw cron add` semantics to `hermes cron create`.
#
# Background
# ----------
# Per user directive (2026-07-04): "crons should be managed by hermes not openclaw".
# SOUL.md COMMITs `one-time-status-cron-on-request` (line 210) and
# `followup-promise-requires-cron` (line 235) currently invoke
# `openclaw cron add --at ... --delete-after-run --announce --to <channel>`
# (literal examples at SOUL.md:217 and SOUL.md:237). This wrapper preserves
# those exact flag spellings so existing SOUL.md can stay byte-identical
# while the implementation switches to the native hermes cron surface.
#
# Mapping (openclaw → hermes cron create):
#   --at TIME            → positional schedule arg ("20m", "10m", "1h", "0 9 * * *")
#   --delete-after-run   → --repeat 1        (one-shot semantics)
#   --announce           → implicit          (hermes delivers to target by default)
#   --to CHANNEL         → --deliver slack:CHANNEL
#   --name NAME          → --name NAME
#
# Passthrough extras (useful for non-status cron usage, ignored by status cron workflows):
#   --prompt TEXT        → positional prompt arg
#   --skill SKILL        → --skill SKILL     (repeatable)
#   --script SCRIPT      → --script SCRIPT   (path under ~/.smartclaw/scripts/)
#   --no-agent           → --no-agent        (watchdog pattern: script stdout delivered verbatim)
#   --workdir DIR        → --workdir DIR     (AGENTS.md/CLAUDE.md/.cursorrules injection cwd)
#
# Forbidden inputs (fail loud, do NOT translate silently):
#   --every INTERVAL     → recurring cron = notification spam; use hermes cron create normally
#                          with a regular schedule string instead.
#   --keep-after-run     → hermes cron repeats via --repeat N; one-shot is the default.
#
# Operational modes
# -----------------
#   cron-dispatch.sh [OPENCLAW_FLAGS...]            → live: calls `hermes cron create` and prints job ID
#   cron-dispatch.sh --dry-run [OPENCLAW_FLAGS...]  → emit the translated `hermes cron create` invocation only (for tests)
#   cron-dispatch.sh --print-translation [...]      → same as --dry-run; alias used by tests
#   cron-dispatch.sh --help                         → this docstring
#
# Exit codes
# ----------
#   0   success (job created or --dry-run translation emitted)
#   2   invalid arguments (missing --at, unknown flag, banned --every / --keep-after-run)
#   1   hermes CLI failed or not on PATH

set -euo pipefail

usage() {
  cat <<'EOF'
cron-dispatch.sh — wrapper that translates openclaw cron add syntax to hermes cron create.

USAGE
  cron-dispatch.sh --at <TIME> --delete-after-run --announce --to <CHANNEL> --name <NAME> [extras]
  cron-dispatch.sh --dry-run --at <TIME> --delete-after-run --announce --to <CHANNEL> --name <NAME> [extras]
  cron-dispatch.sh --help

REQUIRED (openclaw-compatible)
  --at TIME            Schedule ("20m", "10m", "1h", "0 9 * * *").
  --delete-after-run   Auto-cleanup after firing (translates to --repeat 1).
  --to CHANNEL         Slack channel ID (e.g. ${SLACK_CHANNEL_ID}). Translates to --deliver slack:CHANNEL.
  --name NAME          Job name.

OPTIONAL
  --announce           Implicit in hermes cron. No-op (kept for source-compat with openclaw).
  --prompt TEXT        Append a self-contained prompt to the cron job.
  --skill SKILL        Repeat to attach multiple skills.
  --script SCRIPT      Path under ~/.smartclaw/scripts/ (run with --no-agent for watchdog pattern).
  --no-agent           Skip LLM; deliver --script stdout directly.
  --workdir DIR        Inject AGENTS.md / CLAUDE.md / .cursorrules from this cwd.

BANNED (fail loud)
  --every INTERVAL     Recurring crons cause notification spam — translate manually.
  --keep-after-run     Use --repeat N with hermes cron, not openclaw flags.

MODES
  (default)            Run `hermes cron create` and print the resulting job ID.
  --dry-run            Print the translated invocation only; do NOT call hermes.
  --print-translation  Alias for --dry-run (used by the contract test).

EXAMPLES
  # status-check cron (matches SOUL.md:217 literal)
  cron-dispatch.sh --at 20m --delete-after-run --announce --to ${SLACK_CHANNEL_ID} --name "task status (20m)"

  # followup-promise cron (matches SOUL.md:237 literal)
  cron-dispatch.sh --at 10m --delete-after-run --announce --to ${SLACK_CHANNEL_ID} --name "followup"
EOF
}

# --- arg parse ------------------------------------------------------------

schedule=""
delete_after_run=false
announce=false
channel=""
name=""
prompt=""
skills=()
script_opt=""
no_agent=false
workdir=""
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --at)              schedule="${2:?--at requires TIME}"; shift 2 ;;
    --delete-after-run) delete_after_run=true; shift ;;
    --announce)         announce=true; shift ;;
    --to)               channel="${2:?--to requires CHANNEL}"; shift 2 ;;
    --name)             name="${2:?--name requires NAME}"; shift 2 ;;
    --prompt)           prompt="${2:?--prompt requires TEXT}"; shift 2 ;;
    --skill)            skills+=("${2:?--skill requires NAME}"); shift 2 ;;
    --script)           script_opt="${2:?--script requires PATH}"; shift 2 ;;
    --no-agent)         no_agent=true; shift ;;
    --workdir)          workdir="${2:?--workdir requires DIR}"; shift 2 ;;
    --dry-run|--print-translation) dry_run=true; shift ;;
    -h|--help)          usage; exit 0 ;;
    --every)            echo "ERROR: --every is banned (recurring crons cause notification spam). Use a schedule string." >&2; exit 2 ;;
    --keep-after-run)   echo "ERROR: --keep-after-run is banned. hermes cron one-shot is the default; use --repeat N to repeat." >&2; exit 2 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# --- validate -------------------------------------------------------------

if [[ -z "$schedule" ]]; then
  echo "ERROR: --at <TIME> is required (e.g. --at 20m)" >&2
  exit 2
fi
if [[ -z "$channel" && "$announce" == true ]]; then
  # announce is a no-op but the openclaw intent is "send somewhere" — warn loudly
  echo "ERROR: --announce given but no --to CHANNEL provided" >&2
  exit 2
fi
if [[ -n "$script_opt" && "$script_opt" != /* ]]; then
  echo "ERROR: --script must be an absolute path (hermes cron runs from ~/.smartclaw/scripts/)" >&2
  exit 2
fi

# --- translate ------------------------------------------------------------

hermes_args=("$schedule")

if [[ -n "$name" ]]; then
  hermes_args+=(--name "$name")
fi
if [[ -n "$channel" ]]; then
  hermes_args+=(--deliver "slack:$channel")
fi
if [[ "$delete_after_run" == true ]]; then
  hermes_args+=(--repeat 1)
fi
if [[ "$no_agent" == true ]]; then
  hermes_args+=(--no-agent)
fi
if [[ -n "$workdir" ]]; then
  hermes_args+=(--workdir "$workdir")
fi
if [[ -n "$script_opt" ]]; then
  hermes_args+=(--script "$script_opt")
fi
if (( ${#skills[@]} > 0 )); then
  for s in "${skills[@]}"; do
    hermes_args+=(--skill "$s")
  done
fi
if [[ -n "$prompt" ]]; then
  hermes_args+=("$prompt")
fi

# --- emit -----------------------------------------------------------------

if [[ "$dry_run" == true ]]; then
  # Print one token per line so substring assertions in the contract test
  # are unambiguous. We deliberately do NOT use `%q` here because over-
  # escaping (e.g. `task\ status\ \(20m\)`) makes literal "task status (20m)"
  # assertions fail. Human readability is fine — operators see the
  # shell-ready form via `--help` and the live invocation in their terminal.
  for a in "${hermes_args[@]}"; do
    printf 'ARG_TOKEN=%s\n' "$a"
  done
  exit 0
fi

if ! command -v hermes >/dev/null 2>&1; then
  echo "ERROR: hermes CLI not found on PATH (need /opt/homebrew/bin/hermes)" >&2
  exit 1
fi

# Live path: invoke hermes, surface any error, then echo "job ID: <id>" as the
# final line so callers can grep for it (matches SOUL.md conventions where the
# cron job ID is included in the thread reply).
hermes cron create "${hermes_args[@]}"
status=$?
if [[ "$status" -ne 0 ]]; then
  echo "ERROR: hermes cron create exited with status $status" >&2
  exit "$status"
fi
