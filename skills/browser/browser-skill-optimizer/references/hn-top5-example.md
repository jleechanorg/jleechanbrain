# Example: Hacker News Top 5 Extractor

## Baseline Run (click-by-click)

**Approach:** Navigate to HN, take `browser_snapshot(full=true)`, manually parse the accessibility tree text to extract titles, points, and comments.

**Turns:** 2 (`browser_navigate` + `browser_snapshot`)
**Time:** ~3 seconds
**Tokens:** ~4K input (large snapshot) + ~1K output
**Fragility:** HIGH — parsing accessibility tree text depends on snapshot formatting, which changes with page structure

## Optimized Run (JS eval)

**Approach:** Navigate to HN, use `browser_console` with a single JS expression that queries the DOM directly and returns structured JSON.

**Turns:** 2 (`browser_navigate` + `browser_console`)
**Time:** ~2 seconds
**Tokens:** ~1K input + ~500 output
**Fragility:** MEDIUM — DOM selectors can break if HN changes HTML structure, but far more stable than snapshot parsing

### JS Eval Code

```javascript
(() => {
  const rows = document.querySelectorAll('tr.athing');
  const out = [];
  rows.forEach((row, i) => {
    if (i >= 5) return;
    const titleLink = row.querySelector('span.titleline > a');
    const siteEl = row.querySelector('span.sitebit > a');
    const subRow = row.nextElementSibling;
    const scoreEl = subRow ? subRow.querySelector('.score') : null;
    const commentLinks = subRow ? subRow.querySelectorAll('a') : [];
    const lastLink = commentLinks.length > 0 ? commentLinks[commentLinks.length - 1].textContent : '';
    out.push({
      rank: i + 1,
      title: titleLink ? titleLink.textContent : '',
      site: siteEl ? siteEl.textContent : '',
      points: scoreEl ? scoreEl.textContent : '0',
      comments: lastLink
    });
  });
  return JSON.stringify(out, null, 2);
})()
```

### Output

```json
[
  {"rank": 1, "title": "Google broke reCAPTCHA for de-googled Android users", "site": "reclaimthenet.org", "points": "453 points", "comments": "152 comments"},
  {"rank": 2, "title": "Tesla Model Y Passes NHTSA's New 'Advanced Driver Assistance System' Tests", "site": "nhtsa.gov", "points": "10 points", "comments": "discuss"},
  {"rank": 3, "title": "AWS data center outage hits trading on Fanduel, Coinbase", "site": "cnbc.com", "points": "37 points", "comments": "9 comments"},
  {"rank": 4, "title": "You gave me a u32. I gave you root. (io_uring ZCRX freelist LPE)", "site": "ze3tar.github.io", "points": "107 points", "comments": "67 comments"},
  {"rank": 5, "title": "AI is breaking two vulnerability cultures", "site": "jefftk.com", "points": "196 points", "comments": "83 comments"}
]
```

## Selector Stability

| Element | Selector | Stability | Notes |
|---------|----------|-----------|-------|
| Story row | `tr.athing` | HIGH | HN has used this class for 15+ years |
| Title link | `span.titleline > a` | MEDIUM | Changed from `.storylink` to `.titleline` recently |
| Site name | `span.sitebit > a` | HIGH | Stable class |
| Score | `.score` | HIGH | Very stable |
| Comments link | Last `a` in subtext row | MEDIUM | Position-based, could break if HN adds links |

## Key Lesson

For data extraction tasks, JS eval wins over snapshot parsing because:
1. **Structured output** — JSON instead of text scraping
2. **Smaller context** — 500 chars vs 4K+ chars of snapshot
3. **More reliable** — DOM queries > accessibility tree text parsing
4. **Composable** — can add filtering, sorting, pagination in the same eval

But for tasks requiring visual understanding (is this button visible? does this layout look right?), snapshots remain necessary.
