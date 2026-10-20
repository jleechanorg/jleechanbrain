# browser_exec extraction fallback — when curl + Tavily both fail

This is the **deepest retrieval tier** — used only when curl returns a JS-shell
page (e.g. vendor sites with client-side rendering) or when Tavily + web_extract
are explicitly disabled. The SKILL.md's "When NOT to Use" section already
names `browser_exec` for single-URL deep extraction; this reference captures
the concrete recipe verified 2026-08-20 on a K-drama cast lookup.

## The tier ordering (canonical)

1. **curl + grep** — fast, no JS, plain-text vendors (Wikipedia raw, official docs).
2. **web_extract** (Tavily/Firecrawl) — handles basic JS, returns markdown.
3. **browser_exec** (Browser Use CLI, `~/.local/bin` PATH) — full Chromium, JS-rendered.
4. **Aside MCP / `aside repl`** — persistent daemon, reuses signed-in session.

Use 3 when 1+2 return `Web tools are not configured` or vendor blocks curl UA.

## browser_exec recipe (verified pattern)

```python
# In a single browser_exec call (Python in browser-use REPL):
new_tab("<url>")           # opens + navigates
wait_for_load()             # blocks until DOMContentLoaded
text = js("document.body.innerText")   # full body as text string
import re
# do regex in the SAME block — don't dump 100KB to parent context
for m in re.finditer(r"(?i)<pattern>", text):
    ctx = text[max(0, m.start()-100):m.end()+200]
    print(ctx)              # prints surface back in the tool result
```

**Key gotchas:**

- `js()` returns a string — Python `re` module is available in the same block.
- JS string literals must use doubled backslashes (the harness passes code via
  `exec()`, so an unterminated single-quote crashes the call). Test with a
  throwaway snippet first if your string has embedded quotes.
- For multi-page extraction, use `new_tab(url)` repeatedly — the tab list
  persists, so you can land on page N and reference previous tabs via
  `listBrowserTabs()`.
- `capture_screenshot()` auto-attaches images to your context — use only when
  you actually need pixels, not for text extraction.
- Output is capped at ~50KB stdout — chunk large extractions across multiple
  `browser_exec` calls.

## Verify the binary is alive

```bash
which browser-use        # ${HOME}/.cache/uv/archive-v0/.../browser-use
ls ~/.local/bin/browser-use 2>&1 || echo "MISSING"
```

If missing, install: `uv tool install browser-use` (the env-preferences rule
allows autonomous installs under `~/.local/bin`).

## Domain-specific extension: K-drama cast lookups

For K-drama / K-movie cast questions (Wikipedia only lists top-billed):

1. Search MyDramaList: `https://mydramalist.com/search?q=<show-name>`
2. Find the canonical slug: result looks like `/15062-oh-my-venus`
3. Pull full cast: `https://mydramalist.com/<id>-<slug>/cast`
4. The page renders `Main Role` + `Support Role` + `Guest Role` blocks in
   `document.body.innerText`. Regex `(?i)anna|hollywood|reporter|scandal` to
   surface Western-named guest roles.

**Why this matters:** Wikipedia cast sections list 6-12 names; MDL lists all
guest roles with episode numbers. Side characters and one-shot cameos are
almost always only on MDL.

## Worked example — Oh My Venus "Anna" lookup (2026-08-20)

User asked: *"Anna sue oh my venus real actress name"* — a side character.

1. `web_search` / `web_extract` → returned `Web tools are not configured`.
2. `curl https://en.wikipedia.org/wiki/Oh_My_Venus` → 200 OK, but `Cast`
   section only listed So Ji-sub + Shin Min-a + 4 supports. No "Anna".
3. Pivoted to `browser_exec` per `/browser` → `aside` available, signed in.
4. `new_tab("https://en.wikipedia.org/wiki/Oh_My_Venus")` + regex `(?i)anna`
   on `body.innerText` → **0 matches**.
5. Searched MDL: `https://mydramalist.com/search?q=oh+my+venus` → slug
   `/15062-oh-my-venus`.
6. `new_tab("https://mydramalist.com/15062-oh-my-venus/cast")` → full cast
   with `Support Role` + `Guest Role` blocks.
7. Regex on full cast → only Western name is `Joey Albright` as `[Reporter]`
   (guest role, no Wikipedia page).
8. Reported honestly: **no "Anna" character exists in Oh My Venus**. Asked
   user to confirm whether they meant a different show (likely *Oh My Ghost*
   which has an actual Anna played by Park Han-byul).

## Anti-patterns

- � Retrying `web_search` / `web_extract` after they returned "not configured"
  — they will return the same error. Pivot immediately.
- ❌ Dumping full `innerText` (10-100KB) back to parent context — regex
  inside the browser_exec block, print only the matches.
- ❌ Using `curl` on a JS-only page and reporting the script-tagged empty
  content as the source — that's the page, not the data.
- ❌ Posting a "Pick one: A) typo, B) wrong show, C) ..." menu when the
  user already said "there should be web search" — that's the
  `pre-execution-option-bailout-guard` violation.
