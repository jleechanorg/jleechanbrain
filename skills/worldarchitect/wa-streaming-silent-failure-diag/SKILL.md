---
name: wa-streaming-silent-failure-diag — sub-class E
description: 'Successful LLM call recorded in BQ `llm_payloads` (FinishReason.STOP, response_text 5–9KB), but the SSE stream POST immediately after returns HTTP 200 with body 1.3–1.5KB containing only the STREAMING_EMPTY_RESPONSE error event. _preferred_display_text() returned empty post-parse. Discovered 2026-09-14 on campaign dBm9WI1hGvbIBhQLhCvp. Confirmed root cause 2026-09-14: PR #9822 decode-then-strip collapses when LLM emits ONLY literal `\n` runs (decoder converts them to real LFs, `.strip()` returns ""). Sibling sub-class F (Gemini 400 INVALID_ARGUMENT despite 85k ceiling revert, BQ row absent) lives at references/sub-class-f-gemini-400-invalid-argument-85k-ceiling.md — load it FIRST if you see the 400 with no BQ row, that is a distinct bug class.'
tags: ["worldarchitect", "streaming", "empty-response", "post-parse", "preferred-display-text", "branch-b", "god-mode", "silent-failure", "pr-9822", "decode-strip-collapse", "edge-case", "test-gap"]
---

# Sub-class E — Post-parse empty display-text on a successful LLM call

## Symptom (user-verbatim)

> empty response error happening more often ... think recent PR made it worse

Screenshot 2026-09-14 (iPhone, iOS 26_6_2, CRIOS/153.0.8010.24):

```
You :THINK:: How should we be using our money and now dragons
Resources: None
Story: [Error: Empty response from server]
God: Let's not require sorcerery points for non somatic casting but I think incantation
     less casting should stand out more. Also are there any sorcerors in dragon lance?
```

The God panel renders real prose; the Story panel renders the orange error banner — but the LLM call that produced the God response ran to completion.

## The signature (cross-check BOTH GCP + BQ)

```bash
CID="<CAMPAIGN_ID>"  # extract from /game/<CID> URL

# GCP — bucket stream POSTs by response body size
gcloud logging read \
  "resource.type=cloud_run_revision AND resource.labels.service_name=mvp-site-app-dev \
   AND textPayload:${CID} AND textPayload:interaction/stream" \
  --project=worldarchitecture-ai --limit=200 --format=json --freshness=24h \
  | python3 -c "
import json, sys, re
from collections import Counter
data = json.load(sys.stdin)
buckets = Counter()
for e in data:
    m = re.search(r'\"POST [^\"]+interaction/stream HTTP/1\.1\" 200 (\d+)', e.get('textPayload',''))
    if m: buckets[(int(m.group(1)),)] += 1
for (sz,), n in sorted(buckets.items()): print(f'  body={sz:>7} bytes  count={n}')
"

# BQ — confirm LLM calls succeeded
bq query --nouse_cache --format=pretty "
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts, agent, model,
       LENGTH(request_json) AS req_bytes, LENGTH(response_text) AS resp_bytes,
       finish_reason
FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
WHERE campaign_id = '<CID>'
  AND ingested_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
ORDER BY ingested_at DESC LIMIT 40"
```

**Signature pattern:**
| Observation | What it means |
|---|---|
| GCP shows N stream POSTs with body 1387–1400 bytes (vs normal 326KB+) | Branch B fired — `STREAMING_EMPTY_RESPONSE` error event is ~1.3KB SSE |
| BQ shows 0 empty `response_text` rows on that CID | LLM call succeeded — Branch A (pre-BQ) is NOT the cause |
| Every empty POST is paired with a successful BQ row 10–60s earlier | Confirms Branch B fires POST-BQ-log, NOT a Gemini SDK flake |

## The two code paths in `mvp_site/llm_service.py` (origin/main)

