---
name: claim-verification
description: Verify external citations against primary sources.
---

# Claim Verification

User gives you a document and a list of external claims to verify. Return a structured verdict citing primary sources. Common shape: VERDICT / REASONING / MAIN CAVEAT / CONFIDENCE / SOURCES.

## Methodology (5 phases)

### Phase 0 — Premise check (do this FIRST)

Before chasing external verification, **grep the source document for each claim's key terms**. If a claim is not actually in the source, say so in the verdict. The user may have conflated documents, be testing your honesty, or the task prompt may have drifted from the artifact.

Example: user asks to verify 'Shapiro's Feb essay describes the 5-level ladder'. Open the essay — does it actually contain the ladder? If the ladder is in a *different* post (Jan), report that. Do not invent a connection.

### Phase 1 — Tool selection

In priority order:

1. **Managed web tools** (`web_search`, `web_extract`) — fast, indexed, summarized.
   - If they error with 'Web tools are not configured' (FIRECRAWL_API_KEY missing), skip immediately to (2).
2. **Direct HTTP via `curl`** with a desktop User-Agent. Always capture:
   - Final URL after redirects (`-w "%{url_effective}"`)
   - HTTP code (`-w "%{http_code}"`)
   - Bytes downloaded (`-w "%{size_download}"`)
   - **200 does not equal real content** — many services return 200 with placeholder body. Always grep the title and a substantive excerpt.
3. **Wayback Machine** for Cloudflare-blocked sources (medium.com, substack behind paywall, etc.):
   - Check availability: `curl 'http://archive.org/wayback/available?url=<encoded_url>'`
   - Fetch via captured timestamp: `curl 'https://web.archive.org/web/<TIMESTAMP>/<URL>'`
4. **Browser** as last resort (`browser_navigate`). Useful for JS-heavy pages; will still hit Cloudflare on Medium. Snapshot tells you immediately if blocked.

### Phase 2 — Domain-specific verification

For `github.com/<owner>/<repo>` claims:
- Existence check: `curl -o /dev/null -w '%{http_code}' https://github.com/<owner>/<repo>`
- Bypass HTML for raw content: `curl https://raw.githubusercontent.com/<owner>/<repo>/main/README.md`
- Check sibling repos separately (e.g., `strongdm/attractor` vs `strongdm/attractorbench`) — the spec repo and benchmark repo often differ.

For provider-API quirks (headers, params, models):
- Pull **current** provider docs, not blog posts from N years ago.
- Note canonical header vs. alias. Example: OpenRouter `X-OpenRouter-Title` is canonical; `X-Title` is legacy alias still accepted. Older blog posts cite only the alias.

For status / disablement claims:
- Status page + history feed (`status.<service>.com/`, `/history.atom`).
- 100% uptime across the alleged window = suspect — could be local/account, not vendor-side.
- Disambiguate 'vendor disabled it' from 'I disabled it locally'.

For chronology claims (post A, post B, related):
- Open each cited source. Title drift in URLs is common: the 'intuitive' slug may 404 while a slightly different slug works. If the title is known, search related-post sidebars rather than guessing the slug.

For amenity / existence claims on booking sites (Airbnb, Booking.com, hotel chains):
- **Hotel chain sites** (Locke, Staycity, etc.): often Cloudflare-bot-blocked for curl (403). Don't fight it — pivot to Booking.com's mirror, which is canonical and JS-renders cleanly.
- **Booking.com**: page is JS-rendered — curl returns a 3.8KB shell. Use `browser_navigate` (headless). Amenity list is visible in the initial snapshot; description paragraph holds the marketing copy with the same keyword.
- **Airbnb**: the **first-10 amenities trap** — UI shows only 10 amenities + a "Show all N amenities" button. AC is often NOT in the first 10. Always click "Show all N amenities" to expand.
- **Defense-in-depth** after expanding: run `browser_console(expression="document.body.innerText.includes('Air conditioning')")` to confirm the keyword is in the **fully rendered DOM**. Returns boolean — easy to assert.
- **Distinguish AC classes** in the final report: ducted AC / mini-split / portable AC / "heating only" — common gotcha in Irish/UK listings where "central heating" implies nothing about cooling.
- **Trust hierarchy** (most → least reliable): Booking.com amenity list > hotel official site > Airbnb listing description > Airbnb listing title.

### Phase 3 — Verdict output (required shape)

```
VERDICT: <one-sentence consensus>
REASONING: <3-4 sentences citing primary sources>
MAIN CAVEAT: <one sentence on biggest remaining uncertainty>
CONFIDENCE: <high / medium / low with justification>
SOURCES: <5-8 URLs with verification status>
```

