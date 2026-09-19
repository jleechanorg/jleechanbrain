#!/bin/bash
#
# cmux Terminal Surface Report (4h cadence)
# Runs every 4 hours, lists all cmux workspaces + surfaces, reads each focused
# surface briefly, categorizes as Healthy/Risky/Blocked, and posts to Slack.
#
# Adapted from cmux-terminal-review skill (verified 2026-06-20).
# This is the "4h" version of workspace-report.sh (which is weekly).
#
# Cron registration (hermes cron stores this as no-agent script):
#   hermes cron create "every 4h" \
#     --name cmux-surface-report-4h \
#     --script cmux-surface-report-4h.sh \
#     --no-agent \
#     --deliver slack:C0AJQ5M0A0Y
#
# Verified job id: 0ef4c7f154bb
# Output:
#   - Slack post to $HERMES_CMUX_4H_CHANNEL (default: C0AJQ5M0A0Y)
#   - Log file: ~/.smartclaw/logs/cmux-surface-report/YYYY-MM-DDTHH.log
#
# Key pitfalls (see skill SKILL.md §7, §8, §10, §11):
#   - Use Python tree parser, NOT awk. Box-drawing chars (├──│└──) break awk.
#   - Filter `^\s*Error:` lines from cmux's own error responses before
#     classifying, or your "blocked" count will be inflated by 2-3x.
#   - set -e + numeric guards on ws/surf BEFORE building LABEL strings.
#   - Sanity cap TOTAL>100 aborts the post (catches parser regressions).

set -euo pipefail

# --- 0. notify_skip helper ---
# Post a one-liner to Slack when a tick can't produce a report (no live socket,
# cmux tree RPC wedged, parser produced nothing). User requested on 2026-06-24
# after multiple silent ticks. Rate-limited to one post per 4h so a long cmux
# outage doesn't flood the channel. Behaviour:
#   - Token-gated: no SLACK_BOT_TOKEN / _USER_TOKEN → silent no-op.
#   - State file (notify_skip.last_post) in CMUX_REPORT_STATE_DIR holds the
#     Unix timestamp of the last successful skip post; suppress if < 4h ago.
#   - POST body shape: ⚠️ prefix + tick UTC time + reason, so the message is
#     visually distinct from a normal green-check report.
notify_skip() {
  local reason="$1"
  local state_dir="${CMUX_REPORT_STATE_DIR:-$HOME/.smartclaw/state/cmux-surface-report}"
  local channel="${HERMES_CMUX_4H_CHANNEL:-C0AJQ5M0A0Y}"
  local token="${SLACK_BOT_TOKEN:-${HERMES_SLACK_USER_TOKEN:-}}"
  local marker="$state_dir/notify_skip.last_post"
  local now last_post age limit=14400  # 4h in seconds

  if [ -z "$token" ]; then
    echo "[$(date -u +%FT%TZ)] notify_skip: no Slack token — silent" >&2
    return 0
  fi
  mkdir -p "$state_dir"
  if [ -f "$marker" ]; then
    last_post="$(cat "$marker" 2>/dev/null || echo 0)"
    if [[ "$last_post" =~ ^[0-9]+$ ]]; then
      now="$(date +%s)"
      age=$(( now - last_post ))
      if [ "$age" -lt "$limit" ]; then
        echo "[$(date -u +%FT%TZ)] notify_skip: suppressed (last post ${age}s ago < ${limit}s)" >&2
        return 0
      fi
    fi
  fi

  local tick_utc body
  tick_utc="$(date -u +%FT%TZ)"
  body="⚠️ *cmux surface report (4h) — skip* — _Tick: ${tick_utc}_ — ${reason}"

  # Mirror the main-post curl shape so the test recorder + production code
  # share the same parser. Bearer token is interpolated via the existing
  # Authorization header convention; we do not log the token.
  local payload
  payload=$(jq -nc --arg ch "$channel" --arg txt "$body" '{channel:$ch, text:$txt, unfurl_links:false}')
  if curl -sS -X POST "https://slack.com/api/chat.postMessage" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$payload" >/dev/null 2>&1; then
    date +%s > "$marker"
    echo "[$(date -u +%FT%TZ)] notify_skip: posted skip notice to $channel" >&2
  else
    echo "[$(date -u +%FT%TZ)] notify_skip: curl failed (rc=$?)" >&2
  fi
  return 0
}