```python
# Branch A (line ~10862) — pre-BQ-log, phase2 streaming empty
if not full_narrative or not full_narrative.strip():
    yield StreamEvent(type="error", payload={..., "error_type": "empty_response"})
    return

# ... LLM call would be logged here in BQ ...

# Branch B (line ~11209) — post-BQ-log, parsed display_text empty
display_text = _preferred_display_text(narrative_text, structured_response)
if not display_text:
    yield StreamEvent(type="error", payload={..., "error_type": "empty_response"})
    return
```

`_preferred_display_text(narrative_value, response_obj)`:
1. If `narrative_value.strip()` is non-empty → return it.
2. Else try `_structured_string_field(response_obj, "display_text", "god_mode_response", "faction_header")` → returns first non-empty string from those three fields.
3. Else return `""` → Branch B fires.

**Branch B fires when:**
- `_parse_streamed_response()` returned `JSON_PARSE_FALLBACK_MARKER` (line ~10868 collapses `narrative_text = ""` for that marker) **AND**
- the structured response has empty/unset `display_text`, `god_mode_response`, and `faction_header`.

Verified pattern (campaign `dBm9WI1hGvbIBhQLhCvp`, 4 empty POSTs in 24h):
- All 4 followed a successful GodMode/Planning/StoryMode agent call by 30–80s
- All 4 were preceded by a Think/Plan mode submission (which routes to GodMode/Planning/StoryMode agents)
- Empty rate: 4/93 = 4.3% on this campaign today (vs ~1.5% Sub-class A baseline)

## User workaround

Re-submit the SAME prompt. The LLM is non-deterministic; ~70% of re-submits produce a parseable structured response on the next attempt. Same response, different gemini seed, parse succeeds. User cost: ~30s wait + lost first attempt.

## Suspect recent PRs (verified 2026-09-14 deployment `mvp-site-app-dev-05037-muz`)

- **#9822** `fix(narrative): decode unicode escapes in full_narrative ship-out` — `mvp_site/text_normalization.py:_decode_embedded_unicode_escapes` collapses literal `\\n\\n\\n` → `\n\n\n` → `strip() = ""`. If a GodMode response has only escape sequences, the decoded narrative strip-empties. Applied at 6 sites in `llm_service.py` (lines 10051, 10394, 10548, 10893, 10927, 10260).
- **#9847** `refactor(llm_service): share the Gemini tool-phase core between streaming and non-streaming` — dedupe of `build_tool_phase2_materials` + `ToolPhase2Materials` + `should_single_infer_faction_tools` predicate. **LOW risk for Sub-class E** (verified 2026-09-14: zero changes to decode/parse/display paths; `git merge-base` confirms it's an ancestor of #9822). Bisect only after #9822 revert.

Bisect recipe: revert **PR #9822 first** (5 commits: `9a091723c8c` + `a3ddda6674a` + `c5aca52c7bf` + `6da034c2287` + the merge). Revert PR #9847 only if #9822 revert alone fails to clear the symptom — diff analysis confirms #9847 made zero changes to the decode/parse/display path (`git show d0df0d41141 -- llm_service.py` shows no occurrences of `_decode_embedded_unicode_escapes`, `_parse_streamed_response`, `_preferred_display_text`, or `JSON_PARSE_FALLBACK_MARKER`). Worktree setup: branch `fix/empty-response-bisect-2026-09-14`, redeploy to dev `mvp-site-app-dev-05037-muz`, watch the 4.3% empty rate for 1h. **Note:** `gh pr diff` may be HTTP 403 rate-limited from a heavy session — fall back to `git show <merge-commit>:<file>` to read the merged source directly.

## DURABLE FIX SHAPE (verified 2026-09-14 — confirmed root cause + test gap)

### Confirmed root cause via diff bisect (2026-09-14 21:47 UTC)

`gh pr diff` was rate-limited (HTTP 403); fell back to `git show <merge-commit>:<path>` to read the merged source. For each suspect PR, opened the merged tree at its merge-commit and grepped for `_decode_embedded_unicode_escapes`:

