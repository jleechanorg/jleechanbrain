#!/usr/bin/env bash
# lib-slack-post.sh
#
# Shared helper for posting Slack messages from scripts.
#
# Exports:
#   slack_post_message <channel_id> <text> [thread_ts]
#     Post a message via chat.postMessage. If thread_ts is set, posts as a
#     reply in that thread. Returns 0 on success, non-zero on failure.
#
#   slack_post_daily_anchor <anchor_channel> <report_url> <report_date_time> \
#     <llm_judgment_md> <threads_csv>
#     Post a single top-level ":clipboard: Slack thread roadmap — {date}"
#     digest to ONE channel (the canonical daily anchor target). Default
#     if env DAILY_ANCHOR_CHANNEL is unset and <anchor_channel> is empty:
#     C0AJQ5M0A0Y (=#ai-general). This is the ONLY place a top-level
#     daily digest is posted; per-channel summaries are threaded under
#     the originating thread (slack_post_per_thread_summary) so #worldai,
#     #all-jleechan-ai, etc. do not get channel-root noise.
#
#   slack_post_per_thread_summary <channels_csv> <report_url> <report_date_time> \
#     <llm_judgment_md> <threads_csv>
#     Post a per-thread summary as a REPLY (thread_ts) under each
#     actionable thread. <threads_csv> is a newline-delimited list of
#     "chan|ts|url|kind" tuples. The function parses the LLM judgment
#     markdown to extract the per-thread section for each thread and
#     posts it as a reply in the originating thread, so the user sees
#     the summary inline with the thread they were already reading.
#     Threads younger than DAILY_ANCHOR_GRACE_MIN (default 60, matching
#     the 5b-leak-detector grace window) are skipped here because the
#     daily anchor covers them.
#
# Token resolution (launchd does not source ~/.bashrc):
#   1. SLACK_BOT_TOKEN (already exported)
#   2. Source ~/.bashrc inside a subshell
#   3. Bail to stderr so caller can fall back
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"
OUTBOUND_SECRET_GATE="${OUTBOUND_SECRET_GATE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/outbound_secret_gate.py}"

slack__resolve_token() {
  local tok="${SLACK_BOT_TOKEN:-}"
  if [[ -z "$tok" ]]; then
    tok="$(bash -c 'source ~/.bashrc 2>/dev/null; echo -n "${SLACK_BOT_TOKEN:-}"' 2>/dev/null || true)"
  fi
  if [[ -z "$tok" ]]; then
    echo "slack__resolve_token: SLACK_BOT_TOKEN not set" >&2
    return 1
  fi
  printf '%s' "$tok"
}

