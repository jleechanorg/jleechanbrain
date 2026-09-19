---
name: frontend-scroll-anchor-streaming
version: 1.3.0
description: "Fix scroll-anchor viewport yank during streaming UIs — covers both yank-protection (auto-follow near bottom) and always-watch (snap on user action) policies."
tags: [frontend, scroll, streaming, overflow-anchor, browser-default, bug-class, chat, submit-snap]
author: hermes
license: MIT
metadata:
  hermes:
    tags: [frontend, scroll, streaming, overflow-anchor, browser-default, bug-class, submit-snap, always-watch, yank-protection]
    triggers:
      - "scrolled to bottom while streaming"
      - "lost my position when content loaded"
      - "page keeps dragging me down"
      - "viewport jumps when chat updates"
      - "overflow anchor"
      - "can't scroll up while messages load"
      - "scroll to bottom on submit"
      - "snap to bottom when user submits"
      - "scroll to the bottom once the player submits"
      - "auto-scroll on action"
---

# Frontend scroll anchoring vs streaming content

## When to use

Trigger on any of: "scrolled to bottom while streaming", "lost my position when content loaded", "page keeps dragging me down", "viewport jumps when chat updates", "can't scroll up while messages load", "overflow anchor", "the UI scrolls to the end when streaming ends", or any chat/AI/infinite-feed scroll-jank report that mentions the user being involuntarily moved to the bottom while content is being appended.

Do NOT use for: user *intentionally* being at the bottom (that is normal behavior), reverse-scroll-drift (virtualization class), page-level scroll jumps on route changes (`scrollRestoration`), or OS-level rubber-banding (`overscroll-behavior`).

## The bug class (read this first)

When a scrollable container (`overflow: auto` or `overflow-y: auto`) has content appended *below the current scroll position* while the user is reading somewhere in the middle, **Chromium / Firefox / WebKit all run "scroll anchoring" by default**. The browser picks an anchor element visible in the scrollport and adjusts `scrollTop` after every layout change so that element stays at the same pixel offset. From the user's perspective, content appears to scroll downward on its own.

This bites every chat UI, AI streaming panel, infinite feed, notification list, and "live log" view that appends content to a scrollable container. Symptom signature:

- User scrolls up to re-read earlier content
- New chunks arrive at the bottom
- The viewport drifts downward, one anchor-keep per chunk, until the user is at the bottom
- User scrolls up again — same thing happens, often faster than they can fight it
- On stream/lifecycle end (final render, "done" event, history merge) the anchor snaps to the very last visible content

User reports sound like: *"the UI scrolls to the end when streaming ends and the user loses their position"*, *"page yanks me back to the bottom"*, *"I can't scroll up while it's loading"*.

## Why your existing scrollToBottom() didn't fix it

A common wrong fix is to add a `scrollToBottom()` call "only when at the bottom". This fights scroll anchoring in two ways:

1. The check (`Math.abs(scrollTop - maxScroll) < threshold`) usually passes because scroll anchoring has already moved the user near the bottom by the time the check runs
2. Even when the check correctly returns false (user is up top), the browser's next layout tick re-anchors and moves them again

You need to address the **root cause** (default anchor behavior) AND the **intent** (auto-follow when user wants it).

## Diagnosis recipe (3 checks, <2 min)

### Check 1 — Is the container a scroll context?

```js
const el = document.querySelector('#story-content');
const cs = getComputedStyle(el);
console.log({ overflowY: cs.overflowY, overflowAnchor: cs.overflowAnchor });
```

If `overflow-y` is `auto`/`scroll` and `overflow-anchor` is `auto` (or unset), the container is anchored.

### Check 2 — Is content being appended below the user's viewport?

```js
const anchorEl = document.elementFromPoint(window.innerWidth/2, 200);
const anchorTopBefore = anchorEl.getBoundingClientRect().top;

someNode.appendChild(newChunk);
const anchorTopAfter = anchorEl.getBoundingClientRect().top;
const drift = anchorTopAfter - anchorTopBefore;
```

A non-zero `drift` while the user is NOT touching the wheel = scroll anchoring.

### Check 3 — Is there a JS scrollToBottom() being called defensively?

`rg -n "scrollToBottom|scrollIntoView.*smooth|scrollHeight" <dir>` — if you find a "smart" helper that "only scrolls if user is at the bottom", the smart helper and the anchor behavior are in a tug-of-war. Pick one model and own it.

## Pre-flight: which policy does this repo want?

