#!/usr/bin/env bash
# lib-llm-judgment.sh
#
# Shared helper for the LLM judgment call used by:
#   - scripts/slack-thread-roadmap-report.sh  (every-4h cron)
#   - scripts/slack-thread-roadmap-demo.sh    (one-shot demo)
#
# Exports a single function:
#   llm_judgment_for_threads <tmpdir> <num_threads> <threads_bundle>
#     tmpdir:           scratch dir for the LLM response file
#     num_threads:      integer (for logging)
#     threads_bundle:   newline-delimited thread reports (CHANNEL=... blocks)
#   Echoes:   the LLM judgment text (markdown) on success
#   Returns:  0 on success; non-zero on failure (caller should fall back to
#             heuristic-only or skip the report)
#
# Side effects:
#   - Writes <tmpdir>/llm-resp.txt with the raw LLM response
#
# Inference: routes through `hermes chat -q -Q --max-turns 1` so we use the
# canonical Hermes pipeline (provider failover, memories, session naming)
# instead of hitting the API directly. This is the same pattern used by
# ~/.smartclaw/scripts/doctor.sh for the gateway inference probe.
#
# DRY: this is the only place the LLM prompt template lives. If the prompt
# or the judgment schema changes, edit here once.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"

# Filter the final response for a structured output: drop the "no auxiliary
# LLM provider" warning, the "Memories used:" line, and the trailing
# "session_id:" line so the report body is clean markdown.
hermes_judgment_clean() {
  local resp_file="$1"
  # Drop warning banner (lines starting with ⚠), the "🧠 Memories used:" line
  # and everything after the first "session_id:" line. Also strip the
  # "⚠ No auxiliary LLM provider configured" warning.
  python3 -c '
import re, sys
text = open(sys.argv[1]).read()
# Split off everything from the first "session_id:" line onwards
parts = re.split(r"^session_id:", text, maxsplit=1, flags=re.MULTILINE)
body = parts[0]
# Drop the "Memories used:" line
body = re.sub(r"^🧠 Memories used:.*$", "", body, flags=re.MULTILINE)
# Drop warning lines starting with ⚠
body = re.sub(r"^⚠.*$", "", body, flags=re.MULTILINE)
# Trim trailing whitespace per line + drop leading/trailing blank lines
lines = [ln.rstrip() for ln in body.split("\n")]
while lines and not lines[0].strip():
  lines.pop(0)
while lines and not lines[-1].strip():
  lines.pop()
print("\n".join(lines))
' "$resp_file"
}

llm_judgment_for_threads() {
  local tmpdir="$1" num_threads="$2" threads_bundle="$3"

  if ! command -v hermes >/dev/null 2>&1; then
    echo "llm_judgment_for_threads: hermes CLI not found in PATH" >&2
    return 1
  fi

  local now_local now_iso
  now_local=$(date '+%Y-%m-%d %H:%M:%S %Z')
  now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  local prompt
  prompt=$(cat <<EOF
You are an executive assistant for Jeffrey. It is $now_local ($now_iso). You are scanning $num_threads actionable Slack threads from the last 48 hours. For each thread, produce a structured judgment. Be terse — Jeffrey reads this at 4h intervals and only needs enough detail to decide whether to /a (auto-arm the next session to drive it) or /auto (spawn a worker on it).

For each thread, output a markdown section like this (exactly):

### <one-line title: what's the thread about?>
- **Channel**: <id>
- **Thread**: <thread_url>
- **Kind**: <dropped-thread kind: cold | stale-dispatch | timeout-failure | standalone | admitted>
- **Why dropped**: <one sentence — what went wrong>
- **Current state**: <1-2 lines: who said what last, where the work is>
- **Can /a drive this?**: yes | no | partially — <one-line reason>
- **Can /auto drive this?**: yes | no | partially — <one-line reason>
- **Recommended next command**: \`/a <thread_url>\` OR \`/auto <thread_url>\` OR \`<exact command Jeffrey should run>\` — include a 1-line rationale
- **Risk if ignored 24h**: low | medium | high — <one line>

If a thread is clearly already done (PR merged, fix deployed, user said "thanks"), say so explicitly and recommend "no action — close".

If a thread needs human judgment (e.g. "which option do you want"), say so and recommend \`/clarify <thread_url>\`.

At the end, output a one-paragraph executive summary (3-5 lines) of the top 2-3 things Jeffrey should look at first.

Do NOT make up thread contents. If a digest says "[parse error]" or is empty, mark the thread as "unreadable — manual review needed".

THREADS:
$threads_bundle
EOF
)

  local resp_file="$tmpdir/llm-resp.txt"
  local err_file="$tmpdir/llm.err"
  : > "$err_file"

  # -Q = quiet (no banner/spinner), --max-turns 1 = one-shot, -q = query mode.
  # Matches the doctor.sh inference probe pattern (the canonical script-level
  # way to call the gateway LLM).
  # 600s = 10min cap. Real cron runs (25-thread bundles) take 2:50-3:05
  # wallclock (per prod comment); 360s was at the edge and produced
  # KeyboardInterrupt at the SIGTERM cutoff (hermes cli installs SIGTERM
  # → KeyboardInterrupt). 600s gives 3x headroom for slow LLM days.
  # See memory: project_2026-06-22_lib_llm_keyboard_interrupt.md
  if ! timeout 600 hermes chat -q "$prompt" -Q --max-turns 1 \
        > "$resp_file" 2> "$err_file"; then
    local rc=$?
    echo "llm_judgment_for_threads: hermes chat failed rc=$rc" >&2
    # Detect KeyboardInterrupt specifically — hermes cli converts SIGTERM
    # to KeyboardInterrupt with rc=0, which `if !` swallows. Check stderr
    # for the traceback signature.
    if grep -q "KeyboardInterrupt" "$err_file" 2>/dev/null; then
      echo "llm_judgment_for_threads: detected KeyboardInterrupt (SIGTERM→KBInt via hermes cli); timeout too short" >&2
    fi
    head -3 "$err_file" >&2 || true
    return 1
  fi
  if [[ ! -s "$resp_file" ]]; then
    echo "llm_judgment_for_threads: hermes chat returned empty response" >&2
    head -3 "$err_file" >&2 || true
    return 1
  fi

  hermes_judgment_clean "$resp_file"
}