slack_post_message() {
  local channel="$1" text="$2" thread_ts="${3:-}"
  if ! printf '%s' "$text" | python3 "$OUTBOUND_SECRET_GATE" check; then
    echo "slack_post_message: BLOCKED — outbound body contains a secret-like value; redact it before retrying" >&2
    return 3
  fi
  local tok
  tok="$(slack__resolve_token)" || return 1

  # unfurl_links=false + unfurl_media=false suppress Slack's automatic link
  # previews (the inline cards that pop up under messages containing URLs).
  # Without this, the slack-thread-roadmap daily anchor — which contains 8-30
  # thread permalinks — produced a wall of preview cards that buried the
  # actual text Jeffrey wanted to scan (see 2026-06-23 thread complaint).
  # The trade-off: links still render as plain text hyperlinks but Slack
  # no longer fetches og:title/og:image and renders a preview card.
  local payload
  if [[ -n "$thread_ts" ]]; then
    payload=$(CH="$channel" TXT="$text" TH="$thread_ts" python3 -c '
import json, os
print(json.dumps({
  "channel": os.environ["CH"],
  "text": os.environ["TXT"],
  "thread_ts": os.environ["TH"],
  "unfurl_links": False,
  "unfurl_media": False,
}))
')
  else
    payload=$(CH="$channel" TXT="$text" python3 -c '
import json, os
print(json.dumps({
  "channel": os.environ["CH"],
  "text": os.environ["TXT"],
  "unfurl_links": False,
  "unfurl_media": False,
}))
')
  fi

  local response
  set +e
  # Bound the call so a Slack/network stall cannot block the reporting run
  # indefinitely. --connect-timeout caps TCP handshake; --max-time caps the
  # entire operation (DNS + connect + TLS + send + receive).
  response=$(curl -sS --connect-timeout 10 --max-time 30 \
    -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $tok" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$payload" 2>&1)
  local curl_rc=$?
  set -e
  if [[ $curl_rc -ne 0 ]]; then
    echo "slack_post_message: curl failed rc=$curl_rc" >&2
    return 1
  fi

  local is_ok
  is_ok=$(echo "$response" | python3 -c '
import sys, json
try:
    res = json.loads(sys.stdin.read())
    if res.get("ok"):
        print("true")
    else:
        print("false: " + str(res.get("error", "unknown")))
except Exception as e:
    print("false: parse_error " + str(e))
')

  if [[ "$is_ok" != "true" ]]; then
    echo "slack_post_message failed: $is_ok. Response: $response" >&2
    return 1
  fi

  # Echo the ts of the posted message so callers (slack_post_daily_anchor,
  # thread-reply helpers) can register it as a thread anchor for idempotency.
  # Without this, the daily anchor cron fires 5x per UTC day (every 4h) and
  # each post gets flagged as sub-class 5c by the 5b-leak detector because no
  # caller is writing var/slack/<job>/daily-thread.ts between runs.
  echo "$response" | python3 -c '
import sys, json
try:
    res = json.loads(sys.stdin.read())
    ts = res.get("ts", "")
    if ts:
        print(ts)
except Exception:
    pass
'
}

# Parse the LLM judgment markdown into per-thread sections. Each section
# starts with "### " and continues until the next "### " or end of input.
# Returns: newline-separated "title|body" pairs.
slack__parse_judgment_sections() {
  local judgment_md="$1"
  python3 - "$judgment_md" <<'PY'
import re, sys
md = sys.argv[1]
# Match each "### <title>\n<body>" block
sections = re.split(r'(?m)^### ', md)
out = []
for sec in sections[1:]:
  if not sec.strip():
    continue
  # First line is the title, rest is the body
  parts = sec.split('\n', 1)
  title = parts[0].strip()
  body = parts[1].strip() if len(parts) > 1 else ''
  out.append(f"{title}|{body}")
print('\n'.join(out))
PY
}

# Build the per-channel summary message. Args:
#   $1 = report_url
#   $2 = report_date_time (e.g. "2026-06-20 1809")
#   $3 = judgment_md
#   $4 = threads_csv (chan|ts|url|kind lines)
#   $5 = channel_id (the channel we're posting TO)
# Echoes the message text on stdout.
slack__build_channel_message() {
  local report_url="$1" report_dt="$2" judgment_md="$3" threads_csv="$4" target_channel="$5"
  THREADS="$threads_csv" TARGET="$target_channel" REPORT_URL="$report_url" REPORT_DT="$report_dt" \
    JUDGMENT="$judgment_md" python3 <<'PY'
import os, re, sys

threads_raw = os.environ["THREADS"]
target = os.environ["TARGET"]
report_url = os.environ["REPORT_URL"]
report_dt = os.environ["REPORT_DT"]
judgment = os.environ["JUDGMENT"]

# Parse thread list for this channel
channel_threads = []
for line in threads_raw.splitlines():
  if not line.strip():
    continue
  parts = line.split("|", 3)
  if len(parts) < 4:
    continue
  ch, ts, url, kind = parts[0], parts[1], parts[2], parts[3]
  if ch == target:
    channel_threads.append((ts, url, kind))

if not channel_threads:
  sys.exit(0)

# Parse judgment into sections: title -> body
sections = {}
current_title = None
current_body = []
for line in re.split(r'(?m)^### ', judgment):
  if not line.strip():
    continue
  if current_title is not None and current_body:
    sections[current_title] = "\n".join(current_body).strip()
  parts = line.split('\n', 1)
  current_title = parts[0].strip()
  current_body = [parts[1]] if len(parts) > 1 else []
if current_title is not None and current_body:
  sections[current_title] = "\n".join(current_body).strip()

# Match each thread to a section by the thread URL (section body contains the URL)
lines = []
# Per-channel header: include the source channel id and thread count so each
# Slack message is self-describing when delivered alongside others in the
# same anchor channel (post-2026-06-23 refactor: one message per source
# channel, all delivered to C0AJQ5M0A0Y). Channel id is preferred over
# channel name because the name requires an extra users_search / channels_list
# API call we don't have a cached mapping for in this lib.
lines.append(f":clipboard: *Slack thread roadmap — {report_dt}*  •  source <#{target}|{target}>  •  {len(channel_threads)} thread{'s' if len(channel_threads) != 1 else ''}")
lines.append(f"Full report: {report_url}")
lines.append("")
for ts, url, kind in channel_threads:
  # Find the section whose body mentions this URL
  matched_body = None
  matched_title = None
  for title, body in sections.items():
    if url in body:
      matched_body = body
      matched_title = title
      break
  if matched_body is None:
    # Try fuzzy match on thread_ts
    ts_no_dot = ts.replace(".", "")
    for title, body in sections.items():
      if ts_no_dot in body.replace(".", ""):
        matched_body = body
        matched_title = title
        break
  if matched_body is None:
    matched_body = "(no LLM judgment available for this thread)"
    matched_title = "thread"
  # Truncate body for Slack: keep up to 8 lines but stop at the section
  # end (blank line + next "### " or "Executive summary" marker) so we
  # don't bleed the next thread's content into this one.
  body_lines = matched_body.split("\n")
  short_body_lines = []
  for bl in body_lines[:20]:
    stripped = bl.strip()
    if not stripped and short_body_lines:
      # blank line after content — stop here
      break
    if stripped.lower().startswith("**executive summary"):
      break
    if stripped.startswith("### "):
      break
    short_body_lines.append(bl)
    if len(short_body_lines) >= 8:
      break
  short_body = "\n".join(short_body_lines)
  # Per-entry char cap: a single LLM judgment line can be unwrapped and
  # arbitrarily long. Without this, one bad entry can exceed
  # SLACK_ANCHOR_CHUNK_MAX (3500) and the chunker (slack__chunk_anchor_message)
  # would emit it as a single oversized chunk — the gateway mirror then
  # splits the post and URL-mangles inline links back to "___URL_PLACEHOLDER___"
  # (the misroute class PR #665/#667 are trying to prevent). 1500 leaves
  # room for the header + 1-2 more entries in the same chunk.
  short_body = short_body[:1500]
  lines.append(f"• <{url}|{matched_title}>")
  # Indent body
  for bl in short_body.split("\n"):
    if bl.strip():
      lines.append(f"  > {bl.strip()}")
  lines.append("")

print("\n".join(lines).rstrip())
PY
}

# Split the daily-anchor message into N ≤SLACK_ANCHOR_CHUNK_MAX-char chunks
# at thread-entry boundaries. A "thread entry" starts with a line that
# matches https://* (Slack thread permalink) and continues through the
# indented judgment body that follows, ending at the next blank line OR
# the next URL-prefixed line. The header (":clipboard: Slack thread
# roadmap — {date}" + "Full report: ..." + blank line) is preserved on
# the FIRST chunk only; subsequent chunks just continue listing entries.
#
# Why: when the anchor post exceeds ~3500 chars, the gateway's
# send_message mirror splits the message and replaces ~5-10% of inline
# Slack thread URLs with "___URL_PLACEHOLDER___" (see
# skills/devops/slack-messaging/SKILL.md line 19, 344; live observed in
# the 2026-06-22 10:45 anchor post ts 1782150308.549379). Chunking keeps
# each post under the threshold so URLs survive intact.
#
# Args:
#   $1 = full anchor message
#   $SLACK_ANCHOR_CHUNK_MAX = optional override (default 3500)
#
# Echoes NUL-separated chunks on stdout. Empty input → no output.
# Callers MUST consume the output via process substitution + mapfile -d ''
# (e.g. `mapfile -t -d '' chunks < <(slack__chunk_anchor_message "$msg")`)
# because plain `$(...)` strips trailing NUL bytes.
slack__chunk_anchor_message() {
  local msg="${1-}"
  local max_chars="${SLACK_ANCHOR_CHUNK_MAX:-3500}"

  if [[ -z "$msg" ]]; then
    return 0
  fi

  # Header = first paragraph (everything before the first URL-prefixed line).
  # The build function emits:
  #   line 1: ":clipboard: *Slack thread roadmap — {dt}*"
  #   line 2: "Full report: {url}"
  #   line 3: "" (blank)
  #   then per-thread entries that all start with "• <https://..."
  local header=""
  local body="$msg"
  # Find the first line containing "https://" — everything before it
  # (inclusive of the blank separator) is the header. Disable -e briefly
  # so a grep with no matches does not abort the function under
  # set -euo pipefail.
  local first_url_line
  set +e
  first_url_line=$(grep -n 'https://' <<<"$msg" | head -n 1 | cut -d: -f1)
  set -e
  if [[ -n "${first_url_line:-}" ]]; then
    header=$(head -n "$((first_url_line - 1))" <<<"$msg")
    body=$(tail -n +"$first_url_line" <<<"$msg")
  fi

  # Parse entries from `body` (post-header content). Each entry is a
  # contiguous block of non-blank lines followed by a blank-line separator.
  # The slack anchor build format emits:
  #   "<URL-line>\n<judgment-line>\n\n" per entry (3 lines including blank).
  # Parsing by ENTRY (not by line) guarantees we never split an entry's
  # URL line from its judgment body — the root cause of the earlier
  # mid-entry split bug.
  local -a entries=()
  local cur=""
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" ]]; then
      if [[ -n "$cur" ]]; then
        entries+=("$cur")
        cur=""
      fi
    else
      if [[ -z "$cur" ]]; then
        cur="$line"
      else
        cur+=$'\n'"$line"
      fi
    fi
  done <<<"$body"
  if [[ -n "$cur" ]]; then
    entries+=("$cur")
  fi

  # Header overhead for chunk 0 (header + the "\n" between header and body).
  local header_overhead=0
  if [[ -n "$header" ]]; then
    header_overhead=$(( ${#header} + 1 ))
  fi

  # Greedy pack entries into chunks. Entries are NEVER split; if adding
  # the next entry would exceed max_chars, close the current chunk and
  # start a new one. The chunk size budget is `max_chars - chunk_overhead`
  # where chunk_overhead is the header overhead on chunk 0 and 0 elsewhere.
  local -a chunks=()
  local current=""
  local current_size=0
  local chunk_overhead=$header_overhead
  local entry
  for entry in "${entries[@]}"; do
    local entry_size=${#entry}
    local projected=0
    if [[ -z "$current" ]]; then
      projected=$(( chunk_overhead + entry_size ))
    else
      projected=$(( chunk_overhead + current_size + 1 + entry_size ))
    fi

    if [[ -z "$current" ]]; then
      if [[ $entry_size -gt $(( max_chars - chunk_overhead )) ]]; then
        local allowed=$(( max_chars - chunk_overhead ))
        echo "slack__chunk_anchor_message: warning: entry too large (${entry_size} chars), truncating to ${allowed} chars" >&2
        entry="${entry:0:allowed}"
        entry_size=$allowed
      fi
      current="$entry"
      current_size=$entry_size
    elif [[ $projected -le $max_chars ]]; then
      current+=$'\n'"$entry"
      current_size=$(( current_size + 1 + entry_size ))
    else
      # Emit current; start new chunk with this entry (no header overhead).
      chunks+=("$current")
      chunk_overhead=0
      if [[ $entry_size -gt $max_chars ]]; then
        echo "slack__chunk_anchor_message: warning: entry too large (${entry_size} chars), truncating to ${max_chars} chars" >&2
        entry="${entry:0:max_chars}"
        entry_size=$max_chars
      fi
      current="$entry"
      current_size=$entry_size
    fi
  done

  if [[ -n "$current" ]]; then
    chunks+=("$current")
  fi

  # Emit each chunk NUL-terminated. First chunk gets the header prepended;
  # subsequent chunks stand on their own. Callers should consume via
  # `mapfile -t -d '' chunks < <(slack__chunk_anchor_message "$msg")`.
  local i=0
  for c in "${chunks[@]}"; do
    if [[ $i -eq 0 && -n "$header" ]]; then
      printf '%s\n%s\0' "$header" "$c"
    else
      printf '%s\0' "$c"
    fi
    i=$((i+1))
  done
}

# Post the daily anchor (single channel-root digest) to ONE channel. The
# anchor is the single top-level ":clipboard: Slack thread roadmap — {date}"
# post that lists every actionable thread. We default to C0AJQ5M0A0Y
# (=#ai-general) but respect DAILY_ANCHOR_CHANNEL if set. Returns 0 on
# success, 1 on any failure. Empty threads_csv → no-op success.
slack_post_daily_anchor() {
  local anchor_channel="${1:-${DAILY_ANCHOR_CHANNEL:-C0AJQ5M0A0Y}}"
  local report_url="$2" report_dt="$3" judgment_md="$4" threads_csv="$5"
  # Job name used for var/slack/<job>/daily-thread.ts anchor tracking. Defaults
  # to slack-thread-roadmap-report because that's the only current caller.
  # Cron callers can override via DAILY_ANCHOR_JOB_NAME.
  local job_name="${DAILY_ANCHOR_JOB_NAME:-slack-thread-roadmap-report}"

  if [[ -z "$anchor_channel" ]]; then
    echo "slack_post_daily_anchor: no anchor channel resolved" >&2
    return 1
  fi
  if [[ -z "$threads_csv" ]]; then
    echo "slack_post_daily_anchor: no threads to anchor" >&2
    return 0
  fi

  # Idempotency: source slack_thread_lib.sh so we can check whether a daily
  # anchor was already posted in this UTC day for $job_name. The cron
  # launchd schedule is 5x/day (every 4h). Without this check, each firing
  # would re-post the same digest to the anchor channel, which the 5b-leak
  # detector flags as sub-class 5c recurring (3 trips in one UTC day as of
  # 2026-06-22). The check is best-effort: if the lib cannot be sourced
  # (test env, missing HERMES_HOME), fall through to posting.
  local existing_ts=""
  local anchor_lib=""
  for candidate in \
    "${HERMES_HOME:-}/lib/slack_thread_lib.sh" \
    "$HOME/.smartclaw/lib/slack_thread_lib.sh" \
    "$HOME/.smartclaw/lib/slack_thread_lib.sh"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      anchor_lib="$candidate"
      break
    fi
  done
  if [[ -n "$anchor_lib" ]]; then
    # shellcheck source=lib/slack_thread_lib.sh
    IS_SOURCED=1 source "$anchor_lib"
    # Strict same-UTC-day check. slack_thread_anchor_get has a 36h cross-day
    # grace (ANCHOR_GRACE_SEC default) intended for cron that posts at 23:50
    # then 00:20 next day — but that grace would suppress legitimate day-N+1
    # posts and turn this daily digest into a ~36h-cadence one. Setting
    # ANCHOR_GRACE_SEC=0 disables the cross-day path; the same-day fast path
    # (stored_day == today) still fires before the grace check.
    if ANCHOR_GRACE_SEC=0 existing_ts=$(slack_thread_anchor_get "$job_name" 2>/dev/null) && [[ -n "$existing_ts" ]]; then
      echo "  daily anchor: already posted today (existing ts=$existing_ts); skipping"
      return 0
    fi
  fi

# 2026-06-23: switched from one giant chunked post in $anchor_channel to
  # one Slack message per source channel, all delivered to $anchor_channel.
  # Jeffrey's complaint: the chunked message was too long AND each of its
  # inline Slack thread URLs produced a link-preview card, burying the
  # actual digest. Each per-channel message now stays naturally short
  # (5-10 thread entries per source channel), so chunking is unnecessary,
  # and slack_post_message now sends unfurl_links=false (see header) to
  # suppress the preview cards. The post order is deterministic (sorted
  # by channel_id) so it doesn't reshuffle between cron runs.
  #
  # Group threads by source channel.
  local -a source_channels=()
  declare -A seen_chan=()
  while IFS='|' read -r ch _ts _url _kind; do
    [[ -z "$ch" ]] && continue
    if [[ -z "${seen_chan[$ch]:-}" ]]; then
      seen_chan[$ch]=1
      source_channels+=("$ch")
    fi
  done <<<"$threads_csv"
  if [[ ${#source_channels[@]} -eq 0 ]]; then
    echo "slack_post_daily_anchor: empty threads_csv after grouping" >&2
    return 0
  fi
  # Sort for deterministic ordering.
  local IFS=$'\n'
  source_channels=($(printf '%s\n' "${source_channels[@]}" | sort))
  unset IFS

  local total_bytes=0
  local all_ok=0
  local first_ts=""
  local total_posted=0
  for src_chan in "${source_channels[@]}"; do
    # Build a CSV restricted to this source channel (use real channel id
    # in col 1 so slack__build_channel_message's `if ch == target` filter
    # matches all rows in this group).
    local per_chan_csv
    per_chan_csv=$(awk -F'|' -v c="$src_chan" 'NF>=4 && $1==c {print $1"|"$2"|"$3"|"$4}' <<<"$threads_csv")

    local msg
    if ! msg=$(slack__build_channel_message "$report_url" "$report_dt" "$judgment_md" "$per_chan_csv" "$src_chan" 2>/dev/null); then
      echo "  daily anchor: build_channel_message failed for $src_chan (continuing)" >&2
      all_ok=1
      continue
    fi
    if [[ -z "$msg" ]]; then
      echo "  daily anchor: empty build for $src_chan (no judgment match; skipping)" >&2
      continue
    fi
    # Per-channel message is naturally short (5-10 thread entries), but if
    # an extreme spike pushes it over SLACK_ANCHOR_CHUNK_MAX (3500), chunk
    # at thread-entry boundaries — same logic as the previous one-shot
    # chunker, just scoped to a single source channel's entries.
    local -a chunks=()
    mapfile -t -d '' chunks < <(slack__chunk_anchor_message "$msg")
    local ci=0
    for c in "${chunks[@]}"; do
      chunks[$ci]="${c%$'\0'}"
      ci=$((ci+1))
    done
    if [[ ${#chunks[@]} -eq 0 ]]; then
      continue
    fi

    local i=0
    for chunk in "${chunks[@]}"; do
      i=$((i+1))
      total_bytes=$(( total_bytes + ${#chunk} ))
      local chunk_out
      if chunk_out=$(slack_post_message "$anchor_channel" "$chunk" 2>&1); then
        total_posted=$(( total_posted + 1 ))
        echo "  daily anchor: [$src_chan] chunk $i/${#chunks[@]} posted to $anchor_channel ($(echo -n "$chunk" | wc -c) bytes)"
        if [[ -z "$first_ts" && -n "$chunk_out" ]]; then
          first_ts="$chunk_out"
        fi
      else
        echo "slack_post_daily_anchor: FAILED to post [$src_chan] chunk $i/${#chunks[@]} to $anchor_channel: $chunk_out" >&2
        all_ok=1
      fi
    done
  done

  # Register the anchor ts so subsequent cron firings skip the post.
  # Without this, the 5b-leak detector flags each cron tick's anchor
  # post as sub-class 5c because no var/slack/<job>/daily-thread.ts is written.
  if [[ $all_ok -eq 0 && -n "$first_ts" && -n "$anchor_lib" ]] \
      && command -v slack_thread_anchor_set >/dev/null 2>&1; then
    slack_thread_anchor_set "$job_name" "$first_ts" || \
      echo "  daily anchor: WARNING slack_thread_anchor_set failed (non-fatal)" >&2
  fi

  if [[ $all_ok -eq 0 ]]; then
    echo "  daily anchor: ${#source_channels[@]} source channel(s) → $total_posted message(s) to $anchor_channel (total $total_bytes bytes)"
    return 0
  fi
  return 1
}

# Build a one-thread compact summary (used by the per-thread reply). Args:
#   $1 = report_url
#   $2 = report_date_time
#   $3 = judgment_md
#   $4 = threads_csv (full set, the row matching $5 is picked)
#   $5 = channel_id of the target thread
#   $6 = thread_ts of the target thread
# Echoes the message text on stdout (or empty if nothing to say).
slack__build_thread_reply() {
  local report_url="$1" report_dt="$2" judgment_md="$3" threads_csv="$4" target_channel="$5" target_ts="$6"
  THREADS="$threads_csv" TARGET="$target_channel" REPORT_URL="$report_url" REPORT_DT="$report_dt" \
    JUDGMENT="$judgment_md" TARGET_TS="$target_ts" python3 <<'PY'
import os, re, sys

threads_raw = os.environ["THREADS"]
target = os.environ["TARGET"]
target_ts = os.environ["TARGET_TS"]
report_url = os.environ["REPORT_URL"]
report_dt = os.environ["REPORT_DT"]
judgment = os.environ["JUDGMENT"]

# Find the row for this (chan, ts)
row = None
for line in threads_raw.splitlines():
  if not line.strip():
    continue
  parts = line.split("|", 3)
  if len(parts) < 4:
    continue
  ch, ts, url, kind = parts[0], parts[1], parts[2], parts[3]
  if ch == target and ts == target_ts:
    row = (ts, url, kind)
    break
if row is None:
  sys.exit(0)
ts, url, kind = row

# Parse judgment into sections: title -> body
sections = {}
current_title = None
current_body = []
for line in re.split(r'(?m)^### ', judgment):
  if not line.strip():
    continue
  if current_title is not None and current_body:
    sections[current_title] = "\n".join(current_body).strip()
  parts = line.split('\n', 1)
  current_title = parts[0].strip()
  current_body = [parts[1]] if len(parts) > 1 else []
if current_title is not None and current_body:
  sections[current_title] = "\n".join(current_body).strip()

# Match this thread to a section
matched_body = None
matched_title = None
for title, body in sections.items():
  if url in body:
    matched_body = body
    matched_title = title
    break
if matched_body is None:
  ts_no_dot = ts.replace(".", "")
  for title, body in sections.items():
    if ts_no_dot in body.replace(".", ""):
      matched_body = body
      matched_title = title
      break
if matched_body is None:
  matched_body = "(no LLM judgment available for this thread)"
  matched_title = "thread"

# Truncate body for Slack (8 lines, stop at blank or "### " or "**executive")
body_lines = matched_body.split("\n")
short_body_lines = []
for bl in body_lines[:20]:
  stripped = bl.strip()
  if not stripped and short_body_lines:
    break
  if stripped.lower().startswith("**executive summary"):
    break
  if stripped.startswith("### "):
    break
  short_body_lines.append(bl)
  if len(short_body_lines) >= 8:
    break
short_body = "\n".join(short_body_lines)

# Build the reply: header + indented body + report link. NO ":clipboard:" —
# that's reserved for the daily anchor at channel root. A threaded reply
# with ":clipboard:" is a 5b-leak-detector false positive waiting to happen.
out = []
out.append(f"*Slack thread roadmap — {report_dt}* ({kind})")
out.append(f"<{url}|{matched_title}>")
out.append("")
for bl in short_body.split("\n"):
  if bl.strip():
    out.append(f"  > {bl.strip()}")
out.append("")
out.append(f"Full report: {report_url}")
print("\n".join(out).rstrip())
PY
}

slack_post_per_thread_summary() {
  local channels_csv="$1" report_url="$2" report_dt="$3" judgment_md="$4" threads_csv="$5"
  local grace_min="${DAILY_ANCHOR_GRACE_MIN:-60}"
  local now_epoch
  now_epoch=$(date +%s)

  if [[ -z "$threads_csv" ]]; then
    echo "slack_post_per_thread_summary: no threads to post about" >&2
    return 0
  fi

  # Iterate every (chan, ts) row in threads.csv and post a REPLY under the
  # thread. Skip rows whose ts is within the grace window (the daily anchor
  # will cover them — avoids double-listing). Empty channels_csv (legacy
  # callers) is treated as "no preference" — we still iterate from the
  # threads_csv, not the channels_csv.
  local posted=0 failed=0 skipped=0
  while IFS='|' read -r chan ts url kind; do
    [[ -z "$chan" || -z "$ts" ]] && continue
    # Optional filter: if a channels_csv was passed, only post for channels
    # in that list (preserves the original API for callers that pre-filter).
    if [[ -n "$channels_csv" ]]; then
      local match=0
      for want in $channels_csv; do
        [[ "$want" == "$chan" ]] && match=1 && break
      done
      [[ $match -eq 0 ]] && continue
    fi
    # Grace-window skip: thread younger than grace_min → daily anchor covers it.
    local ts_int="${ts%%.*}"
    local age_sec=$(( now_epoch - ts_int ))
    if (( age_sec < grace_min * 60 )); then
      skipped=$((skipped + 1))
      continue
    fi
    local msg
    if ! msg=$(slack__build_thread_reply "$report_url" "$report_dt" "$judgment_md" "$threads_csv" "$chan" "$ts" 2>/dev/null); then
      failed=$((failed + 1))
      continue
    fi
    if [[ -z "$msg" ]]; then
      continue
    fi
    local reply_err
    if reply_err=$(slack_post_message "$chan" "$msg" "$ts" 2>&1); then
      posted=$((posted + 1))
      echo "  posted reply to $chan/$ts ($(echo -n "$msg" | wc -c) bytes)"
    else
      failed=$((failed + 1))
      echo "  FAILED to post reply to $chan/$ts: $reply_err" >&2
    fi
  done <<<"$threads_csv"

  echo "slack_post_per_thread_summary: posted=$posted failed=$failed skipped=$skipped (grace=${grace_min}m)"
  if [[ $failed -gt 0 ]]; then
    return 1
  fi
  return 0
}
