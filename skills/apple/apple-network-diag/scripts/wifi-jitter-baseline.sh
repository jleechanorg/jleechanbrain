#!/usr/bin/env bash
# wifi-jitter-baseline.sh — Measure ping jitter, packet loss, RSSI, SNR.
# Re-runnable. Each run appends a timestamped log under ~/wifi-jitter/ so
# before/after WiFi config changes can be diffed mechanically.
#
# Usage:
#   bash ~/wifi-jitter-baseline.sh [label]
#
# The [label] becomes part of the log filename: e.g.
#   ~/wifi-jitter/20260814T164328-pre-frontier-disable.log
#
# Always inspect with `cat ~/wifi-jitter/<latest>.log` and compare σ/avg/max
# against the previous run. Don't claim a fix worked without the diff.

set -euo pipefail
LABEL="${1:-baseline}"
TS="$(date +%Y%m%dT%H%M%S)"
LOGDIR="${HOME}/wifi-jitter"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/${TS}-${LABEL}.log"

# Make sure the survey script lives where we expect. If the user moved it,
# fall back to the canonical skill-path location.
SURVEY_SWIFT="${HOME}/.smartclaw/skills/apple/apple-network-diag/scripts/wifi_survey.swift"
[[ -f "$SURVEY_SWIFT" ]] || SURVEY_SWIFT="${HOME}/wifi-survey.swift"

GW="192.168.254.254"
EXT_HOST="1.1.1.1"

exec > >(tee "$LOGFILE") 2>&1

echo "=== WiFi jitter baseline ==="
echo "Timestamp:    $(date -Iseconds)"
echo "Label:        $LABEL"
echo "Host:         $(hostname)"
echo "SSID:         $(networksetup -getairportnetwork en0 2>&1 | awk -F': ' '{print $2}')"
echo "Wi-Fi IP:     $(ipconfig getifaddr en0 2>/dev/null || echo 'not connected')"
echo ""

echo "--- ping -c 20 -i 0.2 $GW (gateway) ---"
ping -c 20 -i 0.2 "$GW" || true
echo ""

echo "--- ping -c 20 -i 0.2 $EXT_HOST (internet, 1.1.1.1) ---"
ping -c 20 -i 0.2 "$EXT_HOST" || true
echo ""

if [[ -f "$SURVEY_SWIFT" ]]; then
  echo "--- WiFi survey (single sample) ---"
  swift "$SURVEY_SWIFT" || true
else
  echo "(wifi_survey.swift not found at $SURVEY_SWIFT — skipping survey)"
fi
echo ""

echo "--- DNS resolution x5 ---"
for i in 1 2 3 4 5; do
  /usr/bin/time -p nslookup google.com >/dev/null 2>&1 || true
done
echo ""

echo "=== Log saved to $LOGFILE ==="
echo ""
echo "=== Diff hint ==="
echo "Compare σ/avg/max against the most recent prior log:"
echo "  ls -lt ~/wifi-jitter/*.log | head"
echo "  diff <prior>.log $LOGFILE | less"