# --- 1. Resolve cmux socket via multi-app probe ---
# Don't trust /tmp/cmux-last-socket-path alone. Two failure modes
# (verified 2026-06-26):
#  (a) Pointer file is stale and points at a socket with 2 idle bash
#      workspaces (e.g. ~/.local/state/cmux/cmux.sock) while all the
#      agent work lives on the dev socket (/tmp/cmux-debug-may-18.sock).
#  (b) launchd-style env with no interactive shell context: `cmux tree`
#      ignores CMUX_SOCKET_PATH and uses its built-in stale default
#      (/tmp/cmux-debug-fix-agy-hook-deny.sock, which doesn't exist),
#      so tree returns empty even when a real socket is reachable.
# Recipe: probe every candidate socket, pick the one with the most
# workspaces (the dev session that holds agent work).
# Refs: cmux skill "Two cmux sessions can be live at the same time"
# (2026-06-24 bug-ref), "Sub-pattern: cmux CLI itself fails with
# Socket not found" (2026-06-24), and the multi-app probe reference
# at cmux/references/multi-app-socket-probe-recipe-2026-06-24.md.
resolve_best_cmux_socket() {
  local best_sock="" best_count=0
  local cand
  while IFS= read -r cand; do
    [ -S "$cand" ] || continue
    local count
    count=$(timeout 5 cmux --socket "$cand" list-workspaces 2>/dev/null \
      | grep -c '^  workspace:' || true)
    if [ "$count" -gt "$best_count" ]; then
      best_count=$count
      best_sock=$cand
    fi
  done < <(ls -1t /tmp/cmux*.sock /private/tmp/cmux*.sock \
              ~/.local/state/cmux/cmux.sock 2>/dev/null \
           | awk '!seen[$0]++')
  printf '%s\n' "$best_sock"
}
SOCK=$(resolve_best_cmux_socket)
# Fallback: pointer file (in case the multi-app probe sees nothing)
if [ -z "$SOCK" ] && [ -r /tmp/cmux-last-socket-path ]; then
  SOCK=$(cat /tmp/cmux-last-socket-path)
fi
# Final fallback: first ls hit
if [ -z "$SOCK" ]; then
  SOCK=$(ls -1 /tmp/cmux*.sock /private/tmp/cmux*.sock 2>/dev/null | head -1)
fi
if [ -z "$SOCK" ] || [ ! -S "$SOCK" ]; then
  echo "[$(date -u +%FT%TZ)] No live cmux socket — skipping this tick." >&2
  notify_skip "no live cmux socket — cmux daemon not running or no socket"
  exit 0
fi
export CMUX_SOCKET_PATH="$SOCK"

CHANNEL="${HERMES_CMUX_4H_CHANNEL:-C0AJQ5M0A0Y}"
LOG_DIR="$HOME/.smartclaw/logs/cmux-surface-report"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date -u +%Y-%m-%dT%H).log"

# Default GitHub owner/repo for PR hyperlinks. Per `.cursor/rules/pr-hyperlink.mdc`,
# all PR references in Slack output must be a markdown link to the full URL.
# The script auto-detects `jleechanorg/<repo>` from the screen text; this default
# is the fallback when the PR number appears without a repo nearby.
DEFAULT_GH_REPO="${CMUX_REPORT_GH_REPO:-jleechanorg/worldarchitect.ai}"

