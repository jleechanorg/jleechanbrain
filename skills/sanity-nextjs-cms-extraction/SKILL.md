---
name: sanity-nextjs-cms-extraction
description: "Extract article body from Sanity/Next.js RSC JSON."
version: 1.0.0
author: Hermes Agent
license: MIT
tags: [Curl, Sanity, Next.js, CMS, Extraction, RSC]
metadata:
  hermes:
    tags: [Curl, Sanity, Next.js, CMS, Extraction, RSC]
    category: research
    related_skills: [curl-sourced-research-reports, browser-exec-extraction-fallback]
---

# Sanity / Next.js CMS Body Extraction

Use when a target URL serves its article body as **nested RSC JSON inside the
HTML** rather than rendered `<p>` / `<article>` tags — the pattern is:

- The HTML page is a Next.js server-component shell.
- The article body lives inside `__NEXT_DATA__` or an inline RSC payload
  (a list of blocks serialized as `\"_type\":\"block\"`).
- Each block has a `children[]` array of `\"_type\":\"span\"` objects, each
  span carrying `\"marks\":[…]` + `\"text\":\"…\"`.
- Plain HTML extraction (`<p>…</p>`, `<article>…</article>`) returns 0
  matches because the body is JSON-encoded text inside `<script>` payloads.

**Verified target (2026-08-25):** https://tessl.io/blog/the-rise-of-the-harness-engineer
— Sanity backend, Chakra UI theme, embedded Sanity `_type:"block"` bodies in the
RSC payload. `web_extract` returned "search-only backend" error; curl + Sanity
JSON extraction recovered the full article text.

## When to Use

- `web_extract` is unavailable OR returns a backend-bypass error.
- The page renders fine in a browser but `curl | grep '<p>'` returns near-zero
  prose matches.
- The HTML body contains a `<script>` block > 50KB with JSON that has
  `\"_type\":\"block\"` markers.
- You can identify the body source (Sanity CMS is the most common;
  Contentful and Strapi have similar but distinguishable shapes).

## When NOT to Use

- The page renders its body in plain HTML → use `curl-sourced-research-reports`
  directly, no JSON extraction needed.
- The page requires authentication to render the body → `browser_exec` with
  a signed-in browser session is the right tool (`auth-gated-site-read`).
- The page is fully static and `curl -sSL | sed 's/<[^>]*>//g'` recovers
  the prose → no need for the JSON path.

## The 3-step extraction recipe

### Step 1 — Fetch with a desktop UA and a non-default `Accept-Language`

```bash
curl -sSL -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36" \
  -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9" \
  -H "Accept-Language: en-US,en;q=0.9" \
  "https://<site>/blog/<slug>" -o /tmp/<site>_raw.html
```

**Why:** many Sanity/Next.js deployments serve a 403 to `curl/8.x` or to
missing `Accept-Language`. The desktop UA + language hint bypasses that gate.

Sanity also frequently serves a **second pass** of article data in the
inline RSC payload (not in `__NEXT_DATA__` JSON, but as a separate `self.__next_f.push([…])`
stream). Plan to extract from **both** locations if the first pass misses
spans.

### Step 2 — Locate the body blocks

Sanity block shape (regex-extractable):
```json
{"_type":"block","children":[{"_type":"span","marks":["strong"],"text":"…"}, …], …, "style":"normal"}
```

**Block-boundary regex** (non-greedy per block, capture children + style):
```python
import re
block_pattern = re.compile(
    r'\\"_type\\":\\"block\\",\\"children\\":(\[(?:[^\[\]]|\[[^\]]*\])*?\])'
    r'(?:,\\"level\\":(\d+))?(?:,\\"listItem\\":\\"[^"]+\\")?'
    r',\\"markDefs\\":\[[^\]]*\][^\}]*\\"style\\":\\"([^"]+)\\"',
    re.DOTALL
)
```

**Span-extraction regex** (per children array):
```python
span_pattern = re.compile(
    r'\\"marks\\":(\[[^\]]*\]|\[\]),\\"text\\":\\"((?:[^"\\]|\\.)*)\\"'
)
```

`marks` tells you the formatting: `"strong"` → bold, `"em"` → italic,
`"code"` → inline code. Wrap the text accordingly when emitting markdown.

### Step 3 — Dedupe and emit

**Critical pitfall:** in Sanity RSC payloads, each span text often appears
**twice** — once as the actual `\"text\"` field and once embedded as the
**inner JSON of the next span** (because the regex boundary misfires on
the closing `\"marks\":[…]` of the previous span). Dedup with a `seen` set
on the joined plain text per block.

