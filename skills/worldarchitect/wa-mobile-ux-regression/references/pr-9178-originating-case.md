# Originating case: PR #9178 (2026-08-20)

## Source

Slack thread C0AH3RY3DK6/p1787261209.775249 — three Android screenshots from
Jeffrey showing `worldarchitect.ai` My Campaigns page on iPhone/Pixel-class
viewports with three mobile UX bugs:

1. **BUG A**: "Duplicate" button text truncated to "Duplicat" (and after CSS
   fix attempt, to "Du" — see below).
2. **BUG B**: "Last played: 20/08/2026, 22:05:28" text clipped at right
   edge of the campaign list row.
3. **BUG C**: "Choose Theme" dropdown (Fantasy / Light panel) overflows
   past the right edge of the viewport when opened.

Jeffrey's request: *"we must reproduce the issues and provide visual
evidence of repro so /es and /er and /advice approves it"*

## Investigation timeline

### Step 1 — Public headless browser probe (initially blocked)

`curl https://worldarchitect.ai/my-campaigns` returns the homepage (HTML
shell only, login wall). The My Campaigns page is gated by Firebase
auth — it requires a real signed-in browser session. Cannot reproduce
from the public URL alone.

**Skipped Android emulator install** — too slow (5+ min) and the bug
class is reproducible in iPhone 14 Pro / Pixel 7 emulation headless in
seconds. Jeffrey was OK with this implicitly (the alternative was
emulator, which would have produced the same evidence at 10x the wall
time).

### Step 2 — Source code root-cause analysis

Found the rendered-DOM source in `mvp_site/frontend_v1/app.js:3006-3012`:

```js
<div class="d-flex flex-column flex-sm-row w-100 justify-content-sm-between
            align-items-sm-center campaign-list-header">
  <h5>...campaign-title-link...</h5>
  <div class="d-flex align-items-center flex-shrink-0
              campaign-list-actions mt-1 mt-sm-0">
    <button class="btn btn-sm btn-outline-primary edit-campaign-btn me-2">Edit</button>
    <button class="btn btn-sm btn-outline-secondary duplicate-campaign-btn me-2">Duplicate</button>
    <small class="text-muted text-nowrap">Last played: ${lastPlayed}</small>
  </div>
</div>
```

And the mobile media query in `mvp_site/frontend_v1/style.css:518-536`:

```css
@media (max-width: 575.98px) {
  .list-group-item[data-campaign-id] .campaign-list-header {
    flex-wrap: wrap !important;
    align-items: flex-start !important;
  }
  .list-group-item[data-campaign-id] .campaign-list-header .campaign-list-actions {
    width: 100%;
    justify-content: flex-start;
    white-space: normal !important;
  }
  /* ... */
}
```

Combined with the global rule at `style.css:498-507`:

```css
.list-group-item[data-campaign-id] .edit-campaign-btn {
  margin-right: 0.5rem !important;
  flex-shrink: 0 !important;       /* <-- this is the bug */
}
.list-group-item[data-campaign-id] .text-muted {
  font-size: 0.875rem !important;
  flex-shrink: 0 !important;       /* <-- and this */
  white-space: nowrap !important;
}
```