There are two valid contracts for streaming UIs and they are MUTUALLY EXCLUSIVE. Diagnose which one the repo wants BEFORE shipping a fix — the wrong pick creates a worse bug than the one being fixed.

| Policy | What it means | When it fits |
|---|---|---|
| **Auto-follow while reading** ("yank-protection") | User can scroll up to re-read; streaming chunks arrive without dragging the viewport | Reading-heavy chat: long story archives, infinite history, anything where the user often scrolls back |
| **Snap-to-bottom on user action** ("always-watch") | Whenever the user takes an action (submit a message, click a button), the viewport snaps to the bottom so streaming is visible | Player-action UI: games, command palettes, "watch the response arrive" workflows — anywhere the user's last action implies "I want to see what happens next" |

The two-component fix below assumes **yank-protection** (auto-follow is desired when the user is near the bottom). If the repo wants **always-watch**, ship ONLY the explicit snap call on the user-action submit handler — and remove any load-time `setTimeout(scrollToBottom, ...)` branches that contradict the policy (see WA PR #9928 reference below).

### How to detect the policy in 30 seconds

```bash
# 1. Search the streaming handler for any scroll/nearBottom call near it
rg -n "onChunk|onMessage|appendStream|appendChunk" <repo> --type js -C 5 | rg -n "scrollToBottom|scrollIntoView|nearBottom"

# 2. Look for a guard test that explicitly forbids auto-scroll in the streaming path
rg -n "scrollToBottom|scrollHeight|maxScroll" <repo>/<tests_dir>/frontend/ 2>/dev/null
rg -n "should not.*scroll.*stream|disable.*auto.*scroll" <repo> -i

# 3. Check git log for an explicit "disable auto-scroll" or "scroll to bottom on submit" PR
git -C <repo> log --all --oneline --grep -i -E "disable.*auto.?scroll|remove.*scroll.*stream|snap.*bottom.*submit|scroll.*on.*submit"
```

### WA PR #9928 — the "always-watch" policy in practice (2026-09-18)

`jleechanorg/worldarchitect.ai` PR #9928 ("fix(scroll): snap to bottom on submit; remove load auto-scroll") flipped a stale half-disabled policy:

- The submit handler explicitly commented `// scrollToBottom removed: user does not want auto-scroll after submitting an action` (a prior decision that was itself a regression).
- The load-finish path still had a `setTimeout(() => scrollToBottom(storyContainer), 100)` branch in `resumeCampaign` that contradicted the documented load-scroll policy (`existing-campaign load MUST NOT auto-scroll to the bottom`).
- The new policy: every player action → snap to bottom so streaming is visible. Load → no auto-scroll (user reads at top, or wherever scrollRestoration lands them).

Lesson: **audit all `scrollToBottom()` call sites in the file before adding any new one.** If two call sites express opposing policies (submit-skip + load-snap), one of them is stale. The fix is to delete the stale one and document the live one in the comment block.

### Real example: WA PR #9358 shipped CSS-only after a CI red

`jleechanorg/worldarchitect.ai` PR #7105 ("Disable auto-scroll during streaming") explicitly removed `scrollToBottom` / `shouldAutoScrollStreamingEntry` calls from `onChunk`. The contract is enforced by `mvp_site/tests/frontend/test_scroll_disabled.py` — it asserts the `onChunk` handler body does NOT contain `scrollToBottom`, `scrollHeight`, or `maxScroll`.

### How to detect the policy in 30 seconds

```bash
# 1. Search the streaming handler for any scroll/nearBottom call near it
rg -n "onChunk|onMessage|appendStream|appendChunk" <repo> --type js -C 5 | rg -n "scrollToBottom|scrollIntoView|nearBottom"

# 2. Look for a guard test that explicitly forbids auto-scroll in the streaming path
rg -n "scrollToBottom|scrollHeight|maxScroll" <repo>/<tests_dir>/frontend/ 2>/dev/null
rg -n "should not.*scroll.*stream|disable.*auto.*scroll" <repo> -i

# 3. Check git log for an explicit "disable auto-scroll" PR
git -C <repo> log --all --oneline --grep -i -E "disable.*auto.?scroll|remove.*scroll.*stream"
```

If any of those hits suggest the maintainers removed scroll from the streaming path on purpose, the JS component is **not wanted**. Ship CSS-only.

### Real example: WA PR #9358 shipped CSS-only after a CI red

`jleechanorg/worldarchitect.ai` PR #7105 ("Disable auto-scroll during streaming") explicitly removed `scrollToBottom` / `shouldAutoScrollStreamingEntry` calls from `onChunk`. The contract is enforced by `mvp_site/tests/frontend/test_scroll_disabled.py` — it asserts the `onChunk` handler body does NOT contain `scrollToBottom`, `scrollHeight`, or `maxScroll`.

My first attempt at PR #9358 shipped the JS hook as Component 2 — CI went red on `Directory tests (core-mvp-2)` because `test_scroll_disabled.py` failed. Amended the commit to CSS-only (removed the JS hook); all 13 checks went green. Lesson: **always rg for "no autoscroll" guard tests before designing the JS component.**

When shipping CSS-only, the regression test should:
- Verify the CSS rule is in the shipped stylesheet (`#story-content { overflow-anchor: none }` matches via regex)
- Verify the streaming handler does NOT contain `scrollToBottom` / `scrollHeight` / `maxScroll` (negative-space regression guard — prevents a future contributor from re-introducing auto-scroll "to make auto-stick work again")
- Behavioral Playwright test: drift == 0 while chunks stream in

## Fix shape (two-component, universal)

The fix is ALWAYS this pair. Don't ship one without the other — unless the pre-flight above tells you the repo has an explicit "no auto-scroll" contract, in which case ship CSS-only.

### Component 1 — CSS: disable browser anchoring on the container

```css
#story-content, .chat-scroll, .live-log, [data-stream-scroll] {
  overflow-anchor: none;
}
```

`overflow-anchor: none` turns off the browser's auto-adjust. Content can grow underneath the user's viewport without dragging them.

Scope this rule to the specific scroll container — don't blanket-apply it to the whole document or you lose the (usually desirable) document-level anchoring on pages without explicit scroll regions.

### Component 2 — JS: intent-driven auto-follow

Replace the browser's "anchor to whatever was visible" with an explicit "only follow if the user wants to follow". Common idiom:

```js
function shouldAutoFollow(streamEl, container) {
  if (!streamEl || !container) return false;
  const maxScroll = container.scrollHeight - container.clientHeight;
  if (Math.abs(container.scrollTop - maxScroll) < 100) return true;
  const eTop = streamEl.getBoundingClientRect().top;
  const cTop = container.getBoundingClientRect().top;
  return Math.abs(eTop - cTop) < 100;
}

if (shouldAutoFollow(streamEl, container)) {
  container.scrollTo({ top: container.scrollHeight, behavior: "instant" });
}
```

Wire the check into the streaming chunk handler, the append-on-message handler, and any "history merged" handler. Don't wire it into "click an old message to re-read it" handlers (those are explicit user scroll intent — let them win).

### When the fix is wrong-shaped

- `scrollToBottom()` unconditionally on every chunk → makes the bug worse
- `setTimeout(scrollToBottom, 100)` after append → races with the user's own scroll, feels laggy
- Only `overflow-anchor: none`, no auto-follow → users who WANT to watch the stream lose their place
- Only auto-follow, no `overflow-anchor: none` → anchor + auto-follow tug-of-war, jittery
- `scroll-behavior: smooth` on the container → fights the `behavior: "instant"` calls in the chunk loop

## Always-watch fix (Component 2 only, no CSS change)

When the repo policy is **snap-to-bottom on user action**, you do NOT want `overflow-anchor: none` — that disables the browser's helpful anchoring on chat UIs. You want exactly ONE explicit `scrollToBottom()` call site (the user-action submit handler), plus audit/delete of every other auto-scroll branch.

```js
// Inside the form submit handler, AFTER appending the user's entry:
const storyContainer = document.getElementById("story-content");
if (storyContainer) {
  resetReaderScrollIntent();   // clears text-anchor, sets readerFollowing=true
  scrollToBottom(storyContainer);  // explicit snap
}
```

Then **audit every other `scrollToBottom()` / `scrollHeight` call site** in the file. The four common ones to look for:

| Location | Verdict |
|---|---|
| Submit handler (`addEventListener("submit", ...)`) | KEEP — canonical user-action snap |
| `resumeCampaign` / load-finish | DELETE — contradicts the policy; user reads where scrollRestoration lands them |
| `showView` / view-switch | KEEP only if it's a user-initiated switch (e.g. tab click); the snap helps them see new content |
| `slowScrollTo` helper for character-creation landing | KEEP — explicit user-initiated landing target, not auto-scroll |

The negative-space regression test that prevents reintroduction:

```python
# test_no_auto_scroll_after_load.py
import re
from pathlib import Path

def test_only_submit_can_auto_scroll():
    src = Path("mvp_site/frontend_v1/app.js").read_text()
    matches = [
        (m.start(), src[max(0, m.start() - 200):m.end() + 50])
        for m in re.finditer(r"scrollToBottom\(", src)
    ]
    in_submit = [m for m in matches if "interaction-form" in m[1]]
    assert len(in_submit) == 1, f"Expected exactly 1 scrollToBottom() in submit handler, found {len(in_submit)}"
    in_load = [m for m in matches if "setTimeout" in m[1] and "100" in m[1]]
    assert not in_load, f"Found setTimeout(scrollToBottom, ...) near load path — auto-scroll on load is forbidden"
```

This is the test that PR #9928 added to lock the always-watch policy.

## Verification (Playwright, computed-style guard)

The bug only manifests while content is being added, so a static `getBoundingClientRect()` snapshot is not enough.

```python
def assert_no_scroll_drift(page, scroll_selector, content_selector):
    page.goto(URL)
    page.evaluate("""
        const sc = document.querySelector('%s');
        sc.scrollTop = sc.scrollHeight / 2;
        window.__anchor = document.elementFromPoint(
            window.innerWidth/2, window.innerHeight/2);
        window.__topBefore = window.__anchor.getBoundingClientRect().top;
    """ % scroll_selector)
    page.evaluate(f"""
        const cs = document.querySelector('{content_selector}');
        for (let i = 0; i < 30; i++) {{
            const p = document.createElement('p');
            p.textContent = 'chunk ' + i + ' '.repeat(200);
            cs.appendChild(p);
        }}
    """)
    drift = page.evaluate(
        "window.__anchor.getBoundingClientRect().top - window.__topBefore")
    return drift  # expect ~0 if fix is in place
```

`drift == 0` (±2px for sub-pixel rounding) is the regression test. Capture BEFORE PNG showing drift >0 and AFTER PNG showing drift ~0.

## Common pitfalls

### Smooth-scroll on the container

`scroll-behavior: smooth` on the scroll container animates the `scrollTo({behavior:"instant"})` calls and makes auto-follow laggy. If you need smooth for explicit user scrolls (e.g. "jump to first unread"), apply it to a child element or use a JS-only smooth scroll and `behavior: "instant"` in the chunk loop.

### `white-space: pre-wrap` + long unbroken tokens

A single very long word (URL, stack trace, generated token without spaces) inside `white-space: pre-wrap` will expand the line to its native width and push the anchor. Use `overflow-wrap: anywhere` on text containers that receive LLM output.

### Re-rendering the entry on completion is its own append

Many chat UIs render a "Loading…" placeholder, then `replaceWith` the final entry when the stream ends. The replace is a layout change — it triggers a re-anchor. Make sure Component 1 (`overflow-anchor: none`) is in place BEFORE the final render, or the user still gets yanked at the very end.

### Checking `isIntersecting` instead of scrollTop

`IntersectionObserver` says "is the latest element visible" — not "is the user reading near the bottom". For chat/streaming UIs, `scrollTop` distance-from-bottom is the right signal. Reserve IntersectionObserver for "show 'X new messages' pill" UX.

### Hidden overflow-anchor on a parent

Some layouts (e.g. flex with `min-height: 0` on a child) create nested scroll contexts. The browser's anchor algorithm uses the *outermost* scroll context. If your "fix" applies to the inner one, the outer one still drags. Test the actual scroll container the user is reading in.

### Test fixture: inline `style=` attribute neutralizes `<style>`-sheet rules

When building a Playwright regression fixture with `_build_fixture_html(css_text)`, **never** inline the same properties the test CSS provides on the same element:

```python
# WRONG — inline `overflow-y:auto` silently drops `overflow-anchor: none`
# because inline styles outrank <style>-sheet rules, and `overflow-anchor`
# is NOT set inline → falls back to its initial value `auto`.
"<div id='story-content' style='overflow-y:auto; overflow-x:clip'>"

# RIGHT — let the production CSS supply `overflow-y:auto; overflow-x:clip;
# overflow-anchor:none` from the <style> block, only set border inline.
"<div id='story-content' style='border:1px solid #ccc;'>"
```

This bit PR #9358 (WA streaming scroll-yank) twice — Phase B AFTER failed because the inline `overflow-y:auto` overrode the test's `overflow-anchor: none`, restoring the bug the fix was supposed to eliminate. The test was reporting a regression that was actually a fixture bug.

Rule: the test fixture mirrors the production DOM. If production sets `overflow-anchor` in `<style>`, the test fixture must NOT inline any sibling `overflow-*` properties on the same element. Use `re.sub` to strip the rule for the BEFORE/Phase A fixture only.

### Test fixture: `shouldAutoFollow` second branch fires when streaming entry is near scrollport top

The classic two-branch helper `if (nearBottom) return true; if (abs(entryTop - containerTop) < 100) return true;` is fine in production but treacherous in a fixture that positions the marker near the top of the scrollport and the streaming entry right below it:

- The user scrolled up → branch (a) `nearBottom` is false
- The streaming entry is near the scrollport top (just below the marker) → branch (b) fires
- `scrollToBottom(container)` runs → marker gets yanked via the very auto-follow you were trying to disable

Two ways to test the yank shape without that collision:

1. **Don't install the production helpers in the fixture at all** for the yank-detection test. The bug is browser-native scroll anchoring — application JS has nothing to do with it. A pure textContent-write loop is enough.
2. **Position the streaming entry BELOW the scrollport** (not near the marker) so branch (b) also returns false in the fixture. This matches production: a user reading old content has the live streaming entry off-screen at the bottom.

If you need a separate test for the auto-follow path (verify `scrollToBottom` actually fires when the user is near the bottom), use a dedicated fixture with `container.scrollTop = container.scrollHeight` BEFORE chunk writes — that's the production-shape "I'm watching the stream" scenario.

### Dispatch lesson: let the worker iterate on test fixtures

When dispatching this fix class to a claudem worker via `bash -lic 'claudem -p ...'`, prescribe the fix shape (the two CSS+JS components) but do NOT prescribe exact test fixture HTML. The fixture needs to match the production DOM, and only an in-loop Playwright run reveals specificity/branch-collision bugs. Two 600s timeouts (claudem's max foreground window) on a 3-file diff is the cost of prescribing too much detail; one round of "write test, run test, iterate" by the orchestrator (you) is cheaper than three round-trips through the worker. Watch for: worker times out after writing the test file but before running it = they're stuck in a fix-the-fixture loop without iterating. Take over the test-fixture phase manually.

### Dispatch lesson: brief must enumerate every auto-scroll call site, not just the new one

When dispatching the always-watch variant ("scroll to bottom on submit, also remove the other auto-scroll logic"), the worker does NOT know which sites you consider "the other". Spell out:

- **KEEP**: explicit user-initiated scrolls (load-landing on character creation, view-switch with trusted input, slowScrollTo)
- **KEEP**: helper definitions (the `scrollToBottom()` function itself, `resetReaderScrollIntent()`)
- **DELETE**: `setTimeout(scrollToBottom, ...)` branches in load paths
- **DELETE**: dead `storyContainerSubmit` style "I removed this but left the variable" artifacts
- **KEEP-with-justification**: `resetReaderScrollIntent()` at view-switch (it's a state reset, not an auto-scroll — the comment must make that clear)

If the worker doesn't have the per-site verdict, they'll either over-prune (delete `resetReaderScrollIntent()` and break the completion-time `shouldFollowStream` gate) or under-prune (only fix the submit handler, leave the load-branch in place). PR #9928 succeeded because the brief listed all 5 keep sites + 2 delete sites explicitly.

## When NOT to use this skill

- User *intentionally* scrolled to the bottom and wants to stay there — that's normal behavior, not a bug. Only "fix" it if the user explicitly opted out of auto-follow.
- Reverse-scroll-drift bugs (user expects content to stay at the bottom of their viewport while they scroll *down* in history) — different class, usually requires virtualization.
- Page-level scroll jumps on route changes — that's `scroll-behavior: smooth` + `scrollRestoration` interaction, not scroll anchoring.
- OS-level rubber-banding — `overscroll-behavior`, not `overflow-anchor`.

## Reference

- `references/worldarchitect-streaming-scroll-yank.md` — originating case from WorldArchitect.AI `#story-content` panel: video evidence of the yank, the diff that fixed it (1-line CSS + 10-line JS hook into the existing `shouldAutoScrollStreamingEntry` helper), and the Playwright regression test.
- `references/worldarchitect-submit-snap-to-bottom-2026-09-18.md` — always-watch variant (PR #9928): snap to bottom on submit, audit every other `scrollToBottom()` call site, negative-space test that locks the policy.