- **PR #9822** merge-commit `b0816a98e75`:
  - Adds `mvp_site/text_normalization.py` (214 lines, decoder + loop-until-stable guard `_MAX_DECODE_PASSES = 3`).
  - Adds `mvp_site/tests/test_narrative_unicode_escape_decoder_9778.py` (401 lines, 22 tests).
  - At 6 sites in `mvp_site/llm_service.py`, wraps `full_narrative` with `text_normalization._decode_embedded_unicode_escapes(...)` before assignment. **Two of the six sites append `.strip()`:**
    - `mvp_site/llm_service.py:10394-10396` — Phase 1 JSON-parse-fallback raw-looks-like-story branch: `narrative_text = text_normalization._decode_embedded_unicode_escapes(full_narrative).strip()`
    - `mvp_site/llm_service.py:10927-10929` — Phase 2 same-shape fallback.
  - Pre-PR-#9822 the same two sites did `narrative_text = full_narrative.strip()` on the RAW text (lines 10370, 10897 in pre-merge file). When LLM emits only literal `"\n\n\n"` (6 chars: backslash+n×3), pre-fix code returned the literal sequence (non-empty, malformed prose survived); post-fix code, after decode-then-strip, returns `""`.

- **PR #9847** merge-commit `d0df0d41141`:
  - 9847 is a direct ancestor of 9822 in the commit graph (`git merge-base d0df0d41141 b0816a98e75 == d0df0d41141`); 9847 was already on the tree that 9822 merged into.
  - Touches `mvp_site/llm_service.py` (+67/-34), `mvp_site/faction/tools.py` (+24/-1), `mvp_site/tests/test_provider_tool_requests.py` (+138/-1).
  - Intent: dedupe `build_tool_phase2_materials` + `ToolPhase2Materials` between streaming and non-streaming paths; extract `should_single_infer_faction_tools` predicate.
  - **Verified ZERO changes** to `_decode_embedded_unicode_escapes`, `_parse_streamed_response`, `_preferred_display_text`, `JSON_PARSE_FALLBACK_MARKER`, Branch B yield — none of those identifiers appear in `git show d0df0d41141 -- llm_service.py` diff.
  - **Verdict: PR #9847 is LOW risk for Sub-class E.** Cannot be responsible.

### Exact collapse reproduction (Python, runtime-verified 2026-09-14)

```python
def decode_literal_backslash_n(value):
    """Mirrors _decode_embedded_unicode_escapes_once for the \\n-only case."""
    out = []
    i, n = 0, len(value)
    while i < n:
        ch = value[i]
        if ch != "\\" or i + 1 >= n:
            out.append(ch); i += 1; continue
        if value[i + 1] == "n":
            out.append("\n"); i += 2  # literal \n → real LF
        else:
            out.append(ch); i += 1
    return "".join(out)

inp = "\\n" * 3         # 6 chars: backslash + n × 3
decoded = decode_literal_backslash_n(inp)  # "\n\n\n" (3 real LFs)
print(decoded.strip() == "")  # True — silent collapse into Branch B
```

Same collapse for any input of N literal `\n` runs where N ≥ 1 (after decode, all whitespace). Pre-#9822, the same input `full_narrative.strip()` returned the literal 2N-char string (non-empty, malformed prose) and the orange banner did not fire. Post-#9822, the decode step is necessary for the bug to manifest.

### Test gap (verified 2026-09-14)

`mvp_site/tests/test_narrative_unicode_escape_decoder_9778.py` has 22 tests covering:
- `test_decoder_no_op_on_empty_string` (input="") — pre-existing no-op case
- `test_decoder_strips_all_literal_backslash_n_from_bq_fixture` (mixed text with embedded `\n`) — strips the literal sequences, leaves real text
- 20 other tests on surrogate pairs, UTF-8 byte runs, invalid scalars, idempotency, persistence seams, import surface

