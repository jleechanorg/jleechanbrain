# PR #9042 stale-CSS incident (2026-08-18)

## Summary

User reported an avatar cut-off bug on the PR #9042 preview deploy. The PR's source
code contained the fix (`overflow-clip-margin: 56px` rule in `style.css`, 88px avatar size,
`-46px` bleed in `avatar.css`) but the deployed preview was serving **45-day-old static
assets** from a previous build. The CI workflow had reported `deploy-preview` SUCCESS at
the correct HEAD SHA, masking the staleness behind a green check. The user had to file
the bug visually ~30 minutes after the deploy before the staleness was caught.

This is the canonical example for **P13 (CSS static assets can be stale too)** and **P14
(inbound UI screenshot is a deploy-verification signal)**. PR #8787 / #8790 / #8808 were
all JS-bundle staleness; this is the first catalogued CSS-staleness incident in the WA
project.

## Timeline

| UTC time | Event |
|---|---|
| 2026-08-19T00:19:02Z | `deploy-preview` GH Actions workflow started on PR HEAD `4994e53c50dfad212f070117c8964de8820db51e` |
| 2026-08-19T00:30:47Z | `deploy-preview` workflow SUCCESS. Bot posted preview URL `https://mvp-site-app-s10-i6xf2p72ka-uc.a.run.app` and commit SHA `4994e53c` |
| 2026-08-19T00:31-00:35Z | User posts desktop+mobile+tmux evidence in Slack thread `${SLACK_CHANNEL_ID}/p1787098654574219` — all SHA-tagged `4994e53c50`. Inbound-evidence review confirms body already references the same SHA + Slack file URLs + gist raw URLs. No body push, no binary commit, status read only. |
| 2026-08-19T00:55Z | Agent re-verifies PR state. CI: 32 pass / 1 CANCELLED (Light/Fantasy gate, non-blocking) / 0 fail. CR APPROVED gate still outstanding (2 COMMENTED reviews on ancestor SHAs). 7-green status: 5/7 met, #3 (CR APPROVED) and #4 (Bugbot clean) outstanding. |
| 2026-08-19T01:00Z | User posts new screenshot in same thread: "Dont code just analyze. Why is the image still cutoff top half?" with two identical 2672×1134 PNGs of the deployed preview showing the avatar's top half cut off flat at the navbar boundary. |
| 2026-08-19T01:01Z | Agent runs Phase 2.7-equivalent curls. Discovery: served `avatar.css` `Last-Modified: Sat, 04 Jul 2026 18:53:10 GMT`, 8 876 B vs 9 654 B in repo HEAD `4994e53c50`. Served `style.css` same `Last-Modified`, 34 139 B vs 53 592 B in repo HEAD (delta -36%). Served `avatar.css` has NO `.header-avatar-slot { margin-top: -46px }` rule and `.game-avatar-float img { width: 176px }` (old hero size, not the PR's 88px). Served `style.css` has NO `#game-view { overflow-x: clip; overflow-clip-margin: 56px }` rule. |
| 2026-08-19T01:05Z | Agent posts root-cause analysis in thread. No code change (user explicitly said "Dont code just analyze"). |

## Evidence chain

### User's screenshot shows the bug

- 2672×1134 PNG (2x retina, CSS viewport ~1336×567)
- Vision-extracted crop: avatar circle's top edge is flat-clipped at the navbar/game-view boundary
- Visible portion: mouth, chin, neck, shoulder only — no eyes, no nose, no forehead
- ~44 px of expected 88 px height is missing

### Repo HEAD `4994e53c50` CSS contract (CORRECT, has the fix)

`mvp_site/frontend_v1/css/avatar.css`:
```css
.header-avatar-slot { margin-top: -46px; }   /* pulls avatar up 46px to straddle */
.game-avatar-float img {
  width: 88px; height: 88px;
  border-radius: 50%;
  object-fit: cover;
  object-position: center 15%;               /* biases the visible face downward */
}
@media (max-width: 576px) { .game-avatar-float img { width: 56px; height: 56px; } }
```

`mvp_site/frontend_v1/style.css`:
```css
#game-view {
  overflow-x: clip;
  /* 56px bleed budget so the avatar's top half can render above #game-view */
  overflow-clip-margin: 56px;
}
```

### Deployed preview CSS contract (STALE, July 4 2026)

`Last-Modified: Sat, 04 Jul 2026 18:53:10 GMT` — 45 days before the deploy. `content-length: 8 876` vs repo HEAD 9 654.

```css
.game-avatar-float img {
  width: 176px;        /* OLD: 2x of new 88px */
  height: 176px;
  border: 2px solid rgba(168, 85, 247, 0.5);
  /* NO object-position: center 15% */
}
/* NO .header-avatar-slot { margin-top: -46px } rule */
```

`style.css` `Last-Modified: Sat, 04 Jul 2026 18:53:10 GMT`, `content-length: 34 139` vs repo HEAD 53 592 (delta -19 453 B, -36%).

```css
#game-view.active-view {
  display: flex;
  flex-direction: column;
  height: 85vh;        /* OLD: not 100dvh */
}
/* NO #game-view { overflow-x: clip; } rule */
/* NO overflow-clip-margin anywhere */
```

### Why the cut happened with the OLD code

1. Avatar was `176×176` (the old "hero" size before this PR shrunk it to 88 px), sitting at the top of the game-view header.
2. `#game-view { height: 85vh }` — fixed-height container.
3. **No `overflow-clip-margin`** — so the avatar's bleed gets eaten by whatever ancestor has the clip.
4. No `margin-top: -46px` bleed — the avatar is supposed to be aligned to the title row, but with the larger 176 px size it overflows upward and gets clipped.

### Why the new code WOULD have prevented the cut (if it had deployed)

1. Avatar is now 88×88 (mobile 56×56) — smaller, fits within the bleed budget.
2. `.header-avatar-slot { margin-top: -46px }` — explicit bleed margin.
3. `object-position: center 15%` — biases the visible face downward (the eyes/nose that the old code chopped off are now in the visible portion by design).
4. `overflow-clip-margin: 56px` widens the clip rect by 56 px so the 46 px upward bleed renders above `#game-view`.

The new code was correct; the deploy never shipped it.

### Diagnosis commands (Phase 2.7)

```bash
PREVIEW=https://mvp-site-app-s10-i6xf2p72ka-uc.a.run.app
HEAD_SHA=4994e53c50dfad212f070117c8964de8820db51e

# 1. Last-Modified header sanity
for asset in frontend_v1/css/avatar.css frontend_v1/style.css; do
  lm=$(curl -fsSI -H 'Cache-Control: no-cache' "$PREVIEW/$asset" \
       | awk -F': ' 'tolower($1)=="last-modified"{print $2}' | tr -d '\r')
  echo "$asset -> Last-Modified: $lm"
done
# Output:
#   frontend_v1/css/avatar.css -> Last-Modified: Sat, 04 Jul 2026 18:53:10 GMT
#   frontend_v1/style.css -> Last-Modified: Sat, 04 Jul 2026 18:53:10 GMT

# 2. Byte-count vs source at HEAD
for asset in frontend_v1/css/avatar.css frontend_v1/style.css; do
  src=$(gh api "repos/jleechanorg/worldarchitect.ai/contents/$asset?ref=$HEAD_SHA" --jq '.size')
  served=$(curl -fsSI -H 'Cache-Control: no-cache' "$PREVIEW/$asset" \
           | awk -F': ' 'tolower($1)=="content-length"{print $2}' | tr -d '\r')
  echo "$asset -> source=$src served=$served"
done
# Output:
#   frontend_v1/css/avatar.css -> source=9654 served=8876 (delta -778)
#   frontend_v1/style.css      -> source=53592 served=34139 (delta -19453)

# 3. Selector-presence grep
for asset in frontend_v1/css/avatar.css frontend_v1/style.css; do
  count=$(curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW/$asset" \
          | grep -cE 'overflow-clip-margin|object-position: center 15%')
  echo "$asset -> expected-rule count: $count"
done
# Output:
#   frontend_v1/css/avatar.css -> expected-rule count: 0
#   frontend_v1/style.css      -> expected-rule count: 0
```

All three signals confirm staleness; none would have been caught by the original Phase 2 JS-bundle grep.

## Lessons

1. **CSS files need their own verification recipe (Phase 2.7)** — Phase 2's string-grep is JS-shaped. Adding a CSS-specific `Last-Modified` + byte-count + selector-presence probe catches a class of false-green the original recipe missed.
2. **Inbound UI screenshots are deploy-verification signals (P14)** — when a user posts a screenshot showing the PR's documented fix NOT applied, that is itself the staleness report. Run Phase 2 + 2.7 in the same turn; don't wait for a separate bug report.
3. **`cache-control: public, max-age=300, must-revalidate` does NOT mean fresh** — 5-minute edge cache TTL is fine, but the upstream `Last-Modified` header proves the origin itself is stale. Always pair `Last-Modified` checks with `Cache-Control: no-cache` curls.
4. **The "deploy CI SUCCESS + image tag = HEAD SHA" pattern is necessary but not sufficient for CSS** — same lesson as P1 for JS, but easier to miss for CSS because CSS does not get the function-presence grep that JS does.
5. **A 45-day gap between served `Last-Modified` and deploy CI's reported time is a smoking gun, not a fluke** — investigate Cloud Build cache layer + Dockerfile `COPY` step, not the PR's source code.

## Cross-references

- `pr-evidence-inbound-review` Pitfall 11 (added 2026-08-18) — inbound-side discipline for the same scenario.
- `references/stale-bundle-bug-case-study.md` — PR #8787 JS-bundle staleness (canonical case).
- `wa-visual-proof-playwright` skill — visual verification pattern that surfaces this class of bug.
