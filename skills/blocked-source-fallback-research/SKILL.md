---
name: blocked-source-fallback-research
version: 1.0.0
author: Hermes Agent
license: MIT
description: "Yelp/IG blocked — use vendor's .com + sitemap.xml instead."
tags: ["research", "fallback", "yelp", "instagram", "sitemap", "small-business"]
category: research
metadata:
  hermes:
    tags: ["research", "fallback", "yelp", "instagram", "sitemap", "small-business"]
    related_skills: ["grounded-citations", "vendor-webcheck-first", "duckduckgo-search"]
    fallback_for_toolsets: ["web"]
triggers:
  - "Yelp blocked"
  - "Instagram blocked"
  - "check this shop"
  - "do they make X"
  - "has vendor done Y"
  - "small business capability check"
provenance: "2026-08-17 LA-pet-cake vendor research (4 shops, all Yelp/IG/DDG blocked). Sitemap + .com fallback discovered the canonical-page trick (`cakeandart.com/animals` not `/animal-cakes`). Origin: Slack channel C0AMM2B4319, thread 1786947290.749289."
---

# Blocked-Source Fallback Research

## When to Use

Use when the aggregate web sources (Yelp, Instagram, Google, DDG HTML, Tavily) return
403 / captcha / login-walls, but you still need an answer about a vendor's product
or service capability. The **vendor's own `.com` + `sitemap.xml`** is the
authoritative non-blocked source.

## The blocking matrix (verified 2026-08-17)

| Source | `curl` with UA | `web_extract` |
|---|---|---|
| Yelp business page | 403 (anti-bot) | "Web tools not configured" |
| Instagram profile | 200 but JS-only, login-walled | "Web tools not configured" |
| DuckDuckGo HTML (`/html/`) | 202 + captcha | n/a |
| Google search (no cookie) | blocked | block varies |
| Tavily `web_search` | disabled (SOUL.md rule) | disabled |
| **Vendor's own `.com`** | usually 200 | usually 200 |
| **Vendor's `sitemap.xml`** | 200, every public URL | 200 |

## The fallback order

1. `curl -sSL -A "Mozilla/5.0" "<shop>.com"` — establishes the shop exists; gets nav text.
2. `curl -sSL "<shop>.com/sitemap.xml"` — discovers every public page slug.
3. For each sitemap URL, scrape and grep for the capability keywords your question asks about.
4. Report:
   - ✅ evidence found (page slug + title/caption text)
   - ❌ evidence absent (sitemap categories + the page content saying they do OTHER things)

## The sitemap-discoverability trick (load-bearing)

Vendor URL slugs frequently do NOT match the user-visible menu label. ALWAYS
pull `sitemap.xml` before guessing URLs. Verified conflict:

- Intuitive guess: `cakeandart.com/animal-cakes` → 404
- Sitemap reality: `cakeandart.com/animals` → 200, has the Animal Cakes gallery

Shopify splits large catalogs into timestamped sub-sitemaps with `?from=...&to=...`
query strings; the initial `sitemap.xml` only lists the sitemap *index*. Follow
each `<loc>` in the index to enumerate real product/page URLs.

## Extracting gallery titles from JS-rendered sites

When Wix/Squarespace/Elementor sites hide images behind JS, the **caption text**
still appears in static HTML. Captions are useful evidence, even if the image
URLs do not. Patterns:

```python
# Wix gallery titles
titles = re.findall(r'item-title[^>]*>(?:<[^>]+>)*([^<]+)<', raw_html)

# Generic alt-text scrape
alts = re.findall(r'<img[^>]+alt="([^"]+)"', raw_html)

# Shopify collection titles (often in <h1> or <h2>)
heads = re.findall(r'<h[12][^>]*>([^<]+)</h[12]>', raw_html)
```

## Evidence-tier language for the reply

When the fallback path produces only captions (not reviews/photos), use the
right tier words:

- ✅ "Vendor's portfolio page lists a 'Cheshire Cat Cake' (sourced from `deliciousarts.com/noveltycakes`)"
- ✅ "Vendor's nav has a dedicated 'Animal Cakes' category (`cakeandart.com/animals`)"
- ❌ "Yelp reviews mention cat cakes" — you didn't fetch Yelp; don't claim you did
- ❌ "The gallery shows cat cakes" — you may not have seen the images; only the captions are verifiable

## Pairs with

- `grounded-citations` — pair the sitemap + page URLs as evidence entries in the citations ledger
- `vendor-webcheck-first` — verify user-named artifacts at the source; this skill extends it for the "all paths blocked" sub-class
- `duckduckgo-search` — when DDG via the `ddgs` Python library is available (separate from the HTML scrape path that captcha-blocked)

## Anti-pattern — don't do this

- "Let me try a different IP / different User-Agent" — anti-bot blocks UA-rotated requests harder, not easier
- "Let me pay for a Yelp / Apify / Bright Data proxy" — out of scope; the shop's own site is the answer
- "Let me ask the user to screenshot the Yelp page" — violates `## COMMIT: self-service-only`; the shop's own site solves it
- "Let me retry Tavily" — Tavily is disabled (SOUL.md `research-integrity.md` rule)

## When to STOP and ask the user

If even the shop's own site is JS-only with no extractable caption text (rare —
happens with single-page Wix/Framer/Headless sites), say so explicitly and list
the contact info the user can DM/call. Don't fabricate "they have cat cakes" from
a domain-existence check.

## Worked example — 4-shop LA pet-cake check (2026-08-17)

Question: "Check these 4 LA bakeries — do any do cake with cats or pets?"

Blocked: Yelp (403), Instagram (login-walled), DuckDuckGo HTML (captcha).

Fell back to each shop's own site + sitemap:

| Shop | Cat/pet capability | Sources cited |
|---|---|---|
| Cake and Art (WeHo) | ✅ Dedicated `/animals` page | sitemap_index + animals page |
| Delicious Arts (Irvine/Pico) | ✅ "Cheshire Cat Cake" in novelty portfolio | sitemap_index + noveltycakes page |
| Sweet Angeles (Beverly Hills) | ❌ Kids = princess/unicorn/dinosaur only | sitemap_collections + kids-baby-cakes page |
| Ina Bakes (Venice) | ❌ Cookies + by-the-slice only, no sculpted cakes | product sitemap + custom page |

Every entry has TWO sources: the sitemap (structural) + the relevant page
(containing the actual evidence text). The reply's claims were grounded entirely
in the vendor's own site, with zero Yelp/IG claims.
