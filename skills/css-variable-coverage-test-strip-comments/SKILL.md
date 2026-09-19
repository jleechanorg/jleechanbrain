---
name: css-variable-coverage-test-strip-comments
version: 0.1.0
description: "Strip CSS comments before var() regex in coverage test."
tags: ["css", "testing", "regex", "false-positive", "root-cause-fix"]
triggers:
  - test_css_variable_coverage.py fails with undefined CSS variable
  - undefined CSS variable name ends with a trailing dash
  - PR adds new CSS custom properties with hex fallbacks
changelog:
  - "0.1.0 (2026-08-18): Initial extract from PR #9070 / commit 011debf4be."
---

# css-variable-coverage-test-strip-comments

## The bug class

`mvp_site/tests/test_css_variable_coverage.py` scans every `.css` file under
`mvp_site/frontend_v1/` and asserts that every `var(--name)` usage has a
matching `--name: value` definition. The regex `re.compile(r"var\(\s*(--[\w-]+)")`
captures the variable name from `var(...)` calls.

When a CSS author writes documentation like:

```css
/* The helper var(--risk-rgb-<level>) holds the numeric RGB triple so
   color-mix works in `in srgb` syntax without parsing the hex. */
```

…the regex matches `var(--risk-rgb-` (the `<` and `>` are non-word chars that
terminate the `\w-` class) and captures `--risk-rgb-` as a "used" variable
name. The trailing dash makes it impossible to match any definition, so the
test fails:

```
AssertionError: Undefined CSS variables found (used but never defined):
  --risk-rgb-  (used in: planning-blocks.css:25)
```

## The fix (root-cause)

Strip CSS comments BEFORE scanning for var() usages. The test regex should
ignore comments — that's the test's job, not the comment author's job.

```python
# Before
def _extract_var_usages(css_files):
    usages = {}
    for path in css_files:
        text = path.read_text(encoding="utf-8")
        for i, line in enumerate(text.splitlines(), 1):
            for match in VAR_USAGE_RE.finditer(line):
                var_name = match.group(1)
                usages.setdefault(var_name, []).append(f"{path.name}:{i}")
    return usages

# After
def _extract_var_usages(css_files):
    """Return {variable_name: [file:line, ...]} for every var() usage.

    Strips /* ... */ comments before scanning so documentation that mentions
    `var(--foo-bar)` placeholders in comments does not count as a usage.
    """
    usages = {}
    for path in css_files:
        text = path.read_text(encoding="utf-8")
        text_no_comments = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
        for i, line in enumerate(text_no_comments.splitlines(), 1):
            for match in VAR_USAGE_RE.finditer(line):
                var_name = match.group(1)
                usages.setdefault(var_name, []).append(f"{path.name}:{i}")
    return usages
```

## Why this is the right fix (not a band-aid)

1. **Root cause**: regex consumes text that is semantically not CSS code
   (comments). The fix moves the regex to only consume real CSS.
2. **Forward-compatible**: any future contributor who writes a docstring-style
   `var(--token)` placeholder in a CSS comment will not break CI.
3. **Robust verification**: real `var()` usages are still detected:

```python
>>> import re
>>> text = '/* comment with var(--risk-rgb-) */ real: var(--undefined) other: var(--defined)'
>>> re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
' real: var(--undefined) other: var(--defined)'
>>> re.findall(r"var\(\s*(--[\w-]+)", _)
['--undefined', '--defined']
```

## Pitfalls (don't do these)

- ❌ Don't change the comment to remove `var(--risk-rgb-<level>)`. The
  comment is intentional documentation explaining how the token family is
  structured. Removing it makes the CSS less self-documenting and creates
  drift between the actual tokens and the explanation.
- ❌ Don't add `--risk-rgb-` to the test allowlist. That hides the bug
  for one specific PR but doesn't fix the regex consumer's failure to
  ignore comments.
- ❌ Don't use a placeholder name like `--risk-rgb-<level>` in real CSS
  code. Keep it inside `/* ... */` so the regex (after the fix) ignores it.

## Verification (proven recipe from PR #9070)

Local:

```bash
cd ~/projects/worldarchitect.ai
# Before fix: 1 fail, 4 pass, 1 error
./venv/bin/python -m pytest mvp_site/tests/test_css_variable_coverage.py -v
# After fix: 5 pass in 0.06s
```

CI (literal evidence from run 32217158768 / job 95961901650):

```
Directory tests (core-tests)
  Total tests run: 35
  Passed: 35
  Failed: 0
```

This is the GitHub-hosted `core-tests` shard that exercises `mvp_site/tests/`.
The self-hosted `core-mvp-1(self hosted)` shard also runs the same test but
can be SKIPPED due to network flakes on the self-hosted runner — the
GitHub-hosted shard is the authoritative proof when self-hosted fails.

## Related skills

- `root-cause-first` — fix the regex consumer, not the comment
- `pr-green-definition` — what counts as CI green when self-hosted shards skip
