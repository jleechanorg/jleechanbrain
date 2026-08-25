#!/usr/bin/env bash
# test_slack_anchor_chunking.sh
#
# Unit-style assertions for the daily-anchor chunking helper in
# lib-slack-post.sh. Verifies:
#   1. slack__chunk_anchor_message is a no-op (1 chunk) for messages
#      smaller than SLACK_ANCHOR_CHUNK_MAX (default 3500).
#   2. Large messages with many thread entries are split into multiple
#      chunks, each ≤ SLACK_ANCHOR_CHUNK_MAX chars.
#   3. No chunk splits mid-entry: every chunk that contains a URL line
#      keeps all subsequent indented/judgment lines of that entry
#      together with it.
#   4. The header (":clipboard: Slack thread roadmap — ..." + "Full
#      report: ..." + blank line) appears only on the FIRST chunk.
#   5. Custom SLACK_ANCHOR_CHUNK_MAX override is respected.
#
# All assertions run against slack__chunk_anchor_message directly, with
# no Slack calls. Exit code: 0 if all pass, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib-slack-post.sh"
if [[ ! -f "$LIB" ]]; then
  echo "FATAL: lib-slack-post.sh not found at $LIB" >&2
  exit 1
fi

source "$LIB"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Run the chunker with the same mapfile pattern the production call
# site uses (slack_post_daily_anchor). The chunks are loaded into the
# caller-supplied array name; this avoids NUL-byte stripping that
# `$(...)` causes.
#
# Usage: do_chunk <max> <msg> <out_array_name>
do_chunk() {
  local max="$1" msg="$2" out_name="$3"
  local -a tmp=()
  mapfile -t -d '' tmp < <(SLACK_ANCHOR_CHUNK_MAX="$max" slack__chunk_anchor_message "$msg")
  # mapfile -d '' leaves the delimiter on each element; strip it.
  local i=0
  for c in "${tmp[@]}"; do
    tmp[$i]="${c%$'\0'}"
    i=$((i+1))
  done
  # Re-export under the requested name.
  local -n out_ref="$out_name"
  out_ref=()
  for c in "${tmp[@]}"; do
    out_ref+=("$c")
  done
}

# === Test 1: small message → 1 chunk ===
echo ""
echo "=== test 1: small message → 1 chunk ==="
SMALL_MSG=$':clipboard: *Slack thread roadmap — 2026-06-22 1000*\nFull report: https://example.com/r.md\n\n• <https://jleechanai.slack.com/archives/C1/p11|thread A>\n  > body A\n\n• <https://jleechanai.slack.com/archives/C1/p22|thread B>\n  > body B\n'
CHUNKS1=()
do_chunk 3500 "$SMALL_MSG" CHUNKS1
if [[ "${#CHUNKS1[@]}" -eq 1 ]]; then
  ok "small message → 1 chunk"
else
  bad "small message expected 1 chunk, got ${#CHUNKS1[@]}"
fi
C0="${CHUNKS1[0]-}"
if [[ "$C0" == *"Slack thread roadmap"* && "$C0" == *"Full report:"* && "$C0" == *"thread A"* && "$C0" == *"thread B"* ]]; then
  ok "single chunk contains header + both entries"
else
  bad "single chunk missing header or entries (len=${#C0})"
fi

# === Test 2: large message with 28 entries → multiple chunks, each ≤ 3500 ===
echo ""
echo "=== test 2: large message → multiple chunks, each ≤ 3500 chars ==="
BIG_MSG=$':clipboard: *Slack thread roadmap — 2026-06-22 1000*\nFull report: https://example.com/r.md\n\n'
for i in $(seq 1 28); do
  # Use 60-byte padding so each entry is ~150 bytes; 3500/150 ≈ 23 entries
  # per chunk, so the 28 entries naturally force a 2-chunk split without
  # boundary-pressured overflow.
  pad=$(printf 'x%.0s' $(seq 1 60))
  BIG_MSG+=$'• <https://jleechanai.slack.com/archives/C0AH3RY3DK6/p'"$((1000000000 + i))"$'|thread '"$i"$'>\n  > judgment '"$i"$' '"$pad"$'\n\n'
