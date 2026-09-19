# Verified Booking/Airbnb Amenity Claims — 2026-08-10 Dublin AC audit

Source task: "Review all these options and find proof there is real AC" — user pasted a list of 8 Dublin lodging URLs (aparthotels + Airbnb listings) and asked the agent to verify each has real AC.

This is a worked example of **amenity/existence claim verification on booking sites** — a sub-class of claim-verification that has its own quirks vs. verifying prose claims about blog posts or papers.

## The 8 listings and outcomes

| # | Listing | URL | Site | Method | AC proof (verbatim) | Verdict |
|---|---|---|---|---|---|---|
| 1 | Zanzibar Locke | `lockeliving.com/en/dublin/zanzibar-locke` | Official | curl (initial, no AC found) + Booking.com (canonical) | Booking.com description: *"Zanzibar Locke in Dublin offers 4-star comfort with **air-conditioned rooms**"* | ✅ Real AC |
| 2 | Beckett Locke | `lockeliving.com/en/dublin/beckett-locke` | Official | curl | Official suite list: *"**Air conditioning** with heating"* | ✅ Real AC |
| 3 | Staycity Dublin City Centre | `staycity.com/dublin/city-centre` | Official | curl returned 403; Booking.com fallback | Booking.com amenity list: *"**Air conditioning**"* + description: *"Each unit includes **air-conditioning**"* | ✅ Real AC |
| 4 | Locke Studio at Zanzibar Locke (Airbnb) | `airbnb.com/rooms/46256758` | Airbnb | browser_navigate + browser_scroll | Amenity list (visible): *"**Air conditioning**"* + description: *"all the Locke perks, including **air-conditioning**"* | ✅ Real AC |
| 5 | Large Luxury Penthouse (Airbnb) | `airbnb.com/rooms/6290081` | Airbnb | browser_navigate | Amenity list: *"**Portable air conditioning**"* | ✅ Portable AC (note: weaker than ducted) |
| 6 | Peaceful Retreat (Airbnb) | `airbnb.com/rooms/1571389763229509884` | Airbnb | browser_navigate + browser_click "Show all 59 amenities" + browser_console.expression | `document.body.innerText.includes('Air conditioning')` returned **false** | 🔴 **NO AC — mislabeled** |
| 7 | Modern 3BD Split-Level Dublin 16 (Airbnb) | `airbnb.com/rooms/1512368039719725932` | Airbnb | browser_navigate | Amenity list: *"**Air conditioning**"* + description: *"Central heating and **portable A/C unit** ensure year-round comfort"* | ✅ Portable A/C |
| 8 | Dublin 1 Large Studio (Airbnb) | `airbnb.com/rooms/1005108060930897562` | Airbnb | browser_navigate | Amenity list: *"**Air conditioning**"* + description: *"The studio has a seriously good **air conditioning system which is both ducted and temperature controlled**"* | ✅ Ducted AC |

## Tool chain that worked + ordering

### Tier 1 — curl (fastest, fails on JS-rendered or bot-blocked)

```bash
curl -fsSL -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36" \
  <URL> | python3 -c "
import sys, re
body = sys.stdin.read()
text = re.sub(r'<script.*?</script>', '', body, flags=re.DOTALL|re.IGNORECASE)
text = re.sub(r'<style.*?</style>',    '', text, flags=re.DOTALL|re.IGNORECASE)
text = re.sub(r'<[^>]+>',              ' ', text)
text = re.sub(r'\s+',                  ' ', text)
for kw in ['air conditioning', 'air-conditioning', 'air con', 'AC']:
    for m in re.finditer(re.escape(kw), text, re.IGNORECASE):
        s = max(0, m.start()-100); e = min(len(text), m.end()+100)
        print(f'[{kw}] ...{text[s:e]}...')
"
```

**Fallback for bot-blocked sites** (Staycity returned 403, Cloudflare-blocked):

```bash
# Don't waste time on browser stealth for Cloudflare-blocked hotel sites — go straight to Booking.com mirror
curl -fsSL -A "Mozilla/5.0 ..." "https://www.booking.com/hotel/ie/<slug>.html" | python3 <extractor>
```

**Why Booking.com is the canonical neutral source**:
- Has both the hotel description AND the canonical amenity list
- Lists amenities with normalized terms (e.g. "**Air conditioning**" with a space, not "aircon")
- JS-rendered, requires browser_navigate (curl returns a 3.8KB shell)
- Same brand description mirrored across thousands of OTA scrapers, so cross-check is trivial

### Tier 2 — browser_navigate for JS-rendered pages (Airbnb, Booking.com)

Airbnb amenity lists are **partially visible** — the first 10 amenities are shown, then a "Show all N amenities" button gates the rest. This is critical: **AC may not be in the first 10, even when present.** Workflow:

