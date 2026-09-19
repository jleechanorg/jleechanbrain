# Prompt-template schema mismatch — Phase 0 condition 7

**Verified on:** [jleechanorg/worldarchitect.ai issue #9099](https://github.com/jleechanorg/worldarchitect.ai/issues/9099) + PR [#9102](https://github.com/jleechanorg/worldarchitect.ai/pull/9102), campaign `s3yGfUXCGmeqFO1Hn93m` (House Targaryen / Rhaenyra character creation), 2026-08-18 ~22:55 PT.

## What this class is

A prompt file in `mvp_site/prompts/` teaches the LLM a **non-canonical variant** of a structured field's schema (e.g. `choices` as object-with-keys instead of canonical array-of-objects). The runtime parser at `narrative_response_schema.py` **silently accepts both forms** via normalization (`isinstance(raw_choices, dict)` → iterate keys → auto-populate `id`). Downstream the frontend (which iterates `choices[]`) breaks because the served field is sometimes emitted as a JSON-stringified blob with non-standard separators.

Distinct from conditions 5 and 6:
- **Condition 5 (LLM already received the rule):** the rule WAS in the prompt; the LLM ignored it; the fix is NOT a content patch.
- **Condition 6 (wrong-tier from a multi-tier decision tree):** the rule WAS in the prompt; the LLM picked the wrong tier; the fix IS a content patch (trigger-phrase vocabulary + worked example).
- **Condition 7 (prompt teaches non-canonical schema variant):** the prompt IS the bug; the rule it teaches is the wrong shape; the fix is a content patch (rewrite the worked example + add a HARD rule pinning the canonical shape).

## Symptom signature

User-facing UI: rendered choice text is the raw JSON of the array, with internal separator duplicated:

```
1.  {"text": "Edit Character", "description": "Adjust Rhaenyra's stats, spells, or backstory before starting."}: {"text": "Edit Character", ...
2.  {"text": "Finish Character Creation and Start Game", "description": "Confirm your status and descend into the political fire of King's Landing."}: {"text": "Finish ...
```

Trailing `: {"text": ...` is the array re-emitted with `", "` rewritten to `": "`, then the whole string dropped into `choices[0].text`.

Backend-side: BQ often shows ZERO rows for the affected campaign (verified on #9099 — `SELECT COUNT(*) WHERE campaign_id='s3yGfUXCGmeqFO1Hn93m'` returned 0). This is a **client-side / parser-normalization** bug; the LLM may never have produced the malformed string in this exact shape — the symptom can also be the parser's normalization leaking the dict-as-string into the served payload.

## Phase 0 condition 7 — verify the prompt teaches the canonical schema

Three sub-checks MUST all pass before this skill applies (and the fix is a content patch):

1. **Cross-prompt shape grep:** `grep -n '"choices"' mvp_site/prompts/*.md`. Look for `"choices": {` (object-with-keys) vs `"choices": [` (array-of-objects). If BOTH appear across files, you have the bug class — the LLM is being taught two conflicting shapes. The fix is to rewrite the wrong-shape worked examples to match the canonical schema.
2. **Parser normalization audit:** `grep -n 'isinstance(raw_choices' mvp_site/narrative_response_schema.py mvp_site/llm_parser.py`. If the parser accepts both forms via `isinstance(raw_choices, dict)`, that's the silent-accept path that masks the prompt-template bug. The parser isn't wrong (it must accept both forms for backward compatibility with #8353 / #7710 / other sibling fixes that rely on dict acceptance) — the fix is upstream in the prompt.
3. **Canonical schema cross-check:** confirm the canonical schema file (`planning_protocol.md` CHOICE_SCHEMA, `narrative_response_schema.py`, `agent_prompts.py` CHOICE_SCHEMA export) actually uses the array form. If the canonical schema says "array" but the prompt's worked example says "object-with-keys", that's the bug.

If all three sub-checks confirm the class, condition 7 applies — the fix is a content patch. Skip the copy-campaign step (the bug never reaches the backend in this exact shape; BQ shows 0 rows; copy-replay would burn 5+ minutes for no evidence).

## Real-Gemini-API RED proof recipe (per `/rg` RULE 8)

When the user authorizes direct Gemini API (or when the deployed path can't run an LLM turn locally), the canonical RED proof is **two live Gemini calls with the served-prompt fragment** — one against the OLD prompt (stashed), one against the NEW prompt:

```python
import os, json, urllib.request, urllib.error

KEY = os.environ["GEMINI_KEY"]  # from `gcloud secrets versions access latest --secret=gemini-api-key --project=worldarchitecture-ai`
prompt_text = open("mvp_site/prompts/character_creation_instruction.md").read()
# Extract just the planning-relevant section to keep prompt <32K
system_section = prompt_text[prompt_text.find("**MANDATORY CHOICE FORMAT**"):prompt_text.find("## Manual Character Creation Flow")]
user_request = (
    "The character has been auto-created (Elf Wizard, L1, ability scores 14/12/13/10/10/8). "
    "Equipment and gold are auto-fixed. Now emit your planning_block so the player can confirm or edit. "
    "Use the exact baseline choice IDs `edit_character` and `start_adventure`."
)

url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key={KEY}"
body = {
    "contents": [{"parts": [{"text": system_section + "\n\n---\n\nUSER REQUEST:\n" + user_request}]}],
    "generationConfig": {"temperature": 0.2, "responseMimeType": "application/json"},
}
req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=60) as resp:
    text = json.loads(resp.read())["candidates"][0]["content"]["parts"][0]["text"]
    parsed = json.loads(text)
    choices = parsed["planning_block"]["choices"]
    assert isinstance(choices, list), f"FAIL: LLM emitted choices as {type(choices).__name__}, expected list"
    assert all("id" in c and "text" in c for c in choices), "FAIL: missing required fields"
```

**Verified worked example (PR #9102):**

| Prompt version | Gemini 2.5 Flash emitted `choices` as | Result |
|---|---|---|
| OLD (`character_creation_instruction.md` with object-with-keys example at 4 worked examples) | `dict` (object with `id` keys) | Parser normalizes; sometimes leaks as raw text to frontend |
| NEW (array form at all 4 worked examples + explicit `MANDATORY CHOICE FORMAT` rule) | `list` of 2 objects with `id`/`text`/`description` | Canonical form, UI-iterable |

**Worktree discipline for RED control:** use `git stash` to revert the prompt fix, run the OLD-prompt call, `git stash pop` to restore the fix, run the NEW-prompt call. Capture both responses verbatim in the PR body — this is the audit trail that proves the LLM-behavior change came from the prompt, not from random variation.

## 4-component durable fix shape (mirrors PR #9068)

1. **Prompt file** — convert every worked example to canonical schema + add an explicit `MANDATORY CHOICE FORMAT` rule pinning the schema and required fields. Keep the change minimal: array brackets + add explicit `id` to each object.
2. **Canonical schema mirror** — only needed if the canonical schema file (`planning_protocol.md`) was wrong; in this class it usually isn't (canonical was right, agent-specific prompt was wrong).
3. **Contract test** — pin the prompt file's schema contract (see recipe below).
4. **PR body** — verbatim OLD-prompt Gemini response + verbatim NEW-prompt Gemini response + the regex-extracted diff from `_extract_choices_form()` showing the `dict → list` switch + the sibling-issue list (`gh issue list --search "planning_block"`) showing this PR is the missing branch in the cluster.

## Contract-test recipe (TDD layer for the prompt contract)

```python
import os, re, unittest

def _resolve_repo_root():
    env = os.environ.get("HERMES_REPO_ROOT")
    if env and os.path.isfile(os.path.join(env, "mvp_site/prompts/character_creation_instruction.md")):
        return env
    cur = os.path.dirname(os.path.abspath(__file__))
    for _ in range(8):
        cur = os.path.dirname(cur)
        if os.path.isfile(os.path.join(cur, "mvp_site/prompts/character_creation_instruction.md")):
            return cur
    return "${HOME}/projects/worldarchitect.ai"

REPO_ROOT = _resolve_repo_root()
PROMPT_PATH = os.path.join(REPO_ROOT, "mvp_site/prompts/character_creation_instruction.md")


def _extract_planning_block_examples(prompt_text):
    blocks = re.findall(r"```json\s*(\{[\s\S]*?\})\s*```", prompt_text)
    return [b for b in blocks if '"planning_block"' in b]


def _extract_choices_form(planning_block_json):
    """Return the leading char of the choices value: `[` for array, `{` for object."""
    match = re.search(r'"choices"\s*:\s*([\[{])', planning_block_json)
    return match.group(1) if match else None


class TestPlanningBlockChoicesCharacterCreationArray(unittest.TestCase):
    def test_every_worked_example_uses_array_form(self):
        with open(PROMPT_PATH) as f:
            text = f.read()
        examples = _extract_planning_block_examples(text)
        self.assertGreaterEqual(len(examples), 2)
        for idx, ex in enumerate(examples):
            form = _extract_choices_form(ex)
            self.assertEqual(
                form, "[",
                f"Example #{idx + 1} has choices as object-with-keys, not array. "
                "Fix: rewrite to canonical PlanningChoice schema (array of {id, text, description}).",
            )

    def test_every_choice_object_has_id_field(self):
        with open(PROMPT_PATH) as f:
            text = f.read()
        for ex in _extract_planning_block_examples(text):
            if '"choices"' not in ex:
                continue
            m = re.search(r'"choices"\s*:\s*\[(.*?)\]\s*,?\s*"', ex, re.DOTALL)
            if not m:
                continue
            self.assertGreaterEqual(
                len(re.findall(r'\{\s*"id"\s*:', m.group(1))),
                1,
                "Every choice object in worked examples must carry an `id` field",
            )
```

## Pitfalls

- **Don't claim "parser is wrong" first.** When the user reports malformed `choices`, the parser-acceptance pattern looks suspicious, but the fix is upstream. The parser was designed to accept both forms (the dict-form is sometimes legitimate as a fallback). Changing the parser would break #8353 / #7710 / other sibling fixes that rely on dict acceptance. Fix the prompt.
- **Don't copy-campaign if BQ shows 0 rows for the campaign.** #9099 had 0 rows in `worldarchitecture-ai.llm_forensics.llm_payloads` — the bug never reached the backend in the user's exact session. The symptom came from earlier-turn state or parser-side normalization. Skip the copy-campaign step (it would burn 5+ minutes for no evidence) and go straight to static-evidence + prompt audit.
- **Don't trust the user's exact screenshot text as the LLM's actual emission.** The screenshot in #9099 showed `": "` as the array separator, which is not what `json.dumps` produces. The actual emission was likely the dict-form being normalized and then re-stringified somewhere in the streaming merge path (`llm_parser.py:1977` `normalize_planning_block_choices` is one candidate). The screenshot is a clue, not proof.
- **Worktree `./run_tests.sh` works.** Unlike pytest from the main checkout, `./run_tests.sh` resolves to the worktree's venv cleanly. Verified on PR #9102.
- **`responseMimeType: application/json` forces structured output.** Without it, Gemini may emit the choices wrapped in prose. With it, the response is a parseable JSON object directly. Verified.
- **Active factory PR may cover some planning_block surfaces but not all.** PR #9068 (`factory/dark-factory-bi3e-r4`) covers God Mode + level-up. The character-creation branch needs a separate PR — that's the missing piece #9102 fills. Link both in the cluster signal.

## Coverage map (no regressions verified on PR #9102)

```
✓ test_planning_block_choices_format.py
✓ test_planning_block_normalization.py
✓ test_planning_block_robustness.py
✓ test_planning_block_analysis.py
✓ test_planning_block_streaming_passthrough.py (4s)
✓ test_planning_block_validation_integration.py (3s)
✓ test_planning_block_completed_milestone_7373.py
✓ test_planning_block_future_leak_7763.py
✓ test_planning_block_canonical_state_anchor_8444.py
✓ test_planning_blocks_ui.py
✓ test_planning_block_choices_character_creation_9099.py (this PR)
```

## When to load this reference

- User reports "planning_block choices malformed" / "choices rendered as JSON" / "strategic choices panel shows raw text".
- `grep '"choices"' mvp_site/prompts/*.md` shows BOTH `"choices": {` and `"choices": [` across files (the conflicting-schema tell).
- BQ `llm_payloads` returns 0 rows for the campaign — symptom is client-side / parser-side, not server-side.
- Active factory PR covers some planning_block surfaces but not all — this PR is the missing branch in the cluster.
- User authorizes direct Gemini API for the RED proof.

## Worked example — jleechanorg/worldarchitect.ai PR #9102 (2026-08-18)

Trigger: Jeffrey said *"Lets root cause and mke a new PR to /rg fix and you can use real gemini api"* on issue #9099 (planning_block.choices malformed on character creation, campaign `s3yGfUXCGmeqFO1Hn93m`).

- **Phase 0 condition 5 (LLM-already-received):** the LLM was emitting the wrong shape, but the prompt was teaching the wrong shape. Condition 5 doesn't directly apply (the LLM DID follow what the prompt said — the prompt was just wrong).
- **Phase 0 condition 7 (NEW, this reference) verified:** cross-prompt grep showed `"choices": {` in 4 worked examples of `character_creation_instruction.md` + `"choices": [` in `planning_protocol.md` canonical example. Parser normalization audit confirmed `narrative_response_schema.py:3983` accepts both forms. Canonical schema cross-check confirmed `planning_protocol.md` array form is correct. All three sub-checks pass.
- **Phase 1 worker attempt 1 (max-turns 12, the gateway itself acts as editor — no claudem worker used):** ran `./run_tests.sh` first to confirm baseline green (1/1 existing planning_block tests pass). Wrote the contract test `mvp_site/tests/test_planning_block_choices_character_creation_9099.py` (154 lines, 4 assertions). Initial regex extraction had a bug (extracted `:` not `[`); patched. Test ran: 1/1 FAIL on `test_planning_block_examples_use_array_choices` — RED proof captured. Patched all 4 worked examples to array form + added `MANDATORY CHOICE FORMAT` rule. Test re-ran: 1/1 PASS — GREEN proof captured.
- **Phase 2 (no worker, gateway is editor):** all 4 prompt examples converted to array form + 1 new mandatory rule added. No regressions in 10 sibling `test_planning_block_*.py` files. Real-Gemini-API red control: stashed the fix, ran Gemini 2.5 Flash with OLD prompt → LLM returned `choices` as `dict`. Restored fix, re-ran Gemini → LLM returned `choices` as `list` of 2 objects with `id`/`text`/`description`. Both responses captured verbatim in PR body.
- **Phase 3 (gateway is shipper — no claudem worker used because this was a single-file content fix):** committed with `claudem/minimax-M3:` prefix per the commit-provenance rule. 2 files / +186/-22. Pushed to `fix/planning-block-choices-character-creation-9099` branch on `origin/main`.
- **Phase 4 verify:** `git rev-parse origin/<branch>` == local SHA. `gh-safe-publish pr create` succeeded (graphql budget 1081/5000, plenty). PR [#9102](https://github.com/jleechanorg/worldarchitect.ai/pull/9102) opened, `state=OPEN, draft=false, mergeable=MERGEABLE`. No CI yet (pending Green Gate).
- **Phase 5 reply:** PR URL + commit SHA + file list + RED/GREEN test proof + Gemini response verbatim quotes + cluster signal + sibling issue list + status cron `9401daeddf3c` armed for +25m. `Pending — needs your PR review + merge to apply.`

Total: 1 worker dispatch (the contract-test RED pass) + 1 real-Gemini-API red control + 1 GREEN pass = 3 turn-compression checkpoints, all in one session. The 4-component deliverable shape landed in a single PR.

The skill that makes the difference here vs condition 5 (LLM-already-received-the-rule) is **condition 7's distinct diagnostic surface**: the prompt IS the bug, not the LLM's attention to it. The fix shape is identical to conditions 5/6 (content patch + worked example + contract test + PR body), but the Phase 0 sub-checks are different (cross-prompt grep + parser normalization audit + canonical cross-check instead of BQ request-payload grep).