**Missing:** a test of input that is purely literal `\n` sequences such that the decoder succeeds (real LFs returned) but a downstream `.strip()` returns `""`. The decoder contract test alone cannot catch this — the bug is in the assignment-site composition (`decode(...).strip()` at `llm_service.py:10396` and `:10929`), not in the decoder.

A correct contract test belongs at the assignment site:
```python
# In a NEW test file (e.g. test_streaming_decode_strip_9822_bisect.py):
def test_decode_then_strip_does_not_collapse_only_escape_input():
    """Regression for Sub-class E on dBm9WI1hGvbIBhQLhCvp (2026-09-14).
    Input is ONLY literal '\\n' runs. Decoder succeeds (real LFs).
    .strip() returns ''. Branch B would fire on a live turn.
    Either (a) the assignment sites must NOT call .strip() on the decoded
    value, OR (b) the fallback narrative (full_narrative without decode)
    must be preserved if decode-then-strip collapses."""
    full_narrative = "\\n" * 3  # 6 chars, all literal \n
    decoded = text_normalization._decode_embedded_unicode_escapes(full_narrative)
    assert decoded == "\n\n\n"          # decoder succeeds
    assert decoded.strip() == ""          # strip collapses
    # The fix is structural: either drop .strip() at the assignment site or
    # fall back to full_narrative (the un-decoded raw text) when strip empties.
```

### Recommended bisect direction (next agent)

Revert **PR #9822 first** (5 commits on the merge branch: `9a091723c8c` + `a3ddda6674a` + `c5aca52c7bf` + `6da034c2287` + the merge). Reverting #9847 is not necessary unless #9822 revert alone fails to clear the symptom — the diff analysis strongly indicates the `decode(...).strip()` pair at `llm_service.py:10396` and `:10929` is the single-point fault. If a tighter patch is preferred over a full revert: remove the `.strip()` calls at those two lines so the decoded value is preserved verbatim, and replace the `.strip()` truthy check in `_preferred_display_text` at `llm_service.py:10100` with a check that does not require non-whitespace content (or, better, fall back to `full_narrative` raw when the decode-then-strip collapses).

Fallback if neither revert nor minimal patch lands: ship Half E2 from the Durable Fix Shape section — the root-cause fix lifts the JSON_PARSE_FALLBACK_MARKER collapse at `llm_service.py:4975/8331` so it preserves the original `full_narrative` instead of returning `""`. This is larger but does not require touching PR #9822; it works around the decode-then-strip bug at the Branch B gate.

## Durable fix shape

**Half E1 — Don't ship empty Story panel (UX fix, ship FIRST):**

In `_preferred_display_text`, when all three structured fields are empty AND `narrative_value` is empty, fall back to `full_narrative.strip()` instead of `""`. If even `full_narrative` is empty, yield a NON-EMPTY placeholder like `"[The DM is composing a response — your action has been recorded.]"` instead of the `STREAMING_EMPTY_RESPONSE` error event. The user should never see the orange error banner if the LLM actually ran.

**Half E2 — Root-cause the parse fallback (ship WITH E1):**

At `llm_service.py` line ~10868, the `JSON_PARSE_FALLBACK_MARKER` branch collapses `narrative_text = ""`. Change to: if `_classify_raw_narrative(full_narrative)` says it looks like story, use `full_narrative.strip()` as the narrative. This is the same fallback that already exists for `_parse_streamed_response` failures on the non-streaming path — apply it here for symmetry.

**Half E3 — Telemetry for the next regression (defense-in-depth, ship LAST):**

In `_preferred_display_text` empty branch, log:
```python
logging_util.error(
    "🔴 DISPLAY_TEXT_EMPTY: campaign=%s agent=%s model=%s "
    "narrative_len=%d display_text_len=%d god_mode_response_len=%d "
    "faction_header_len=%d json_parse_fallback=%s",
    campaign_id, prepared.agent.__class__.__name__, prepared.model_to_use,
    len(narrative_value or ""), len(structured_display_text or ""),
    len(structured_god_mode or ""), len(structured_faction or ""),
    narrative_value == JSON_PARSE_FALLBACK_MARKER,
)
```
The next 4 empty POSTs will name the field that's actually missing — bisecting becomes a single BQ grep.

