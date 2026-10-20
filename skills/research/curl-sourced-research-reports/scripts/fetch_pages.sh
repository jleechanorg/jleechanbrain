#!/usr/bin/env bash
# Bulk-fetch a list of URLs into /tmp with a desktop User-Agent.
# Usage: scripts/fetch_pages.sh https://a https://b ...
# Output filenames: /tmp/wiki_<urlslug>.html
# Each line of stdout: "<http-code> <output-path> <bytes>"
set -uo pipefail

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
TIMEOUT=25

for url in "$@"; do
  # slugify: keep alphanum + . + - + _ + % ; replace others with _
  slug=$(echo "$url" | sed 's|https\?://||;s/[^A-Za-z0-9._%-]/_/g')
  out="/tmp/wiki_${slug}.html"
  code=$(curl -sL --max-time "$TIMEOUT" -A "$UA" -o "$out" -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  size=$(stat -f "%z" "$out" 2>/dev/null || stat -c "%s" "$out" 2>/dev/null || echo 0)
  echo "${code} ${out} ${size}"
done