# Pinned workspaces: Jeffrey can pin by workspace ref (`workspace:14`) or by
# name fragment (e.g. `agento`, `latency`). One per line, `#` comments ok.
# File is optional — missing file means no pins.
PINNED_FILE="${CMUX_PINNED_FILE:-$HOME/.config/cmux/pinned-workspaces.txt}"
declare -a PINNED_REFS=()
declare -a PINNED_NAME_FRAGS=()
if [ -r "$PINNED_FILE" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"                # strip trailing comment
    line="$(echo "$line" | xargs)"     # trim whitespace
    [ -z "$line" ] && continue
    if [[ "$line" == workspace:* ]]; then
      PINNED_REFS+=("${line#workspace:}")
    else
      PINNED_NAME_FRAGS+=("$line")
    fi
  done < "$PINNED_FILE"
  if [ "${#PINNED_REFS[@]}" -gt 0 ]; then
    echo "Pinned refs: ${PINNED_REFS[*]}"
  fi
  if [ "${#PINNED_NAME_FRAGS[@]}" -gt 0 ]; then
    echo "Pinned name frags: ${PINNED_NAME_FRAGS[*]}"
  fi
  if [ "${#PINNED_REFS[@]}" -eq 0 ] && [ "${#PINNED_NAME_FRAGS[@]}" -eq 0 ]; then
    echo "Pinned file is empty (no pins set)"
  fi
fi

exec >> "$LOG_FILE" 2>&1
echo "=== cmux surface report tick $(date -u +%FT%TZ) ==="
echo "Socket: $SOCK"
echo "Target channel: $CHANNEL"

# --- 2. Inventory: use python to parse tree reliably ---
# Real case 2026-06-22 (dev build `cmux DEV may-18.app`):
#   - `cmux tree --all` hangs/returns empty even though the app is alive
#     (`cmux identify`, `cmux workspace list`, and `cmux tree` all return data).
#   - Verified workaround: `cmux tree` (current window only) and
#     `cmux tree --window window:1` both work. Only `--all` is wedged.
# Strategy: try the cheap path first (`tree --window window:1`), fall back to
# `tree --all` only if the windowed call returns nothing. Wrap each in
# `timeout` so a wedged RPC can't silently kill the tick.
SOCK_FOR_TREE="$SOCK"  # snapshot — subshell-safe

get_tree() {
  local label="$1"; shift
  # Use --socket flag (not CMUX_SOCKET_PATH env) — verified 2026-06-26:
  # in launchd-style env the CLI ignores CMUX_SOCKET_PATH and falls back
  # to its baked-in stale default (/tmp/cmux-debug-fix-agy-hook-deny.sock).
  # --socket is honored consistently. Also: --socket is a GLOBAL flag
  # (verified 2026-06-26 — putting it after `cmux tree` errors with
  # "tree: unknown flag --socket"). Must come right after `cmux`.
  # See cmux skill 2026-06-24 bug-ref.
  timeout 8 cmux --socket "$SOCK_FOR_TREE" "$@" 2>/dev/null || true
}

# Path 1: window-scoped tree (works on dev build)
TREE=$(get_tree "tree-window" tree --window window:1)
if [ -z "$TREE" ]; then
  echo "cmux tree --window window:1 returned empty; trying tree --all..."
  # Path 2: legacy --all flag (some prod builds need it)
  TREE=$(get_tree "tree-all" tree --all)
fi
if [ -z "$TREE" ]; then
  echo "cmux tree returned empty (both --window and --all) — RPC may be wedged. Skipping tick."
  notify_skip "cmux RPC wedged (tree --window AND --all both empty)"
  exit 0
fi

# Parse tree to get list of (workspace, surface) pairs where surface is selected.
# Python is required — awk breaks on Unicode box-drawing characters.
SURFACES=$(echo "$TREE" | python3 -c '
import sys, re
cur_workspace = None
pairs = []
for line in sys.stdin:
    ws = re.search(r"workspace workspace:(\d+)", line)
    if ws:
        cur_workspace = ws.group(1)
    surf = re.search(r"surface surface:(\d+)", line)
    if surf and cur_workspace:
        if "[selected]" in line:
            pairs.append((cur_workspace, surf.group(1)))
# Dedup, preserve order
seen = set()
out = []
for p in pairs:
    if p not in seen:
        seen.add(p)
        out.append(p)
print(len(out))
for w, s in out:
    print(f"{w} {s}")
' 2>/dev/null || true)

if [ -z "$SURFACES" ]; then
  echo "No selected surfaces found in tree."
  exit 0
fi

# First line is count
TOTAL=$(echo "$SURFACES" | head -1)
SURFACE_LIST=$(echo "$SURFACES" | tail -n +2)

# Sanity cap: any reasonable cmux tree has < 60 selected surfaces. If the parser
# ever double-counts (regression in 2026-06-20 08:29 tick posted 72 bogus
# "blocked" entries), refuse to post instead of alarming the channel.
if ! [[ "$TOTAL" =~ ^[0-9]+$ ]]; then
  echo "Parser returned non-numeric TOTAL='$TOTAL' — aborting to avoid bogus post."
  exit 1
fi
if [ "$TOTAL" -gt 100 ]; then
  echo "TOTAL=$TOTAL exceeds sanity cap (100) — aborting to avoid bogus post."
  exit 1
fi
echo "Selected surfaces: $TOTAL"

# --- 3. Per-surface classifier (rich context, prioritized output) ---
#
# For each selected surface we capture four fields:
#   WS_REF    → "w12" (workspace ref)
#   WS_NAME   → human label from `cmux tree` (best effort)
#   CLASS     → BLOCKED / RISKY / HEALTHY_ACTIVE / HEALTHY_IDLE
#   WORKING   → short description of the agent's current task (extracted)
#   STATUS    → one-line current state
#   NEXT      → recommended next action (Jeffrey or agent)
#
# Output ordering prioritizes:
#   1) The focused/selected workspace (cmux marks it with [selected]).
#   2) BLOCKED and RISKY surfaces (anything needing attention).
#   3) HEALTHY_ACTIVE surfaces (work in flight).
#   4) HEALTHY_IDLE surfaces (condensed to a single line each).
#
# Bounded output: a hard cap of 12 per-surface detail blocks; the rest get
# collapsed into a single line "• w3 (idle) …w18 (active)". Slack message
# is also capped at MAX_MSG_CHARS so we don't blow past the 4000-char safe
# limit per chat.postMessage call.

MAX_DETAIL=12
MAX_MSG_CHARS=3800

# Classification regex (kept conservative — false positives waste Slack space)
RX_FATAL='Traceback|panic:|FATAL EXCEPTION|segmentation fault|SIGSEGV|out of memory|killed \(SIGKILL\)'
RX_BLOCKED_PROMPT='/rate-limit-options|session limit|rate limit reached|Authentication failed|permission denied|403 Forbidden|EACCES'
RX_APPROVAL='confirm\?|Do you want to|approve\?|permission to|\[Y/n\]|\(y/N\)'
RX_ACTIVE='Running|processing|generating|building|claude--|Working on|thinking|Cooked for|Brewed for|Sprouting|composer 2 fast|Cogitated for|Compiling|Running tests|Running lint|sleeping \d|mypy|pytest|Rust check|cargo build'

# Per-surface records stored as parallel arrays (bash 3 compatible)
declare -a R_WS=()
declare -a R_NAME=()
declare -a R_CLASS=()
declare -a R_WORKING=()
declare -a R_STATUS=()
declare -a R_NEXT=()
declare -a R_PRIORITY=()   # numeric, lower = shown first
declare -a R_SELECTED=()   # "1" if this is the focused workspace
declare -a R_PINNED=()     # "1" if this workspace is in the pinned list

while IFS= read -r pair; do
  [ -z "$pair" ] && continue
  ws=$(echo "$pair" | awk '{print $1}')
  surf=$(echo "$pair" | awk '{print $2}')

  # Numeric guard: refuse malformed ids before calling cmux read-screen.
  # If the parser ever produces non-numeric ws/surf, the LABEL interpolation
  # below would silently embed garbage like "workspace/" or "│/" — which is
  # exactly what produced the 2026-06-20 08:29 false-positive.
  if ! [[ "$ws" =~ ^[0-9]+$ ]] || ! [[ "$surf" =~ ^[0-9]+$ ]]; then
    echo "SKIP malformed pair: '$pair' (ws='$ws' surf='$surf')"
    continue
  fi

  # Temporarily disable set -e around the per-surface body so a single
  # transient cmux hiccup (or a non-zero exit on grep -vE with no matches)
  # does not abort the entire loop. We re-enable at the bottom.
  set +e

  LABEL="w${ws}/s${surf}"

  # Read the focused surface. Filter cmux's own error lines (e.g. "Error:
  # Invalid workspace handle") before classifying — they would otherwise
  # look like real agent errors. Capture the screen raw for richer parsing
  # below (working-on extraction). `|| true` everywhere: under `set -e +
  # pipefail`, an empty grep match or a missing surface would otherwise
  # abort the loop after the first hiccup.
  RAW=$(cmux --socket "$SOCK" read-screen --workspace "workspace:${ws}" --surface "surface:${surf}" --lines 35 2>&1 || true)
  SCREEN=$(echo "$RAW" | { grep -vE '^\s*Error:' || true; } | tail -30 || true)
  [ -z "$SCREEN" ] && SCREEN="(empty surface)"

  # Workspace name + selected marker from `cmux identify` (authoritative).
  # Falls back to tree parsing if identify errors.
  IDENT_JSON=$(cmux --socket "$SOCK" identify --workspace "workspace:${ws}" 2>/dev/null || true)
  WS_NAME=""
  IS_SELECTED=0
  if [ -n "$IDENT_JSON" ]; then
    # cmux identify prints "  workspace:14  agento  [selected]" on text form,
    # OR JSON when called with --json. Handle both.
    if echo "$IDENT_JSON" | grep -q '"workspace_ref"'; then
      WS_NAME=$(echo "$IDENT_JSON" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
    focused = d.get("focused", {}) or {}
    caller  = d.get("caller",  {}) or {}
    ws_ref  = focused.get("workspace_ref") or caller.get("workspace_ref") or ""
    # cmux does not expose the workspace title in identify; fall back to ""
except Exception:
    pass
' 2>/dev/null || true)
    fi
  fi
  # Pull the workspace title from the tree. The tree layout is:
#   workspace workspace:14  agento  [selected]      ← title lives here (same line)
#   surface surface:58 ...                          ← followed by surfaces
#   workspace workspace:15  mobile - browser       ← next workspace starts
#
# Strategy: find the line containing `workspace workspace:N` and strip the
# prefix + `[selected]` marker. Falls back to "(no title)" if absent.
  if [ -z "$WS_NAME" ] && [ -n "$TREE" ]; then
    WS_NAME=$(echo "$TREE" | awk -v w="workspace:${ws}" '
      $0 ~ w {
        # The workspace title is on the SAME line, after the prefix.
        # Extract it by removing everything up to (and including) the
        # `workspace workspace:N` token, plus the [selected] marker.
        line = $0
        sub(/.*workspace workspace:[0-9]+[[:space:]]*/, "", line)
        sub(/[[:space:]]+\[selected\][[:space:]]*$/, "", line)
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        print line
        exit
      }
    ' | head -c 60)
  fi
  [ -z "$WS_NAME" ] && WS_NAME="(no title)"

  # Detect focused workspace (the one cmux has [selected]).
  # Only the workspace where the same node group has [selected] counts.
  # Use awk to scope the match to a single workspace block.
  if echo "$TREE" | awk -v w="workspace:${ws}" '
    $0 ~ w { in_block=1; if (/\[selected\]/) {found=1; exit} }
    in_block && /workspace workspace:/ { exit }
    in_block && /\[selected\]/ { found=1; exit }
    END { exit(found ? 0 : 1) }
  ' 2>/dev/null; then
    IS_SELECTED=1
  fi

  # Pinned workspace: explicit pin (by ref or by name fragment) trumps
  # [selected]. A pinned surface always floats to the top of the report.
  IS_PINNED=0
  if [ "${#PINNED_REFS[@]}" -gt 0 ]; then
    for pref in "${PINNED_REFS[@]}"; do
      if [ "$ws" = "$pref" ]; then IS_PINNED=1; break; fi
    done
  fi
  if [ "$IS_PINNED" = "0" ] && [ "${#PINNED_NAME_FRAGS[@]}" -gt 0 ]; then
    lc_name=$(echo "$WS_NAME" | tr '[:upper:]' '[:lower:]')
    for frag in "${PINNED_NAME_FRAGS[@]}"; do
      lc_frag=$(echo "$frag" | tr '[:upper:]' '[:lower:]')
      if [[ "$lc_name" == *"$lc_frag"* ]]; then IS_PINNED=1; break; fi
    done
  fi

  # --- Classify ---
  CLASS="HEALTHY_IDLE"
  if echo "$SCREEN" | grep -qiE "$RX_FATAL"; then
    CLASS="BLOCKED"
  elif echo "$SCREEN" | grep -qiE "$RX_BLOCKED_PROMPT"; then
    CLASS="BLOCKED"
  elif echo "$SCREEN" | grep -qiE "$RX_APPROVAL"; then
    CLASS="RISKY"
  elif echo "$SCREEN" | grep -qiE "$RX_ACTIVE"; then
    CLASS="HEALTHY_ACTIVE"
  fi

  # --- Extract "working on" (best-effort, capped at ~100 chars) ---
  #
  # Smarter extraction (2026-06-24): prefer lines that mention a PR number
  # or a `jleechanorg/<repo>` path (most informative). Fall back to
  # activity indicators ("Running", "✻ Cooked for 7m"). Prefer
  # LATER log lines (the bottom 8 lines of a 30-line screen usually
  # have the freshest activity) over header/prompt lines.
  #
  # We do this with one python call: takes the SCREEN blob, ranks
  # candidate lines by (PR-mentioned? 3 : 0) + (activity-keyword? 2 : 0) +
  # (lower in screen = 1), then returns the best line truncated at 100
  # chars on a word boundary.
  WORKING=$(echo "$SCREEN" | python3 -c '
import sys, re

text = sys.stdin.read()
lines = [l for l in text.splitlines() if l.strip()]
if not lines:
    print("")
    sys.exit(0)

PR_RX   = re.compile(r"#\d+|jleechanorg/[A-Za-z0-9_.\-]+")
ACT_RX  = re.compile(r"(?i)\b(running|generating|building|processing|compiling|"
                     r"cooked|brewed|sprouting|cogitated|composer|cargo|pytest|"
                     r"mypy|working on|sleeping|claude--)\b")

best, best_score = "", -1
n = len(lines)
for i, line in enumerate(lines):
    s = line.strip()
    if not s or s.startswith(">"):
        continue
    score = 0
    if PR_RX.search(s):   score += 3   # PR/branch mention — most informative
    if ACT_RX.search(s):  score += 2   # active work indicator
    score += i / max(n, 1)             # later in screen = fresher
    if score > best_score:
        best, best_score = s, score

if not best:
    print("")
    sys.exit(0)

# Truncate at 100 chars on a word boundary.
if len(best) > 100:
    cut = best[:100].rsplit(" ", 1)[0]
    if len(cut) < 60:        # fallback if word boundary would chop too much
        cut = best[:97] + "…"
    else:
        cut = cut + "…"
    best = cut
print(best)
' 2>/dev/null || true)
  case "$CLASS" in
    BLOCKED)  [ -z "$WORKING" ] && WORKING="fatal/blocked prompt visible";;
    RISKY)    [ -z "$WORKING" ] && WORKING="awaiting user approval/permission";;
    HEALTHY_ACTIVE) [ -z "$WORKING" ] && WORKING="active agent work (no specific label)";;
    *)        WORKING="idle — bash prompt or quiet terminal";;
  esac

  # --- Status (one line, free-form) ---
  STATUS=""
  case "$CLASS" in
    BLOCKED)   STATUS="🔴 blocked — needs recovery";;
    RISKY)     STATUS="🟡 risky — waiting for Jeffrey";;
    HEALTHY_ACTIVE) STATUS="🟢 healthy — active work";;
    *)         STATUS="⚪ healthy — idle";;
  esac

  # --- Next steps (rule-based, deterministic) ---
  #
  # PR/branch identifiers in the "next:" line are emitted as full markdown
  # hyperlinks per `.cursor/rules/pr-hyperlink.mdc` (no bare #N). The repo
  # is auto-detected from the screen text — if the screen mentions
  # `jleechanorg/<repo>`, that's the hyperlink target. Otherwise, fall
  # back to $DEFAULT_GH_REPO.
  #
  # Helper: extract the best PR + repo pair from the screen.
  extract_pr() {
    python3 -c '
import sys, re, os
screen = sys.stdin.read()
default_repo = os.environ.get("DEFAULT_GH_REPO", "jleechanorg/worldarchitect.ai")

def normalize(repo):
    """If repo already contains a /, treat it as full owner/repo;
    otherwise prepend the canonical owner. Strips a doubled-owner
    like `jleechanorg/jleechanorg/<repo>` to `jleechanorg/<repo>`."""
    if "/" in repo:
        owner, _, rest = repo.partition("/")
        if owner == "jleechanorg" and rest.startswith("jleechanorg/"):
            return rest
        return repo
    return "jleechanorg/" + repo

# If the screen contains a full github.com pull URL with the canonical
# owner, parse it directly. We walk ALL matches (not just the first) and
# pick the one whose repo segment is NOT "jleechanorg" — this handles
# the doubled-owner case where Slack/chat surfaces print BOTH the
# rendered hyperlink text and the raw URL.
candidates = list(re.finditer(
    r"github\.com/jleechanorg/([A-Za-z0-9_.\-]+)/pull/(\d+)\b",
    screen,
))
# Use the LAST candidate — agent screens typically list activity bottom-up,
# and the freshest PR mention is the most informative for a "next:" line.
valid = [m for m in candidates if m.group(1) != "jleechanorg"]
if valid:
    m = valid[-1]
    repo, n = m.group(1), m.group(2)
    print(f"[#{n}](https://github.com/jleechanorg/{repo}/pull/{n})")
    sys.exit(0)

# Otherwise, look for `jleechanorg/<repo>` (text-only mention) near a
# PR number. Use a word boundary so we do not match a URL fragment.
# Reject the doubled-owner pattern explicitly.
m_repo = re.search(r"\bjleechanorg/(?!jleechanorg/)([A-Za-z0-9_.\-]+)\b", screen)
# No jleechanorg anchor anywhere — refuse to guess a link (the screen
# is probably referencing an unrelated repo PR).
if not m_repo and "jleechanorg" not in screen:
    print("")
    sys.exit(0)
repo = m_repo.group(1) if m_repo else default_repo
# Find the FIRST PR number. Prefer "PR #N" / "#N" / "pull/N".
# Allow 1+ digits (cmux-style small PRs exist).
m_pr = re.search(r"(?:PR\s*#|#)(\d+)\b", screen)
if not m_pr:
    m_pr = re.search(r"/pull/(\d+)\b", screen)
if not m_pr:
    print("")
    sys.exit(0)
n = m_pr.group(1)
print(f"[#{n}](https://github.com/{normalize(repo)}/pull/{n})")
' 2>/dev/null || true
  }
  export DEFAULT_GH_REPO
  NEXT=""
  case "$CLASS" in
    BLOCKED)
      if echo "$SCREEN" | grep -qi 'session limit\|rate limit reached'; then
        NEXT="pick /rate-limit-options or wait for reset"
      elif echo "$SCREEN" | grep -qi 'Authentication failed\|403 Forbidden\|permission denied'; then
        NEXT="re-auth / rotate token, then restart agent"
      elif echo "$SCREEN" | grep -qi 'Traceback'; then
        NEXT="read traceback, file issue or push fix"
      else
        NEXT="inspect traceback + decide"
      fi
      ;;
    RISKY)
      NEXT="answer prompt or steer the agent"
      ;;
    HEALTHY_ACTIVE)
      PR_LINK=$(echo "$SCREEN" | extract_pr)
      if [ -n "$PR_LINK" ]; then
        NEXT="monitor; auto-merge when 7-green ($PR_LINK)"
      else
        NEXT="monitor; let agent finish"
      fi
      ;;
    *)
      NEXT="leave as-is or steer with new task"
      ;;
  esac

  # --- Priority (lower = shown first) ---
  PRI=99
  case "$CLASS" in
    BLOCKED)        PRI=10;;
    RISKY)          PRI=20;;
    HEALTHY_ACTIVE) PRI=40;;
    *)              PRI=80;;
  esac
  # Focused workspace: bump above its class baseline.
  if [ "$IS_SELECTED" = "1" ]; then
    PRI=$((PRI - 5))
  fi
  # Pinned workspace: highest priority of all (floats to top regardless
  # of class). Pinned idle surfaces still appear before unpinned active ones.
  if [ "$IS_PINNED" = "1" ]; then
    PRI=1
  fi

  R_WS+=("$LABEL")
  R_NAME+=("$WS_NAME")
  R_CLASS+=("$CLASS")
  R_WORKING+=("$WORKING")
  R_STATUS+=("$STATUS")
  R_NEXT+=("$NEXT")
  R_PRIORITY+=("$PRI")
  R_SELECTED+=("$IS_SELECTED")
  R_PINNED+=("$IS_PINNED")
  echo "$CLASS $LABEL pri=$PRI selected=$IS_SELECTED pinned=$IS_PINNED"

  # Re-enable set -e for the rest of the script.
  set -e