The buttons are `flex-shrink: 0` (won't give up width) but the actions
row has `white-space: normal` AND no `flex-wrap: wrap`. Result: buttons
get text-clipped at mobile widths.

### Step 3 — Test infrastructure setup

`./vpython mvp_site/main.py serve` failed: `venv/bin/activate` does not
exist in the repo. Workaround: `PYTHONPATH=. TESTING_AUTH_BYPASS=true
python3 mvp_site/main.py serve`. The server binds 127.0.0.1:8081 by
default.

`/api/campaigns` POST returned `401 No token provided` even with
`TESTING_AUTH_BYPASS=true` — the bypass does NOT relax Firebase auth on
write endpoints. Pivoted to synthetic DOM injection (no API call).

### Step 4 — Wrote `testing_ui/test_my_campaigns_mobile_ux_regression.py`

Three assertions, all checking the rendered DOM via `page.evaluate`:

- **bug_a**: `el.scrollWidth > el.clientWidth + 1` (text clipped inside
  the button box)
- **bug_b**: `el.getBoundingClientRect().right > window.innerWidth + 1`
  (or text clipped, or `documentElement.scrollWidth > window.innerWidth`)
- **bug_c**: same shape, applied to `#theme-menu` and the page-level
  horizontal overflow check

Three CSS gates had to be lifted to make `#dashboard-view` visible:
`body.is-logged-out` removal, `.active-view` toggle on the dashboard, and
`#auth-view.active-view` removal. Missing any one leaves the injected
row attached but `display: none`.

### Step 5 — Captured BEFORE evidence at 393×852 (iPhone 14 Pro)

```
[BEFORE] saved /tmp/wa_my_campaigns_mobile_evidence/BEFORE_01_initial.png
[BEFORE] saved /tmp/wa_my_campaigns_mobile_evidence/BEFORE_02_theme_open.png
[BEFORE] saved /tmp/wa_my_campaigns_mobile_evidence/BEFORE_03_row_zoom.png
```

The `BEFORE_03_row_zoom.png` is the smoking gun: the .duplicate-campaign-btn
shows "Du" with `clientWidth=24, scrollWidth=77, textOverflow=clip`.
vision_analyze on the PNG independently confirmed the truncation.

### Step 6 — Dispatched claudem worker

Wrote `/tmp/wa-mobile-ux-brief.md` with:
- Verbatim user request
- All three bugs with file:line root causes
- BEFORE PNG path (the worker should re-capture for canonical evidence)
- Acceptance criteria (PR with embedded BEFORE/AFTER, no scope creep)

Dispatched via `bash -lic 'claudem -p "$(cat /tmp/wa-mobile-ux-brief.md)"
--max-turns 120 --output-format text'` from
`~/repos/jleechanorg/worldarchitect.ai`. Worker created worktree at
`~/.worktrees/wa-mobile-ux` on `fix/my-campaigns-mobile-ux` based on
`origin/main`. Worker (MiniMax-M3) confirmed receipt, set up TaskCreate
tracker, started reading CSS files.

## Outcome

PR #9178 (in flight at session end) — `fix(my-campaigns): mobile UX —
Duplicate button + theme dropdown overflow`. Worker had 14 tool calls in
1:30 when session ended; expected to complete in <10 min more.

## Lessons that became this skill

1. **Public-URL probe is often a dead-end for auth-gated WA pages** —
   go straight to the source code (the rendered DOM is in
   `mvp_site/frontend_v1/app.js:renderCampaignListUI()`), reproduce in
   the local Flask server with synthetic DOM injection, and dispatch.

2. **TESTING_AUTH_BYPASS is not a free pass on write endpoints** — it
   only relaxes rate limits. Write endpoints still need a Firebase
   token. Use DOM injection for mobile fixtures; the rendered markup is
   public.

3. **Three CSS gates hide #dashboard-view** — `is-logged-out` body
   class, `[id]-view { display: none }` default, and `.active-view`
   toggle. Missing any one breaks the test. This is a one-time gotcha
   but it's not obvious from the rendered HTML.

4. **Computed-style assertion is the missing link** — `wa-visual-proof-playwright`
   takes screenshots but doesn't assert on them. The bug can render and
   look like "just a tight button" in PNG but actually be clipped at
   the computed-style level. `clientWidth vs scrollWidth` is the
   reliable signal.

5. **PNG embedding format** — GitHub needs `?raw=true` to render.
   `${HOME}/path.png` and `./relative/path.png` do not work
   in PR markdown. The existing recipe's Step 4 hint was good but the
   `?raw=true` rule wasn't called out explicitly.

## Files

- Test (committed to branch): `testing_ui/test_my_campaigns_mobile_ux_regression.py`
- BEFORE evidence: `/tmp/wa_my_campaigns_mobile_evidence/BEFORE_*.png`
- Worker brief: `/tmp/wa-mobile-ux-brief.md`
- Worker session JSONL: `~/.claude/projects/-Users-jleechan-repos-jleechanorg-worldarchitect-ai/bc363d53-*.jsonl`
- Worktree: `~/.worktrees/wa-mobile-ux` (branch `fix/my-campaigns-mobile-ux`)
