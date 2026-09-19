#!/bin/bash
# chrome_stage_batch.sh — Stage all 14 platforms using chrome_stage.py
# Each platform: chrome cookies → headless Chrome → compose URL → paste → screenshot
# Bundled so that any platform failure doesn't kill the rest.

set -u

DRAFTS=/tmp/drafts/worldai-hotd-2026-08-05
SHOTS=$DRAFTS/screenshots/chrome
mkdir -p "$SHOTS"

PY=${HOME}/.smartclaw/skills/social-poster/scripts/chrome_stage.py

# Platform → (draft_file, compose_url, browser)
# browser=chrome uses Chrome Default profile cookies (works for Dev.to, Fb, Tw, Li, but Reddit/headless gets blocked)
# browser=aside uses Aside cookies (works for Reddit + Twitter + LinkedIn, but Mastodon/Threads unauthenticated)
declare -A PLATFORMS=(
  [twitter]="twitter.md|https://x.com/compose/post|chrome"
  [linkedin]="linkedin.md|https://www.linkedin.com/feed/?shareActive=true|chrome"
  [facebook]="facebook.md|https://www.facebook.com/|chrome"
  [devto]="devto.md|https://dev.to/new|chrome"
  [mastodon]="mastodon.md|https://mastodon.social/publish|chrome"
  [threads]="threads.md|https://www.threads.net/|chrome"
  [reddit_localllama]="reddit_localllama.md|https://old.reddit.com/r/LocalLLaMA/submit?selftext=true|aside"
  [reddit_rag]="reddit_rag.md|https://old.reddit.com/r/Rag/submit?selftext=true|aside"
  [reddit_openai]="reddit_openai.md|https://old.reddit.com/r/OpenAI/submit?selftext=true|aside"
  [reddit_ai_rpg_community]="reddit_ai_rpg_community.md|https://old.reddit.com/r/ai_rpg_community/submit?selftext=true|aside"
  [reddit_AIPlayableFiction]="reddit_AIPlayableFiction.md|https://old.reddit.com/r/AIPlayableFiction/submit?selftext=true|aside"
  [reddit_AIDungeon]="reddit_AIDungeon.md|https://old.reddit.com/r/AIDungeon/submit?selftext=true|aside"
  [reddit_aigamedev]="reddit_aigamedev.md|https://old.reddit.com/r/aigamedev/submit?selftext=true|aside"
  [reddit_HouseOfTheDragon]="reddit_HouseOfTheDragon.md|https://old.reddit.com/r/HouseOfTheDragon/submit?selftext=true|aside"
  [reddit_asoiaf]="reddit_asoiaf.md|https://old.reddit.com/r/asoiaf/submit?selftext=true|aside"
  [reddit_freefolk]="reddit_freefolk.md|https://old.reddit.com/r/freefolk/submit?selftext=true|aside"
  [hackernews]="hackernews.md|https://news.ycombinator.com/submit|aside"
)

OUT=$DRAFTS/chrome_stage_results.json
echo '{}' > "$OUT"

for plat in "${!PLATFORMS[@]}"; do
  IFS='|' read -r draft url browser <<< "${PLATFORMS[$plat]}"
  shot="$SHOTS/${plat}.png"
  echo "===== $plat ($browser) ====="
  if [ ! -f "$DRAFTS/$draft" ]; then
    echo "  MISSING DRAFT: $DRAFTS/$draft"
    continue
  fi
  python3 "$PY" --platform "$plat" --draft "$DRAFTS/$draft" \
    --compose-url "$url" --screenshot "$shot" --wait 8 --browser "$browser" \
    > "$SHOTS/${plat}.json" 2>&1
  rc=$?
  if [ $rc -eq 0 ]; then
    echo "  STAGED: $plat"
  else
    echo "  FAILED (rc=$rc) — see $SHOTS/${plat}.json"
  fi
  # Merge into results
  python3 -c "
import json,sys
d=json.load(open('$SHOTS/${plat}.json'))
o=json.load(open('$OUT'))
o['$plat']=d
json.dump(o,open('$OUT','w'),indent=2)
"
done

echo
echo "===== Summary ====="
python3 -c "
import json
r=json.load(open('$OUT'))
staged=sum(1 for v in r.values() if v.get('status')=='staged')
login=sum(1 for v in r.values() if v.get('status')=='login_wall')
paste=sum(1 for v in r.values() if v.get('status')=='paste_failed')
failed=sum(1 for v in r.values() if v.get('status')=='failed')
print(f'STAGED={staged}  LOGIN_WALL={login}  PASTE_FAILED={paste}  FAILED={failed}  TOTAL={len(r)}')
for k,v in r.items():
  s=v.get('status','?')
  bl=v.get('body_len_in_field',0)
  bel=v.get('body_len_expected',0)
  print(f'  {s:13s} {k:30s} body={bl}/{bel}')
"