done
CHUNKS2=()
do_chunk 3500 "$BIG_MSG" CHUNKS2
NC=${#CHUNKS2[@]}
if [[ "$NC" -gt 1 ]]; then
  ok "big message chunked into $NC chunks (>1)"
else
  bad "big message expected >1 chunk, got $NC"
fi
ALL_OK=1
for ((i=0; i<NC; i++)); do
  SIZE=${#CHUNKS2[$i]}
  if [[ "$SIZE" -gt 3500 ]]; then
    bad "chunk $i size $SIZE > 3500"
    ALL_OK=0
  fi
done
if [[ $ALL_OK -eq 1 ]]; then
  ok "all $NC chunks ≤ 3500 chars"
fi

# === Test 3: no chunk splits mid-entry ===
echo ""
echo "=== test 3: no chunk splits mid-entry ==="
ENTRY_INTEGRITY_OK=1
for ((i=0; i<NC; i++)); do
  C="${CHUNKS2[$i]}"
  URL_COUNT=$(grep -c 'https://jleechanai.slack.com/archives/' <<<"$C" || true)
  BODY_COUNT=$(grep -c '^  > ' <<<"$C" || true)
  if [[ "$URL_COUNT" -ne "$BODY_COUNT" ]]; then
    bad "chunk $i: $URL_COUNT URL lines vs $BODY_COUNT body lines (mid-entry split?)"
    ENTRY_INTEGRITY_OK=0
  fi
done
if [[ $ENTRY_INTEGRITY_OK -eq 1 ]]; then
  ok "every chunk has matching URL/body line counts (no mid-entry splits)"
fi

# === Test 4: header on first chunk only ===
echo ""
echo "=== test 4: header on first chunk only ==="
CHUNK0="${CHUNKS2[0]-}"
HEADER_LEAK_OK=1
if [[ "$CHUNK0" != *"Slack thread roadmap"* ]]; then
  bad "first chunk missing header"
  HEADER_LEAK_OK=0
fi
if [[ "$CHUNK0" != *"Full report:"* ]]; then
  bad "first chunk missing 'Full report:' line"
  HEADER_LEAK_OK=0
fi
for ((i=1; i<NC; i++)); do
  C="${CHUNKS2[$i]}"
  if [[ "$C" == *"Slack thread roadmap"* || "$C" == *"Full report: https://example.com/r.md"* ]]; then
    bad "chunk $i leaks header (should be on first chunk only)"
    HEADER_LEAK_OK=0
  fi
done
if [[ $HEADER_LEAK_OK -eq 1 ]]; then
  ok "header (Slack thread roadmap + Full report) appears only on chunk 0"
fi

# === Test 5: SLACK_ANCHOR_CHUNK_MAX override respected ===
echo ""
echo "=== test 5: SLACK_ANCHOR_CHUNK_MAX=300 → smaller chunks ==="
CHUNKS3=()
do_chunk 300 "$BIG_MSG" CHUNKS3
NC2=${#CHUNKS3[@]}
ALL_OK=1
for ((i=0; i<NC2; i++)); do
  SIZE=${#CHUNKS3[$i]}
  if [[ "$SIZE" -gt 300 ]]; then
    bad "override chunk $i size $SIZE > 300"
    ALL_OK=0
  fi
done
if [[ $ALL_OK -eq 1 && "$NC2" -ge "$NC" ]]; then
  ok "max=300 produces ≥ chunks (got $NC2 vs default $NC) and all ≤ 300"
else
  if [[ $ALL_OK -eq 1 ]]; then
    bad "max=300 produced $NC2 chunks, expected ≥ $NC"
  fi
fi

# === Test 6: empty input → no output ===
echo ""
echo "=== test 6: empty input → no chunks ==="
CHUNKS4=()
do_chunk 3500 "" CHUNKS4
if [[ "${#CHUNKS4[@]}" -eq 0 ]]; then
  ok "empty input → 0 chunks"
else
  bad "empty input expected 0 chunks, got ${#CHUNKS4[@]}"
fi

# === Test 7: single oversized entry → truncated to max ===
echo ""
echo "=== test 7: single oversized entry → truncated to max ==="
OVERSIZED_MSG=$':clipboard: *Slack thread roadmap — 2026-06-22 1000*\nFull report: https://example.com/r.md\n\n• <https://jleechanai.slack.com/archives/C1/p11|thread A>\n  > '
pad=$(printf 'x%.0s' $(seq 1 400))
OVERSIZED_MSG+="$pad"

CHUNKS5=()
do_chunk 300 "$OVERSIZED_MSG" CHUNKS5
NC5=${#CHUNKS5[@]}

ALL_OK=1
for ((i=0; i<NC5; i++)); do
  SIZE=${#CHUNKS5[$i]}
  if [[ "$SIZE" -gt 300 ]]; then
    bad "oversized chunk $i size $SIZE > 300 (failed to truncate)"
    ALL_OK=0
  fi
done
if [[ $ALL_OK -eq 1 ]]; then
  ok "all $NC5 chunks <= 300 (successfully truncated/split)"
fi

echo ""
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1