```python
seen = set()
out = []
for child_blob, style in blocks:
    texts = []
    for sm in span_pattern.finditer(child_blob):
        marks_blob, raw = sm.group(1), sm.group(2)
        text = html.unescape(raw.replace('\\"','"').replace('\\\\','\\').replace('\\n','\n'))
        if text.startswith(','):       # leftover JSON separator
            text = text.lstrip(',').lstrip()
        if not text:
            continue
        is_bold = '"strong"' in marks_blob
        is_italic = '"em"' in marks_blob
        is_code = '"code"' in marks_blob
        if is_code:    texts.append(f'`{text}`')
        elif is_bold:  texts.append(f'**{text}**')
        elif is_italic: texts.append(f'*{text}*')
        else:          texts.append(text)
    plain = ''.join(texts).strip()
    if not plain or plain in seen:
        continue
    seen.add(plain)
    # emit heading vs paragraph based on style
    if style.startswith('h'):
        try:    level = min(int(style[1:]) + 1, 6)
        except ValueError: level = 2
        out.append(f"\n{'#'*level} {plain}\n")
    else:
        out.append(f"\n{plain}\n\n")
```

A typical Tessl-style article: 50–60 unique blocks, ~15KB of clean markdown.

## Pitfalls

- **Skipping the desktop UA.** curl/8.x default UA gets 403 from many Sanity
  deployments. Always set a real desktop UA.
- **Trying `<p>` regex on the raw HTML.** Sanity body content is JSON-encoded
  inside `<script>` — `<p>` returns zero hits. Always inspect the page with
  `rg '_type.*block|__NEXT_DATA__'` first to confirm the body is JSON-encoded.
- **Not deduping.** Without the `seen` set, you ship the article twice — once
  as a coherent document and once as fragmented span residue. The artifact is
  readable but the token spend doubles.
- **Forgetting inline code marks.** Tessl article has `tessl agent` in
  `code` marks — without that formatting, the reader can't tell command names
  from surrounding prose.
- **Confusing Sanity with Contentful.** Contentful uses
  `\"nodeType\":\"text\"` + `\"value\":…` instead of `\"_type\":\"span\"` +
  `\"text\":…`. Different shape, different regex. Sanity is much more common
  in Next.js frontends; check the JSON shape before pasting a regex.
- **Treating the page as JavaScript-required.** Sanity/Next.js is server-side
  rendered — the body IS in the HTML payload. Don't escalate to
  `browser_exec` unless `curl` returns a JS-only shell (then it's actually
  a JS-hydration SPA, not Sanity).

## Verification

After extraction, sanity-check:

1. **Block count.** Should be 30–100 for a typical blog post. < 10 = missed
   a payload location; > 200 = missed dedup.
2. **Heading hierarchy.** At least one `h2` block (`##`) and one `h4`
   block (`####`) for articles with subsections.
3. **First 3 blocks** should be the article intro / dek / opening paragraph.
4. **Tail 3 blocks** should be the closing line / call-to-action / footer.
5. **No JSON separator residue.** `grep -c '\\"text\\":\\"'` on the cleaned
   markdown should be 0.

If any of these fail, re-run Step 1 with a different UA, or escalate to
`browser_exec` (`js("document.body.innerText")` as the canonical fallback).

## When to escalate to `browser_exec`

- The page returns the Sanity/Next.js shell but the article body is gated
  behind a client-side fetch (no inline RSC payload).
- The article is paywalled or auth-required.
- The page is rendered via JavaScript hydration and `curl` only sees the
  skeleton.

In those cases, `browser_exec` is faster than perfecting the JSON regex —
see `references/browser-exec-extraction-fallback.md` in the
`curl-sourced-research-reports` umbrella for the canonical Python recipe.

## Cross-references

- **Canonical parent**: `~/.smartclaw/skills/research/curl-sourced-research-reports/SKILL.md`
  — for the surrounding pipeline (UA selection, score-and-strip, verify).
- **Browser fallback**: `references/browser-exec-extraction-fallback.md`
  in the parent umbrella — for JS-hydrated pages.
- **Verified source**: https://tessl.io/blog/the-rise-of-the-harness-engineer
  (Tessl.io, Sanity + Next.js, 2026-08-25 extraction returned 52 unique
  blocks / 15.7KB of clean markdown after dedup).