1. `browser_navigate(<airbnb_url>)` — loads page, snapshot has top metadata
2. `browser_scroll(direction='down')` — reveals the amenities section
3. `browser_snapshot(full=true)` — read the visible amenity list
4. If "Show all N amenities" button exists, **`browser_click` it** to expand the full list
5. **Defense-in-depth**: after expanding, run `browser_console(expression="document.body.innerText.includes('Air conditioning')")` to confirm the keyword is actually in the **full rendered body**, not just the visible scroll position

```javascript
// The killer check — proves the keyword is present after JS hydration
document.body.innerText.includes('Air conditioning')
// or for case-insensitive:
document.body.innerText.toLowerCase().includes('air conditioning')
```

For Booking.com, the amenity list is visible in the initial snapshot (no expand needed).

### Tier 3 — Wayback for persistent bot blocks

For hotel sites Cloudflare-blocks persistently (Medium, Substack, some OTAs), curl `archive.org/wayback/available?url=<URL>` first, then fetch via `https://web.archive.org/web/<TS>/<URL>`.

## Critical patterns that emerged

### 1. "Initial 10 amenities" trap on Airbnb

Airbnb's UI shows the FIRST 10 amenities, then a "Show all N amenities" button. AC is often NOT in the first 10 even when present. **Always click "Show all N amenities" and re-check.** The Peaceful Retreat listing had 59 amenities and AC was NOT among them — but I had to expand to confirm.

### 2. The browser_console.expression fingerprint trick

Even after expanding amenities, the safest verification is `document.body.innerText.includes('<keyword>')` — this confirms the keyword is in the **fully rendered DOM**, not just the visible scroll. Useful for: amenities, "About this space" sections, host names, review counts, prices. Returns boolean — easy to assert.

### 3. Title-on-page ≠ claim-on-page

Booking.com Zanzibar Locke had no AC keyword on the initial overview — `body.innerText` matched "Locke" 93 times but "air conditioning" 0 times. The keyword was in the **property description** (rendered as a single paragraph), not in the quick facts. Grep the whole body, not just section headers.

### 4. Hotel chain sites: missing amenities on landing pages

Locke's official site does NOT list amenities on the hotel landing page — only on individual apartment-type subpages (e.g. `/locke-studio`). The booking.com mirror is easier and more reliable. Strip-Locke page had the description parser-detect "Air conditioning" in apartment specs; Zanzibar-Locke didn't, because the landing page doesn't enumerate specs.

### 5. Cross-verification matrix

When a listing is hotel-branded and also has a Booking.com URL, **always verify BOTH**:
- Hotel official site = marketing copy (may lie)
- Booking.com amenity list = OTA-canonicalized (rarely lies, but 3rd-party-listed)
- Airbnb amenity list = host-asserted + Superhost vetting (rarely lies on Superhost listings)

If 2 of 3 agree on AC, high confidence. If only 1 of 3, flag as suspect.

### 6. "Portable AC" vs "ducted AC" vs "AC"

Distinguish three classes in the final report — they differ dramatically in cooling performance:
- **Ducted AC** — central HVAC, cools the whole unit. Real AC.
- **"Air conditioning"** (no qualifier) — usually means a mini-split or wall AC. Real.
- **"Portable air conditioning"** — single unit, 1–2 rooms, weak. Real but limited.
- **"Heating" only** — explicit absence of AC. Common gotcha in Irish listings.

In the Dublin-8 listing, the description said "Heating throughout" and the full 59-amenity list had no AC entry. **Do not assume heating implies cooling.**

## Final report shape (sent to user)

A compact table with one row per listing, four columns:
- URL (clickable)
- AC proof (verbatim quote from the page)
- Verdict (✅ / 🔴 + caveat)
- Type of AC (ducted / mini-split / portable)

Plus a one-line summary: "N of M confirmed; listing X was mislabeled."

## Pitfalls (carry these into the SKILL.md body)

- **The first-10 trap on Airbnb**: always expand to full amenity list, then `body.innerText.includes()` the keyword.
- **Bot-blocked ≠ AC-blocked**: when a hotel site returns 403 to curl, do NOT conclude "no AC" — pivot to Booking.com (or another OTA) for the canonical amenity list.
- **OTA descriptions often paraphrase**: "air-conditioned rooms" vs "air conditioning" vs "Air conditioning" — grep case-insensitively and remember the hyphen.
- **Heating ≠ cooling**: an Irish listing that mentions "central heating" says nothing about AC. Both must be asserted separately.
- **Trust hierarchy** (most → least reliable): Booking.com amenity list > hotel official site > Airbnb listing description > Airbnb listing title.