done <<< "$SURFACE_LIST"

# --- 4. Aggregate counts + bucket-sum cross-check ---
BLOCKED=()
RISKY=()
HEALTHY=()
for i in "${!R_WS[@]}"; do
  case "${R_CLASS[$i]}" in
    BLOCKED)        BLOCKED+=("${R_WS[$i]}");;
    RISKY)          RISKY+=("${R_WS[$i]}");;
    *)              HEALTHY+=("${R_WS[$i]}");;
  esac
done
HEALTHY_COUNT=${#HEALTHY[@]}
RISKY_COUNT=${#RISKY[@]}
BLOCKED_COUNT=${#BLOCKED[@]}

# Bucket-sum cross-check: healthy+risky+blocked must equal TOTAL (every
# surface must land in exactly one bucket). If they don't, the parser
# dropped some surfaces silently — log but continue posting.
SUM=$((HEALTHY_COUNT + RISKY_COUNT + BLOCKED_COUNT))
if [ "$SUM" -ne "$TOTAL" ]; then
  echo "Bucket sum mismatch: healthy=$HEALTHY_COUNT risky=$RISKY_COUNT blocked=$BLOCKED_COUNT sum=$SUM total=$TOTAL"
fi

EMOJI=":white_check_mark:"
LABEL="healthy"
if [ "$BLOCKED_COUNT" -gt 0 ]; then
  EMOJI=":rotating_light:"; LABEL="blocked"
elif [ "$RISKY_COUNT" -gt 0 ]; then
  EMOJI=":warning:"; LABEL="risky"
fi

# --- 5. Sort surfaces by priority for output ---
# Build a sorted index list. bash 3 has no `declare -A` ordering; we
# sort with an external python helper to keep the bash portable.
# Re-export the parallel arrays to the python helper via env, then sort.
export __PRI=$(
  for v in "${R_PRIORITY[@]}"; do echo -n "$v"; echo -ne '\x1f'; done
)
export __SEL=$(
  for v in "${R_SELECTED[@]}"; do echo -n "$v"; echo -ne '\x1f'; done
)
export __PIN=$(
  for v in "${R_PINNED[@]}"; do echo -n "$v"; echo -ne '\x1f'; done
)
export __WS=$(
  for v in "${R_WS[@]}"; do echo -n "$v"; echo -ne '\x1f'; done
)
SORTED_IDX=$(python3 - "$TOTAL" <<'PY'
import sys, os
total = int(sys.argv[1])
indices = list(range(total))
pri  = os.environ["__PRI"].split("\x1f")
sel  = os.environ["__SEL"].split("\x1f")
pin  = os.environ["__PIN"].split("\x1f")
ws   = os.environ["__WS"].split("\x1f")
# Sort: priority asc, then pinned desc, then selected desc, then workspace ref asc.
indices.sort(key=lambda i: (
    int(pri[i]) if i < len(pri) and pri[i].isdigit() else 999,
    0 if (i < len(pin) and pin[i] == "1") else 1,
    0 if (i < len(sel) and sel[i] == "1") else 1,
    ws[i] if i < len(ws) else "",
))
print("\n".join(str(i) for i in indices))
PY
)

# --- 6. Build the Slack message ---
HEADER="*cmux Surface Report (4h)* ${EMOJI} ${LABEL}
Workspaces: ${TOTAL} surfaces checked | 🟢 ${HEALTHY_COUNT} healthy | 🟡 ${RISKY_COUNT} risky | 🔴 ${BLOCKED_COUNT} blocked
_Tick: $(date -u +%FT%TZ) | Socket: ${SOCK##*/}_"

# Section A — per-surface detail blocks (prioritized, capped at MAX_DETAIL).
DETAIL=""
COUNT_DETAIL=0
while IFS= read -r idx; do
  [ -z "$idx" ] && continue
  [ "$COUNT_DETAIL" -ge "$MAX_DETAIL" ] && break
  CLS="${R_CLASS[$idx]}"
  NAME="${R_NAME[$idx]}"
  REF="${R_WS[$idx]}"
  WORK="${R_WORKING[$idx]}"
  STAT="${R_STATUS[$idx]}"
  NXT="${R_NEXT[$idx]}"
  # Pinned takes precedence over selected; both can co-exist (📌 + 📍).
  PIN=""
  [ "${R_PINNED[$idx]}" = "1" ]   && PIN="📌"
  [ "${R_SELECTED[$idx]}" = "1" ] && PIN="${PIN:+$PIN }📍"
  [ -n "$PIN" ] && PIN="$PIN "
  DETAIL="${DETAIL}"$'\n\n'"${PIN}*${REF} ${NAME}* — ${STAT}
• working on: ${WORK}
• next: ${NXT}"
  COUNT_DETAIL=$((COUNT_DETAIL + 1))
done <<< "$SORTED_IDX"

# Section B — condensed list of the rest.
REST=""
while IFS= read -r idx; do
  [ -z "$idx" ] && continue
  CLS="${R_CLASS[$idx]}"
  NAME="${R_NAME[$idx]}"
  REF="${R_WS[$idx]}"
  case "$CLS" in
    BLOCKED)        GLYPH="🔴";;
    RISKY)          GLYPH="🟡";;
    HEALTHY_ACTIVE) GLYPH="🟢";;
    *)              GLYPH="⚪";;
  esac
  PIN=""
  [ "${R_PINNED[$idx]}" = "1" ]   && PIN="📌"
  [ "${R_SELECTED[$idx]}" = "1" ] && PIN="${PIN:+$PIN }📍"
  if [ -z "$REST" ]; then
    REST="${GLYPH}${PIN}${PIN:+ }${REF} ${NAME}"
  else
    REST="${REST} | ${GLYPH}${PIN}${PIN:+ }${REF} ${NAME}"
  fi