Per-URL status legend:
- Real and matches claim
- Real but claim mischaracterized (e.g., title right, body says opposite of what claim asserts)
- Real source contradicts claim
- Stale URL (redirects to wrong place) or 404
- Cloudflare-blocked, only verifiable via Wayback

### Phase 4 — Output discipline

- Verdict goes FIRST, before detailed reasoning. The user wants the bottom line.
- Each URL in SOURCES gets a one-line status so the user can scan without re-reading.
- If you cannot verify a claim, say so explicitly in MAIN CAVEAT. Inventing a confident answer is the worst failure mode.

## When invoked from `/advice` (dispatcher-side contract)

If you're a subagent receiving a `/advice` Reviewer-B prompt that asks to verify external citations against an artifact:

1. **Load this skill first** (`skill_view(name='claim-verification')`). Do not rely on the dispatcher prompt alone — it often misses the premise-check guard.
2. **Phase 0 first, every time.** Open the artifact, grep for the claim's key terms. If the claim is not in the source, report absence in the verdict BEFORE chasing external verification.
3. **Surface "only N of M claims are in the artifact"** as a top-line finding — not buried in reasoning. The user needs to know whether the review prompt drifted from the artifact.
4. **Verify only the claims actually in the doc.** Do not verify "what the dispatcher's wide-claim list contained" — that fabricates phantom citations.

**Bug-ref 2026-08-06 (roadmap-ai-coding-advice-2026-08-06 review):** The dispatcher prompt listed 6 external claims (AttractorBench / Shapiro essay / 2389.ai / Yegge ZFC / Tavily disabled / OpenRouter attribution). Four of those six were not present anywhere in the artifact (the doc cited only Tavily + OpenRouter internally). Verifying the absent claims manufactured a "looks-sourced-from-the-doc" appearance that the doc never earned. The Phase 0 check correctly caught this; the lesson is to **make Phase 0 mandatory, not advisory**, especially when the artifact is a long internal roll-up and the claim list was assembled from memory of the topic, not from grepping the source.

---

## Pitfalls

- **Premise mismatch**: claims not in the source document — surface this BEFORE chasing external verification. This is the most common failure mode when the user gives you a list detached from the artifact.
- **200 is not success**: `curl` returning 200 with the right title does not mean the page says what the claim says. Grep the body for a substantive excerpt that matches (or doesn't) the claim.
- **Title drift in URLs**: `...-to-the-dark-factory/` 404s while `...-to-the-software-factory/` works (real example from this skill's birth). If the title is known, search the source for related-post links rather than guessing the slug.
- **URL redirects**: `/posts/foo/` → `/research/writing/foo/` (real example: 2389.ai). Always follow redirects and report the final URL in SOURCES.
- **Cloudflare 403 on Medium and friends**: direct curl returns 403. Wayback is the canonical fallback — do not waste time on browser stealth tricks. The Wayback snapshot timestamp itself is a fact to cite.
- **Bot-blocked hotel site ≠ AC-blocked**: chain sites (Locke, Staycity, etc.) often return 403 to curl. Pivot to Booking.com mirror — do NOT conclude "no AC" from a 403.
- **Airbnb first-10 amenities trap**: UI shows only 10 amenities before the "Show all N amenities" button. AC may be in the gated list. Always expand, then verify with `page.innerText.includes()`.
- **Heating ≠ cooling**: Irish/UK listings often note "central heating" but say nothing about AC. Both must be asserted separately.
- **Alias vs canonical headers**: providers evolve. `X-Title` may still work as alias but `X-OpenRouter-Title` is now canonical. Quote the current docs, not a 2-year-old blog post.
- **Local vs vendor 'disabled'**: 'Tavily disabled 2026-06-30' with a clean status page = local account state, not a vendor outage. Disambiguate by reading status-page data for the alleged window.
- **Sibling repos conflated**: spec repo vs benchmark repo vs runner repo often share a name root. Check each.
- **Wayback-as-fact**: When you cite a Wayback capture, cite the timestamp. Captures drift across versions.

## Reusable scripts

Put under `scripts/` of this skill when packaging:
- `fetch_and_extract.py` — `curl`-based extractor that strips script/style/head/nav/footer, decodes HTML entities, collapses whitespace. Output is grep-friendly.
- `wayback_check.sh` — `archive.org/wayback/available?url=...` → emits the closest-capture URL or 'no archive'.

## Reference files

- `references/verified-claims-2026-08-06.md` — concrete worked example: StrongDM/Attractor/Shapiro/2389/Yegge/OpenRouter/Tavily verification run from this skill's birth session.
- `references/verify-booking-airbnb-amenity-2026-08-10.md` — Dublin AC audit: 8 listings (3 aparthotels + 5 Airbnbs), tool-chain ordering, Airbnb "first-10 amenities" trap, browser_console fingerprint trick, OTA trust hierarchy. 1 of 8 listings mislabeled because of this trap.