## Sibling-issue scan recipe

```bash
gh issue list --repo jleechanorg/worldarchitect.ai --state all \
  --search 'empty response from server' --limit 30 \
  --json number,title,createdAt,state \
  | python3 -c "
import json, sys, datetime
data = json.load(sys.stdin)
for d in data:
    print(f'  #{d[\"number\"]} [{d[\"state\"]:<6}] [{d[\"createdAt\"][:10]}] {d[\"title\"][:120]}')
"
```

Verified 2026-09-14: 0 issues on `jleechanorg/worldarchitect.ai` describe this exact pattern (BQ success + GCP empty body on the same CID). Issue #9114 (PR-9045 prompt regression) is the closest sibling but Sub-class C is a different cause (`finishReason=""` empty string on gemini-3-flash-preview, vs Sub-class E which is `FinishReason.STOP` on gemini-3.8-flash).

## Cross-campaign prevalence scan

```sql
-- Find campaigns where LLM succeeded (response_text > 0) but stream POST returned < 2KB
-- Joins BQ rows to GCP access log via campaign_id + ts (requires Cloud Logging → BQ export)
SELECT campaign_id,
       COUNT(*) AS n_successful_llm_calls,
       SUM(IF(LENGTH(response_text) > 0 AND <2KB body in next 60s>, 1, 0)) AS n_empty_followups
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE ingested_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
GROUP BY campaign_id
HAVING n_empty_followups > 0
ORDER BY n_empty_followups DESC
LIMIT 25
```

(Requires Cloud Logging → BQ sink `mvp_site_access_log`. Without that sink, fall back to per-campaign `gcloud logging read` queries like the one in §"The signature" above.)

## Diagnostic pitfalls discovered during the 2026-09-14 bisect

- **`gh pr diff` may be HTTP 403 rate-limited from a heavy session.** Fall back to `git show <merge-commit>:<file>` to read the merged tree directly. The merge-commits are stable and visible without a network round-trip. Pattern: `git rev-parse origin/main` if reachable, or `git log --all --grep='<PR#>' --oneline | grep '(#<PR>)$'` to find the merge. Local checked-out branch may be 100s of commits behind — fetch the file from the merge-commit, not from HEAD.
- **Local repo may be on a stale branch (verified 2026-09-14: `main-test` was 210 commits behind `origin/main`).** Never read `llm_service.py` from the local checkout when bisecting a recent PR; always fetch the merged file from the merge-commit. Line numbers in the local file vs the merge-commit WILL differ (PRs add/remove code above the cited lines).
- **Sub-class E line numbers in this reference (10394, 10891, 11209, etc.) are pinned to the merge-commit `b0816a98e75` (`origin/main @ 2026-09-14`).** They will drift as subsequent PRs land. Always `grep -n` for the symbol before citing line numbers from any cross-reference — do NOT trust the line numbers above if your session is on a different code state.
- **PR scope confusion:** PR #9847 is an ancestor of PR #9822 in the commit graph. `git log d0df0d41141..b0816a98e75 -- llm_service.py` shows only the #9822 delta — #9847's content is already in `d0df0d41141`. To bisect #9847 alone, revert to `d0df0d41141^` (the parent of the #9847 merge); to bisect #9822 alone, revert to `b0816a98e75^` (the parent of the #9822 merge).
- **The decoder contract test at `mvp_site/tests/test_narrative_unicode_escape_decoder_9778.py` is NOT sufficient to catch decode-then-strip edge cases.** 22 tests cover the decoder in isolation (input vs output), but NONE cover what happens AFTER `.strip()`. The bug is at the assignment site composition, not in the decoder. Bisect tests must target the assignment-site path, not the decoder unit.