done <<< "$SORTED_IDX"

REST_LINE=""
if [ -n "$REST" ]; then
  REST_LINE=$'\n\n'"_All surfaces:_ ${REST}"
fi

MSG="${HEADER}${DETAIL}${REST_LINE}"

# Hard cap: trim if we exceed Slack's safe per-message limit. Slack accepts
# up to ~40k chars but rendering degrades past ~4k; we cap at 3800.
if [ "${#MSG}" -gt "$MAX_MSG_CHARS" ]; then
  echo "MSG length ${#MSG} > $MAX_MSG_CHARS — trimming detail blocks."
  DETAIL=""
  COUNT_DETAIL=0
  while IFS= read -r idx; do
    [ -z "$idx" ] && continue
    [ "$COUNT_DETAIL" -ge 6 ] && break
    CLS="${R_CLASS[$idx]}"
    NAME="${R_NAME[$idx]}"
    REF="${R_WS[$idx]}"
    STAT="${R_STATUS[$idx]}"
    NXT="${R_NEXT[$idx]}"
    PIN=""
    [ "${R_PINNED[$idx]}" = "1" ]   && PIN="📌"
    [ "${R_SELECTED[$idx]}" = "1" ] && PIN="${PIN:+$PIN }📍"
    [ -n "$PIN" ] && PIN="$PIN "
    DETAIL="${DETAIL}"$'\n\n'"${PIN}*${REF} ${NAME}* — ${STAT} → ${NXT}"
    COUNT_DETAIL=$((COUNT_DETAIL + 1))
  done <<< "$SORTED_IDX"
  MSG="${HEADER}${DETAIL}"$'\n\n'"_(trimmed; full list in log ${LOG_FILE##*/})_"
fi

# --- 7. Post to Slack ---
TOKEN="${SLACK_BOT_TOKEN:-${HERMES_SLACK_USER_TOKEN:-}}"
if [ -z "$TOKEN" ]; then
  echo "No Slack token available — skipping post."
  echo "MSG was: $MSG"
  exit 0
fi

PAYLOAD=$(jq -nc --arg ch "$CHANNEL" --arg txt "$MSG" '{channel:$ch, text:$txt, unfurl_links:false}')
RESP=$(curl -sS -X POST "https://slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>&1 || true)
echo "Slack response (truncated): ${RESP:0:200}"
