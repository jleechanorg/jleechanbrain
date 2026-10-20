# Browser-Exec Extraction Fallback for JS-Hydrated Pages

When `curl` returns a JS-hydration shell (Next.js client-side rendering,
React SPAs without SSR body, etc.) and the Sanity/Next.js JSON-extraction
recipe in the parent skill cannot recover the article text, the canonical
fallback is `browser_exec` via the Aside browser MCP.

## When to escalate

- `curl -sSL <url>` returns < 5 KB of HTML with no `<script>` payload
  containing `\"_type\":\"block\"` markers.
- The page hydrates content client-side (React, Vue, Svelte SPA patterns).
- The page requires authentication or cookie-gated content.
- Sanity `__NEXT_DATA__` is present but the article body lives behind a
  separate fetch (e.g. `/api/sanity/query`).

## Recipe

```python
# Via hermes_tools runtime
from hermes_tools import browser_exec
result = browser_exec(code="""
text = js("document.body.innerText")
print(text[:50000])  # cap to 50KB
""")
```

The `js()` helper runs JS in the active tab and returns the result. For
authenticated content, see `auth-gated-site-read` skill — the recipe
covers Chrome cookie injection + signed-in browser session.

## When to NOT escalate

- The Sanity extraction recipe in the parent skill succeeds → no need.
- The page is plain HTML (use `curl-sourced-research-reports` directly).
- The page is a known static export (`next export`, `gatsby build`).

## Cross-reference

For the canonical browser_exec + Playwright fallback (and Python
helper recipes), see:
`~/.smartclaw/skills/research/curl-sourced-research-reports/references/browser-exec-extraction-fallback.md`
