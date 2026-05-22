---
name: browser-skill-optimizer
description: Optimize browser automation workflows by iterating from click-by-click navigation to JS-eval shortcuts, then saving the optimized version as a reusable Hermes skill. Inspired by Autobrowse — eliminates browser agent "amnesia" by making every repeated browser task cheaper and faster.
tags: [browser, optimization, skills, autobrowse, js-eval]
---

# Browser Skill Optimizer

Eliminate browser agent amnesia. When a browser task is expensive (many turns, slow), this skill iterates to find a faster path — typically replacing DOM clicks with `browser_console` JS eval — and saves the optimized workflow as a reusable Hermes skill.

## Trigger

Use when:
- A browser task just completed with >5 turns or >30 seconds
- User says "optimize this browser task", "make this faster", "autobrowse", or "browser skill optimizer"
- After any browser interaction where you think "that was slow, there has to be a better way"

## Workflow

### Step 1: Baseline Run

Run the browser task normally and capture metrics:

```
METRICS TO RECORD:
- turns: number of browser_* tool calls
- time: wall-clock seconds (approximate from tool call timestamps)
- cost: rough token estimate (turns × ~2K tokens × price per 1M)
- approach: summary of what was done (click-by-click, form fills, navigation)
```

### Step 2: Analyze for JS-Eval Shortcuts

Review what the baseline run did. For each step, ask:

1. **Could this click be replaced with JS?**
   - Clicking a button → `document.querySelector('button#submit').click()`
   - Reading text → `document.querySelector('.result').textContent`
   - Filling a form → `document.querySelector('input#name').value = 'foo'`
   - Navigation → `window.location.href = '/next-page'`
   - Waiting for content → `await new Promise(r => setTimeout(r, 1000)); document.querySelector('.loaded')`

2. **Could multiple steps be batched?**
   - 5 sequential clicks → single JS snippet that does all 5
   - Page → scroll → extract → often collapsible into one `browser_console` eval

3. **Is there an API or XHR the page uses?**
   - Check network tab equivalents: look for `fetch()` or `XMLHttpRequest` patterns
   - Sometimes the page calls a REST API that you can hit directly, skipping the UI entirely
   - Use `browser_console` to inspect: `performance.getEntriesByType('resource')`

### Step 3: Optimized Run

Re-run the task using JS-eval shortcuts identified in Step 2.

Key patterns:
- Use `browser_console` with `expression` parameter for JS eval
- Use `browser_navigate` only for initial page load
- Use `browser_click`/`browser_type` only when JS eval can't reach the element (shadow DOM, iframes, cross-origin)
- Batch multiple operations in a single `browser_console` call

Example optimization:
```javascript
// BAD: 5 turns of click-by-click
browser_navigate("https://example.com/dashboard")
browser_click("@e1")  // settings tab
browser_click("@e5")  // toggle switch
browser_click("@e8")  // save button
browser_snapshot()     // verify

// GOOD: 1 turn with JS eval
browser_navigate("https://example.com/dashboard")
browser_console(expression: `
  // Click settings, toggle, save in one shot
  document.querySelector('[data-tab="settings"]').click();
  setTimeout(() => {
    document.querySelector('.toggle-switch').click();
    setTimeout(() => {
      document.querySelector('.save-btn').click();
    }, 500);
  }, 500);
  'Done';
`)
```

### Step 4: Compare Metrics

Record optimized run metrics in the same format as Step 1. Calculate improvement ratios:

```
IMPROVEMENT:
- turns: X → Y (ratio)
- time: Xs → Ys (ratio)
- approach: [what changed]
```

### Step 5: Save as Skill

If the optimized version is meaningfully better (>20% improvement on any metric), save it as a Hermes skill:

```
skill_manage(action="create", name="browser-<site>-<task>", category="browser", content=SKILL_MD)
```

The skill should contain:
1. **URL** of the target site/page
2. **Task description** — what the workflow accomplishes
3. **Optimized JS snippets** — the actual browser_console expressions to use
4. **Fallback steps** — if JS eval fails (site redesign, dynamic selectors), the click-by-click path
5. **Selector stability notes** — which selectors are fragile, which are stable (data-* > class > nth-child)

### Skill Template

```markdown
---
name: browser-<site>-<task>
description: <what it does>
tags: [browser, optimized]
---

# <Site> — <Task>

## Optimized Path (JS eval)

1. Navigate: `browser_navigate("<url>")`
2. Execute:
```javascript
<JS snippet that does the whole thing>
```

## Fallback Path (click-by-click)

1. Navigate: `browser_navigate("<url>")`
2. Click <selector> // step 1
3. Type <selector> // step 2
...

## Selectors

| Element | Selector | Stability |
|---------|----------|-----------|
| <name>  | <css>    | high/medium/low |

## Metrics

| Metric | Baseline | Optimized | Improvement |
|--------|----------|----------|-------------|
| Turns  | X        | Y        | X/Y         |
| Time   | Xs       | Ys       | X/Y         |
```

## Anti-Patterns

1. **Don't optimize one-off tasks** — if you'll never do this again, the optimization time isn't worth it
2. **Don't break on SPA navigation** — JS eval runs in the CURRENT page context. If the page navigates (full load), your eval context is lost. Use `browser_navigate` for navigation, JS eval for same-page operations
3. **Don't hardcode fragile selectors** — prefer `[data-testid]`, `[aria-label]`, IDs over class names that may change
4. **Don't skip the fallback** — sites change. Always include the click-by-click path as a fallback in the saved skill
5. **Don't try to bypass auth** — if login is required, the skill should assume you're already authenticated (browser session persists)

## Multi-Iteration Loop

For maximum optimization, run the cycle multiple times:

```
Iteration 1: Baseline (click-by-click) → metrics
Iteration 2: Replace obvious clicks with JS eval → metrics
Iteration 3: Batch remaining operations, find API shortcuts → metrics
```

Typically 2-3 iterations captures 80%+ of the improvement. Diminishing returns after that.

## Integration with Existing Skills

- **browserclaw**: Use for HAR capture if you need to discover XHR/API endpoints the site calls
- **dogfood**: Use for QA — the optimized skill is a great candidate for systematic exploratory testing
- **skillify**: Use if the workflow needs tests, evals, or more formal structure beyond the basic template
