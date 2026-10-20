---
name: json-schema-deliverable
description: JSON-Schema-validated output with embedded backslashes.
---

# JSON Schema-Validated Deliverable With Embedded Non-JSON Content

## The trap

When the task contract says `Your FINAL response must be a single JSON object that validates against this JSON Schema` and the answer body is large Markdown (with shell patterns, regex, LaTeX, Windows paths, or any text containing backslashes), the naive approach is to:

1. Build the prose as a string
2. Stuff it into `{"summary": "<prose>"}`
3. Hand it to `write_file` or paste it as a final response

**This fails.** The reason: `write_file` runs JSON syntax validation on the content before writing, and any backslash that isn't part of a valid JSON escape (double-backslash, backslash-quote, backslash-slash, backslash-b, backslash-f, backslash-n, backslash-r, backslash-t, backslash-u-XXXX) is rejected as `Invalid \escape (line N, column M)`. Markdown full of `\(`, `\)`, `\d`, `\s`, literal `\\n` (literal n after backslash) trips this immediately. The same problem hits the final response if it is parsed before delivery.

Observed failure mode (2026-08-13): `write_file` rejection on a 29KB AI-coding-advice synthesis reproduction — content had shell patterns `\( -type d -o -type l \)`, JSON quotes inside, and many prose paths. First attempt failed at line 2, column 25678. Second attempt via `json.dump` in `execute_code` succeeded.

## The fix: build JSON in Python, then write

Always construct the JSON via Python's `json.dumps` (or `json.dump`) inside `execute_code`. The Python `json` module handles every escape correctly and uses ASCII-safe encoding by default. This bypasses any tool-layer pre-validation that misreads backslashes.

```python
import json

result = {"summary": """
# Heading

Inline code with shell: `\\( -type d -o -type l \\)` and regex `\\d+`.

JSON inline: `{"key": "value with \\"quote\\""}`.
"""}

# Verify it parses before writing/printing
with open("/path/to/output.json", "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

# Sanity check
with open("/path/to/output.json") as f:
    loaded = json.load(f)
print(f"OK: {len(loaded['summary'])} chars")
```

## When to use Python `json` vs `write_file`

| Content has these | Tool | Why |
|---|---|---|
| Backslashes (shell, regex, LaTeX, Windows paths) | `execute_code` + `json.dump` | `write_file` rejects on `Invalid \escape` |
| Embedded triple-quotes | `execute_code` + `json.dump` | `write_file` treats them as end-of-doc |
| Trailing/leading whitespace matters | `execute_code` + `json.dump` | Preserves exact bytes |
| Pure JSON, no escape hazards | `write_file` directly | One-shot, no overhead |
| Plain text artifact (not JSON) | `write_file` directly | No JSON validation applies |

## Pitfalls to avoid

1. **Don't manually escape.** Trying to escape backslashes by doubling in a string lets you fight the validator without fixing the underlying problem. Use Python's `json` module.

2. **Don't use `write_file` with `content` containing raw JSON-escape candidates.** The validator runs INSIDE `write_file` and rejects before any IO; the file is never created.

3. **Don't manually quote-escape in raw strings.** Python's `json` module knows when a backslash is escaping a quote; manual quoting produces artifacts that downstream readers parse incorrectly.

4. **Don't forget `ensure_ascii=False` if emitting non-ASCII.** Default behavior escapes Unicode as `\uXXXX`, which is fine for JSON but harder to read in the output file. For embedded Markdown with em-dashes, curly quotes, or CJK characters, `ensure_ascii=False` keeps the file human-readable.

5. **Verify with `json.load` after writing.** Same pattern as `artifact-readback-verify`: read the file back, parse it, print the key length. Catches silent truncation.

6. **If the final response itself is JSON-validated (not a file):** Still build with Python. Paste the `json.dump` output as the final response. Test the paste in a Python REPL first to confirm it round-trips.

## Wrapping the harness in a helper

For recurring synthesis tasks (monthly AI coding advice, weekly audit reports, quarterly retrospectives), use the ready-to-run script at `scripts/emit_schema_validated.py` (round-trips the payload through `json.loads` to verify the produced text parses back to the same structure; raises `AssertionError` on mismatch). Inline equivalent:

```python
def emit_schema_validated_object(payload: dict, output_path: str = None) -> str:
    text = json.dumps(payload, indent=2, ensure_ascii=False)
    if output_path:
        with open(output_path, "w") as f:
            f.write(text)
    parsed = json.loads(text)
    assert parsed == payload, "round-trip mismatch"
    return text
```

Terminal form:

```
python3 -m scripts.emit_schema_validated '{"summary":"hello"}' /tmp/out.json
```

## Related

- `artifact-readback-verify` — read back after write, grep for a token. Applies when verifying the file landed correctly.
- `streaming-utf8-mojibake` — different mojibake class (Python `requests` decoding with `decode_unicode=True`). Adjacent but distinct.
- `hermes-agent-skill-authoring` — for authoring SKILL.md files, not for the JSON delivery pattern.
- `write-goal` — produces a `.converge/goal.md`, not a JSON deliverable.
- `plan` — produces a markdown plan in `.smartclaw/plans/`, not a JSON deliverable.

## Verified failure mode (2026-08-13)

Reproduced in this session: a 29KB prose synthesis intended for `{"summary": <prose>}` was first attempted via `write_file` to `/tmp/ai_coding_advice_synthesis.json`. Result:

```
Refusing to write '/tmp/ai_coding_advice_synthesis.json':
candidate content fails .json syntax validation
(JSONDecodeError: Invalid \escape (line 2, column 25678)).
The file was NOT created or modified.
```

The prose contained shell patterns (`\( -type d -o -type l \)` from disk-magician audit notes) and many Markdown table lines with backslashes. The fix was to construct the JSON in Python via `json.dump` and write through Python — succeeded with `OK: written <path>` and `Summary length: 29119 chars`.

This pattern will recur every time a JSON-Schema-validated task contract requires a large Markdown body. Future agents loading this skill will hit the same wall and skip the failed first attempt.
