# Wikipedia Extraction via curl — Parsoid-Aware Recipe

Two non-obvious gotchas when fetching Wikipedia with `curl` + Python regex:

## Gotcha 1: Parsoid HTML has no plain `<p>` tags

As of 2026, the Wikipedia HTML endpoint serves Parsoid-formatted HTML.
The article body is wrapped in `<p data-mw-...">{"...":"..."}</p>` style
JSON-blob paragraphs that look like attributes to a naive regex stripper.

**Wrong** (returns 0 paragraphs on modern Wikipedia):
```python
paragraphs = re.findall(r'<p>(.*?)</p>', html, re.DOTALL)
```

**Right** — find the section by anchor ID:
```python
m = re.search(r'id="Premise"', html)  # or id="Plot", id="Synopsis"
if m:
    chunk = html[m.start():m.start()+10000]
    text = re.sub(r'<[^>]+>', ' ', chunk)
    text = re.sub(r'\s+', ' ', text)
    text = re.sub(r'\[\d+\]', '', text)  # drop reference numbers
```

## Gotcha 2: The first "Plot" hit is the table-of-contents entry

Wikipedia pages have a sidebar TOC that lists every section with its
number. The TOC's text node for the Plot section reads literally:

```
Plot

 2
 Production

 3
 Media
```

So if you search `re.findall(r"\n\s*Plot\s*\n", text)` you get the TOC
hit, then 200 bytes of section numbers, and conclude "Wikipedia Plot is
empty."

**Detection rule:** after a heading match, inspect the next 1-3
non-empty lines. If the first one is just digits / `<3 chars / no
period`, it's the TOC — skip to the next match. Real Plot content
starts with prose ending in a period:

```python
def extract_real_section(text, heading, max_chars=10000):
    positions = [m.start() for m in re.finditer(rf"\n\s*{heading}\s*\n", text, re.IGNORECASE)]
    for pos in positions:
        after = text[pos:pos+400]
        non_empty = [l.strip() for l in after.split("\n") if l.strip()][:3]
        if len(non_empty) >= 2:
            second = non_empty[1]
            # TOC: second line is " 2 ", a digit, or a very short non-period token
            if second.isdigit() or (len(second) <= 3 and not second.endswith(".")):
                continue
        # Found real section. Cut at next major heading.
        end_m = re.search(
            r"\n\s*(Production|Media|Characters|Reception|See also|"
            r"References|Notes|Further reading|Anime|Manga|Light novel)\s*\n",
            text[pos+50:]
        )
        end = pos + 50 + end_m.start() if end_m else pos + max_chars
        return text[pos:end].strip()
    return None
```

## End-to-end script (copy-paste-runnable)

```python
import urllib.request, re, json, os

UA = "Mozilla/5.0"
PAGES = [
    ("Label", "https://en.wikipedia.org/wiki/<Slug>"),
    # ...
]

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    return urllib.request.urlopen(req, timeout=20).read().decode("utf-8", errors="ignore")

def strip(text):
    text = re.sub(r"<script[^>]*>.*?</script>", "", text, flags=re.DOTALL)
    text = re.sub(r"<style[^>]*>.*?</style>", "", text, flags=re.DOTALL)
    text = re.sub(r"<[^>]+>", "", text)
    text = (text.replace("&nbsp;", " ").replace("&amp;", "&")
                .replace("&quot;", '"').replace("&#039;", "'")
                .replace("&#39;", "'").replace("&lt;", "<").replace("&gt;", ">"))
    text = re.sub(r"\[\d+\]", "", text)
    text = re.sub(r"[ \t]+", " ", text)
    return text

# extract by Parsoid anchor first, fall back to TOC-aware heading match
def extract(html_or_text, heading, max_chars=10000):
    # Try anchor on raw HTML first (works on Parsoid)
    m = re.search(rf'id="{heading}"', html_or_text)
    if m:
        chunk = html_or_text[m.start():m.start()+max_chars]
        text = strip(chunk)
        return text[:max_chars]
    # Otherwise search stripped text with TOC skip
    text = strip(html_or_text)
    return extract_real_section(text, heading, max_chars)

# Usage
for label, url in PAGES:
    raw = get(url)
    sec = extract(raw, "Plot") or extract(raw, "Premise") or raw[5000:15000]
    print(f"=== {label} ===\n{sec[:6000]}\n")
```

## What you get out

For each series page, expect ~3-10 KB of cleaned Plot/Premise prose —
enough to summarize the inciting incident, the primary antagonist, and
the structural shape of the first arc. For multi-arc coverage (later
volumes, side characters, faction breakdowns) Wikipedia is **not**
sufficient and you must cite the actual source material — flag the gap
in the report rather than fabricate.

## Pitfalls specific to Wikipedia

- **Series often split into multiple articles**: e.g. `Frieren` (manga)
  vs `Frieren (TV series)` (anime). Pick the right one — usually the
  manga/LN page has the cleanest prose summary.
- **Page name redirects**: `Jobless_Reincarnation` → `Mushoku_Tensei`.
  Confirm via the `wgRedirectedFrom` field in the page metadata or by
  checking for "(Redirected from ...)" in the body.
- **Categorical pages with stubs**: many isekai titles get stub-class
  Wikipedia articles (e.g. "Plot section is one paragraph"). When you
  hit a stub, say so in the report's coverage-gaps section — don't
  invent antagonists.
- **Tables of contents use unicode bullets and numbering** — don't try
  to parse TOC structure; just skip past it.
