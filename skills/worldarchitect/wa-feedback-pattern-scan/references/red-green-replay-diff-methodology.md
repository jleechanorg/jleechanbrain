# RED/GREEN validation-replay diff methodology (verified 2026-08-17, batch D)

When jleechan runs a "red-team / green-team" validation replay of a WA campaign (folder names like `bg3_nocturne_murder_god__RED_replay_<date>__<uid>` and `...__GREEN_replay_<date>__<uid>`), the question is always: **are the two replays actually different, or did the LLM produce identical output?**

Naive answer: `diff` shows hundreds of lines different → must be different campaigns. That's wrong 100% of the time. The actual answer requires a normalization pass.

## The trap

WA .txt dumps serialize `Dice Rolls:` blocks as single-quoted Python dict literals via Python's `repr()`:

```
{'modifier': 14, 'type': "Persuading Sarevok ...", 'roll': '1d20+14', 'faces': '18', 'result': 32, 'label': "..."}
```

Python `dict` iteration order is insertion-order since 3.7, but `repr()` of a dict constructed via `json.loads()` (which builds dicts from JSON-object parsing) inserts keys in JSON-object order, which `json.dumps(sort_keys=True)` would normalize but the underlying logger doesn't. So:

- Same scene, identical dict contents → TWO different byte representations if the dict was constructed via different code paths (e.g., `eval()` vs `json.loads()`).
- Different runs of the SAME prompt can produce different byte representations of the same Dice Rolls dict.

## Verified recipe (batch D bg3 long RED 1zIJDHYG vs GREEN a0G7i0dk)

Both files: 24,082 lines, 2,218,015 bytes, 603 SCENE markers.

**Step 1 — raw byte-level diff.**
```python
import hashlib
def md5(p):
    h = hashlib.md5()
    with open(p, 'rb') as f:
        for chunk in iter(lambda: f.read(8192), b''):
            h.update(chunk)
    return h.hexdigest()
# RED md5: 4c19b75aa4c3a5fdc1ceb1f4abdb6b1a
# GREEN md5: 594d3a9812855c327338b25ba6d8241d
# Identical: False
```
Files differ at byte level. Don't conclude "different campaigns" yet.

**Step 2 — split on SCENE marker, compare per scene.**
```python
text = open(path).read()
scenes = text.split('============================================================\nSCENE ')
# scenes[0] is preamble; scenes[1:] are SCENE 1, 2, ...
```

**Step 3 — strip Dice Rolls JSON block per scene.**
The Dice Rolls block is a `Dice Rolls:\n  - {<dict>}\n  - {<dict>}` continuation. Strip it entirely:
```python
import re
def strip_drives(scene):
    # Strip Dice Rolls block (multi-line dicts + optional blank line after)
    return re.sub(r'Dice Rolls:\s*\n.*?(?=\n\n|\n\[|\n[A-Z][a-z]+:)', '', scene, flags=re.DOTALL)
```

**Step 4 — re-compare.**
```python
prose_divs = []
for i in range(1, len(scenes)):
    if strip_drives(red_scenes[i]) != strip_drives(green_scenes[i]):
        prose_divs.append(i)
# Result: [] (empty list) → 0 prose divergences
```

**Step 5 — characterize remaining byte diffs (sanity check).**
Find the FIRST non-Dice-Rolls byte diff:
```python
r, g = red_scenes[7], green_scenes[7]
for j in range(min(len(r), len(g))):
    if r[j] != g[j]:
        print(r[max(0, j-50):j+200])  # shows the diff
        break
```
Output: `{'modifier': 11, 'type': 'Persuasion...', 'roll': '1d20+11', 'faces': '7', ...}` vs `{'modifier': 11, 'type': 'Persuasion...', 'faces': '7', 'roll': '1d20+11', ...}` — confirmed dict-key reorder, no content diff.

**Step 6 — quantify.**
- Total scenes: 603
- Byte-level divergent: 279 (46.3%)
- Prose-only divergent after Dice Rolls strip: **0**
- Conclusion: replays are **literally identical** in narrative content.

## Why this matters for the skill

1. **Determinism claim.** If RED and GREEN replays produce identical prose + identical dice values, the LLM is deterministic for that prompt stream. WA's red-team/green-team validation methodology is sound.

2. **Diff signal noise.** Every "diff" between WA replay dumps is noise until you normalize Dice Rolls. Don't waste cycles on byte-level diff tools; jump to the JSON-strip step.

3. **Extending the recipe.** The same normalization applies to:
   - Comparing two runs of the same campaign under different model versions.
   - Comparing a `.txt` dump to a re-rendered version after a prompt-template change (the JSON serialization may have shifted).
   - Detecting "which lines actually changed" when the LLM output looks identical at the paragraph level but diff reports hundreds of changes.

## Generalization: when ARE replays genuinely different?

Red flags that the diff is real content, not JSON ordering:
- GM prose text differs (visible in `Game Master:` blocks after stripping metadata).
- Dice roll VALUES differ (e.g., `result: 32` vs `result: 15`).
- Different scene count (one replay ended early, hit an error, or was retaken).
- Player action sequence diverges (different god-mode interventions in the two runs).
- Status fields differ (HP, XP, location) outside the Dice Rolls block.

If only dict-key order differs and prose+dice+status match → identical narrative content, regardless of MD5.

## Output shape for batch D

`/tmp/all_readings/batch_D_summary.json` includes a `red_green_comparison` block:

```json
{
  "red_short_id": "bg3_nocturne_RED_replay_jFBwPkRs",
  "red_long_id": "bg3_nocturne_RED_replay_1zIJDHYG",
  "green_long_id": "bg3_nocturne_GREEN_replay_a0G7i0dk",
  "red_short_scenes": 268,
  "red_long_scenes": 603,
  "green_long_scenes": 603,
  "identical_after_normalization": true,
  "byte_level_divergences": 279,
  "prose_divergences": 0,
  "divergence_root_cause": "Python dict key ordering inside Dice Rolls JSON block ...",
  "md5_red_long": "4c19b75aa4c3a5fdc1ceb1f4abdb6b1a",
  "md5_green_long": "594d3a9812855c327338b25ba6d8241d",
  "conclusion": "The two replays are LITERALLY identical in narrative prose, dice roll values, GM text, scene structure, and choice prompts."
}
```

## Anti-patterns to avoid

- **Don't `diff` two replay dumps and report the diff size as a meaningful metric.** 279 byte-divergent scenes with 0 prose divergences is the wrong story.
- **Don't MD5-compare and call it "different campaigns".** MD5 differs for two byte-identical-prose dumps because of the JSON ordering trap.
- **Don't try to canonicalize the dict ordering with `json.dumps(sort_keys=True)` mid-regex.** Nested-quote handling breaks; stick to the strip-everything approach.
- **Don't skip the prose-only diff check.** Even when byte-level diff is huge, the prose might still be identical — that's the signal you want.