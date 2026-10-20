---
name: curl-sourced-research-reports
description: "Curl-sourced synthesis tables when Tavily is disabled."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [Research, Citations, Fallback, Curl, Wikipedia, Tavily]
    category: research
    related_skills: [grounded-citations, duckduckgo-search, claim-verification]
---

# Curl-Sourced Research Reports

Use when both `web_search` and `web_extract` are explicitly disabled or
rate-limited (Tavily backend off, sandbox block, key rotation pending) and
the task still requires evidence-anchored prose: a research report,
comparison, or pattern-mining deliverable that must *cite* primary sources.

The skill covers the full pipeline: bulk `curl` fetch → HTML strip →
axis-keyword paragraph scoring → synthesis table → row-level citation
verification. It does **not** replace `grounded-citations` — it is the
*provenance-anchored fallback* when the Tavily-backed retrieval pipeline is
off, so the same citation discipline still holds.

## When to Use

- Tavily / `web_search` / `web_extract` tools are unavailable and you must
  use `curl` for retrieval (per task brief or environment).
- The deliverable is a written synthesis with cited URLs (Markdown report,
  comparison table, trope-mining writeup, source-anchored brief).
- The sources are stable URLs (Wikipedia, official publisher pages, arXiv,
  project sites) that render fine as raw HTML — *not* pages that require
  JavaScript rendering.

## When NOT to Use

- A single URL needs deep extraction → use `browser_exec` instead.
  See `references/browser-exec-extraction-fallback.md` for the canonical
  recipe (browser_exec Python block + `js("document.body.innerText")` +
  in-block regex), domain-specific patterns (MyDramaList cast lookup
  `/<id>-<slug>/cast`), and a worked example.
- The citation discipline matters but Tavily is up → use
  `grounded-citations` directly; the `sources.py` ledger is stronger than
  this skill's table-shape check.
- The deliverable is an academic paper needing BibTeX → use
  `research-paper-writing` (which `grounded-citations` feeds).

## Quick Reference

| Action | Command |
|---|---|
| Bulk fetch N pages | `scripts/fetch_pages.sh <url1> <url2> ...` |
| Strip + score + chunk | `scripts/score_paragraphs.py /tmp/wiki_*.html` |
| Verify pattern-table citation density | `scripts/verify_pattern_table.py report.md` |
| Wikipedia (Parsoid HTML) extraction | `references/wikipedia-parsoid-extraction.md` |

## Procedure

① **Confirm the disable.** Check the task brief or system prompt for
"Tavily disabled", "skip web_search", "no web_extract". Don't assume from
silence — Tavily is the default, and switching to `curl` loses snippet-based
discovery (you go from "I know which URL I need" to "I have to know the URL
slug in advance"). If Tavily is up, prefer it.

② **Read the target document first, if there is one.** A "How to apply"
column should be specific callbacks into the target artifact (campaign
bible, design doc, prior report), not generic restatement. Re-reading the
target before writing prose turns the table from a survey into a critique.

③ **Bulk-fetch with `curl`** — one request per source, distinct
User-Agent, status check, save to `/tmp`:
```bash
curl -sL --max-time 25 \
  -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
  "https://en.wikipedia.org/wiki/<Slug>" -o /tmp/wiki_<slug>.html
```
Track status codes and file sizes; a 200 with a 2KB body is likely a redirect
or disambig page — re-fetch with the full slug.

④ **Strip + score + chunk** via `scripts/score_paragraphs.py`. This drops
`<script>`/`<style>`/`<sup>`/tables/figures, splits paragraphs, scores by
axis keywords (`inciting incident`, `magic school`, `guilt`, `demon`, etc.),
keeps the top N by score, writes one `.txt` per source. The script's axes
list is configurable — tune it to the task.

⑤ **Read the text chunks, not the HTML.** This is the discipline point. You
*cite-as-you-read*, which keeps the "register after writing" failure mode
out of the pipeline.

⑥ **Draft the synthesis table.** For each source, ask: what is the *one*
concrete pattern that earns its citation? Don't restate the plot — extract
the *pattern* the row needs. A 12-row table with 18 unique URLs beats a
25-row table with 8 unique URLs every time.

⑦ **Verify before delivery.** Run `scripts/verify_pattern_table.py <draft>`:
- Every numbered row has ≥ 1 URL on its source line(s).
- Unique URL count ≥ row count.
- At least one row pulls from a second source family (catches URL typos
  where two rows cite the same slug).
Exit 0 means ship; exit 1 means fix. Also state the retrieval method under a
**Method** section so the reader knows the evidence chain.

## Pitfalls

- **Fetching into the working tree.** `/tmp/wiki_*.html` is scratch; do not
  pollute the user's repo. The agent cannot `trash` a file the user can see.
- **Default `User-Agent: curl/8.x`.** Wikipedia serves fine but some sites
  block it. Always set a desktop UA.
- **Reading HTML instead of the chunks.** The whole reason for step ④ is to
  force the citation discipline. Skipping it collapses back to "answer from
  memory."
- **Verifying after delivering.** Run `verify_pattern_table.py` *before*
  writing the closing summary, not after. A miss caught late is a wasted
  table.
- **Confusing "table-shape verify" with `sources.py verify`.** This skill
  covers `| # | Pattern | Source | … |` tables and only checks URL
  presence per row. Per-sentence `[n]` citation hygiene still requires
  `grounded-citations` / `sources.py`.
- **One URL per page slug.** A 200 with a body that says "Redirected from
  FOO" is the wrong page; re-slug and re-fetch.
- **Wikipedia Parsoid output.** Modern Wikipedia serves HTML via the
  Parsoid pipeline — the article body is NOT wrapped in plain `<p>` tags.
  `re.findall(r'<p>(.*?)</p>', html)` returns 0 matches and the agent
  concludes "no content." Fix: find section anchors via `id="<Heading>"`
  (e.g. `id="Premise"`, `id="Plot"`) and grab the next ~10KB, then
  strip tags with `re.sub(r'<[^>]+>', ' ', chunk)`. See
  `references/wikipedia-parsoid-extraction.md` for the full recipe and
  TOC-vs-content detection logic.
- **TOC masquerades as the section.** The first `Plot` or `Premise` match
  on a Wikipedia page is almost always the table-of-contents entry,
  followed by a single-digit section number on the next line — NOT the
  actual section content. Detect: after a `\n{Heading}\n` match, look at
  the next non-empty line. If it is ` 2 ` / ` 3 ` / `<digit>` / `<3 chars
  with no period>`, skip and look for the next match. Real Plot prose
  starts with a sentence ending in a period.
- **Inventing the source path.** If the task says "Wikipedia summaries,
  MyAnimeList, official sites" — those are the three families. Don't slip
  in an unsourced `fandom.com` URL.

## Verification

```bash
python scripts/verify_pattern_table.py /tmp/<report>.md
echo "exit=$?"   # 0 = ship
```

The script prints row count, unique URL count, URLs-per-row table, and
which rows fail. Wire into a pre-delivery checklist.

## Delegating to Other Skills

- **Per-sentence citations and Sources block** → pair with
  `grounded-citations`. The table-shape check is *row-level*; the inline
  `[n]` discipline is *sentence-level*.
- **Cross-checking disputed claims** → `claim-verification` provides the
  quote-and-compare framework.
- **Search was actually fine** → drop this skill and use Tavily
  + `grounded-citations` directly.
