#!/usr/bin/env bash
# WA prompt size profile — top-25 files by bytes.
# Usage: bash scripts/wa_prompt_size_profile.sh [/path/to/worldarchitect.ai]

REPO="${1:-$HOME/projects/worldarchitect.ai}"

echo "=== Top-25 prompt files by bytes ==="
echo
(
  for f in "$REPO/mvp_site/prompts"/*.md \
           "$REPO/mvp_site/prompts/shared"/*.md \
           "$REPO/mvp_site/prompts/multiverse"/*.md \
           "$REPO/mvp_site/prompts/divine"/*.md; do
    [ -f "$f" ] || continue
    printf "%8d %5d %s\n" "$(wc -c <"$f")" "$(wc -l <"$f")" "${f#$REPO/}"
  done
) | sort -rn | head -25

echo
echo "=== Total ==="
total=$(
  for f in "$REPO/mvp_site/prompts"/*.md \
           "$REPO/mvp_site/prompts/shared"/*.md \
           "$REPO/mvp_site/prompts/multiverse"/*.md \
           "$REPO/mvp_site/mvp_site/prompts/divine"/*.md 2>/dev/null; do
    [ -f "$f" ] || continue
    cat "$f" >/dev/null
  done
  find "$REPO/mvp_site/prompts" -name "*.md" -type f -exec cat {} \; 2>/dev/null | wc -c
)
echo "$total bytes across $(find "$REPO/mvp_site/prompts" -name "*.md" -type f | wc -l | tr -d ' ') files"

echo
echo "=== Top-5 as % of total ==="
top5=$(
  for f in "$REPO/mvp_site/prompts"/*.md \
           "$REPO/mvp_site/prompts/shared"/*.md \
           "$REPO/mvp_site/prompts/multiverse"/*.md \
           "$REPO/mvp_site/prompts/divine"/*.md; do
    [ -f "$f" ] || continue
    printf "%d\n" "$(wc -c <"$f")"
  done | sort -rn | head -5 | paste -sd+ | bc
)
all=$(find "$REPO/mvp_site/prompts" -name "*.md" -type f -exec wc -c {} \; | awk '{sum+=$1} END {print sum}')
awk -v t="$top5" -v a="$all" 'BEGIN { if (a > 0) printf "%.1f%%\n", (t/a)*100; else print "n/a" }'

echo
echo "=== Rule-vs-reference classification for top-5 ==="
echo "(rule lines = MUST|MANDATORY|🚨|CRITICAL|HARD INVARIANT|REQUIRED|🚫|⚠️)"
echo "(code/example lines = inside fenced blocks)"
echo
for f in $(find "$REPO/mvp_site/prompts" -name "*.md" -type f -exec wc -c {} \; \
           | sort -rn | head -5 | awk '{print $2}'); do
  total=$(wc -l <"$f")
  rules=$(grep -cE 'MUST|MANDATORY|🚨|CRITICAL|HARD INVARIANT|REQUIRED|🚫|⚠️' "$f" 2>/dev/null || echo 0)
  code=$(awk '/^```/{c=!c;next} c' "$f" | wc -l)
  rel="${f#$REPO/}"
  printf "  %-60s L:%4d R:%3d (%2d%%) C:%4d (%2d%%)\n" "$rel" "$total" "$rules" "$((rules*100/total))" "$code" "$((code*100/total))"
done
