---
name: prompt-discovery-prompt-fix-delivery / prompt-level-ab-test
version: 1.0.0
date: 2026-08-20
trigger: when the user asks for "real AGY CLI provider proof" / "/test-realistic style" / "prove the prompt works without / with" — they want a side-by-side prompt-level experiment with real LLM calls, not a unit test or a Flask boot test.
---

# Prompt-level A/B test with real AGY CLI calls

When the user wants to prove a prompt rule actually changes LLM behavior,
the cheapest experiment is a prompt-level A/B: build the same served prompt
twice (variant WITH the rule, variant WITHOUT), send each to a real LLM
via AGY CLI, compare the structured-output fields. This skips Flask +
Firebase + warmup entirely.

## When this is the right tool

- The fix is **prompt-content** (a new section, a stricter rule, a removed
  enum) and you want real-LLM proof that the LLM emits (or stops emitting)
  a structured field because of it.
- The user explicitly asks for AGY CLI / Gemini / "real provider" evidence
  (NOT a unit test, NOT a Flask boot).
- The fix is small enough to fit in a single prompt without exceeding the
  LLM's context window (the example below uses ~3-4K chars per variant).

## When this is the WRONG tool

- The fix is **prompt-position** (recency-window mirror at end of 1MB prompt).
  A 3-4K prompt A/B will fully attend the rule in both variants; the
  production bug (rule at 99.7% offset, LLM tunes out) only reproduces
  in the FULL 1MB production prompt. Verified 2026-08-20 on
  PR #9101 cadence A/B: both variants emitted `companion_arc_event`
  in 2/3 turns because Gemini 3.7 Flash knew the rule from training
  data. The PR's value (recency-window mirror of the cadence rule from
  byte 700K into the dynamic-instruction channel) is invisible to a
  short-prompt A/B.
- The fix is **runtime behavior** (code-execution fallback, parser
  normalization, validator exemption matrix). Use the testing_mcp real-
  server recipes instead.
- The fix is **schema contract** (new required field, mandatory output).
  Use the BQ-aggregate-compliance sampling recipe.

## The 6-step recipe (verified PR #9101, 2026-08-20)

### Step 1 — Build two worktrees with a single variable

Both worktrees branched from the same PR head. The ONLY difference is the
prompt file under test:

```bash
git worktree add -b fix/<topic>-with  ~/projects/_wt<topic>_with \
    origin/<pr-branch>
git worktree add -b fix/<topic>-without ~/projects/_wt<topic>_no \
    origin/<pr-branch>
```

In the no-cadence worktree, replace the prompt file under test with an
HTML-comment stub (so the file exists but is empty):

```bash
# In _wt<topic>_no
cat > mvp_site/prompts/injection/<file>.md <<EOF
<!--
Disabled for the <topic> A/B experiment — intentional EMPTY so the
dynamic-instruction channel carries no <rule> echo. DO NOT restore this
file as part of any other task; the worktree is throwaway.
-->
EOF
```

### Step 2 — Symlink the venv (worktrees don't have their own)

```bash
cd ~/projects/_wt<topic>_with && ln -sf ${HOME}/projects/worldarchitect.ai/.venv .venv
cd ~/projects/_wt<topic>_no && ln -sf ${HOME}/projects/worldarchitect.ai/.venv .venv
```

### Step 3 — Build a scenario-anchored prompt body

The prompt body should:
- Mention the campaign state the LLM needs (companions, scene, character
  sheet).
- Mention the output schema the LLM must follow.
- **NOT** mention the rule under test — otherwise both variants emit
  identically because the LLM inferred the rule from the schema.

```python
STATIC_PROMPT_BODY = """
# WorldArchitect.AI -- Story Mode Continuation

You are the dungeon master.

## Campaign
Title: {title}
Current turn: {turn}

## Companions present
{companions_block}

## Output contract
Respond with JSON: {"narrative": ..., "planning_block": ..., "state_updates": ...}.
Dynamic-injection channel carries any time-bounded obligations that must fire on this turn.
"""
```

### Step 4 — Append the variable block for the WITH variant only

```python
def with_prompt(scenario, turn, cadence_block):
    return STATIC_PROMPT_BODY.format(...) + "\n\n## Cadence echo\n\n" + cadence_block
```

### Step 5 — Dispatch to AGY CLI (verified invocation pattern)

The `--dangerously-skip-permissions` flag is **NOT** needed for `--print`
mode — AGY's `--print` + `--json-schema` already enforce structured
output. The `--sandbox` flag prevents the LLM from drifting into
tool-use / codebase-grep side trips that swallow the LLM's real response
in tool logs.

```bash
agy --new-project \
    --model "Gemini 3.7 Flash (Medium)" \
    --sandbox \
    -p "<prompt>" \
    --output-format json \
    --json-schema '{"type":"object","properties":{...},"required":[...]}' \
    --print-timeout 120s
```

The response is JSON: `{"conversation_id": ..., "status": "SUCCESS",
"response": "<raw model text>", "structured_output": {...},
"duration_seconds": ..., "num_turns": ..., "usage": {...}}`. Extract
the `structured_output` field — that is the schema-conforming object
the LLM emitted. Naive parsing of `proc.stdout` as JSON works because
the envelope itself is JSON; `structured_output` is the schema-shaped
sub-object.

**Anti-patterns (verified 2026-08-20):**
- ❌ `--print` without `-p "<prompt>"` + stdin → AGY reads the prompt as
  background chatter and the LLM responds to a meta-question about CLI
  flags. Always pass the prompt via `-p` (or `--print`) explicitly.
- ❌ `--dangerously-skip-permissions` alone → model runs code-execution
  fallbacks, gets stuck on codebase greps, times out with `error:
  Grep command timed out`. Pair with `--sandbox` (or omit
  `--dangerously-skip-permissions`) for prompt-only experiments.
- ❌ `cwd=/tmp` for `agy --new-project` → still works (AGY uses a fresh
  project workspace), but `--new-project` flag is REQUIRED. Without it,
  AGY tries to read the caller's global CLAUDE.md and can hit a
  permission wall under `--dangerously-skip-permissions`.

### Step 6 — Count the structured fields and write the verdict

For each variant, count:
- `companion_arc_event` field presence (or whatever the test field is)
- `state_updates.<test_field>` initialization for the named entities

```python
def count_arc_events(resp):
    return 1 if "companion_arc_event" in resp else 0
```

Write the verdict as a Markdown table with totals row + interpretation
paragraph. Honest verdict matters more than a "PASS" stamp: if the
LLM emits the field in BOTH because it knows the rule from training
data, say so and propose the full-prompt A/B as follow-up. **Don't
pretend PASS** — that's the false-green trap.

## Worked example — PR #9101 cadence A/B (2026-08-20)

| Setup | Detail |
|---|---|
| Both worktrees | `origin/feat/wa-arc-cadence-lift` @ `8e0bfdf084` |
| WITH file | `injection/companion_arc_cadence.md` (1662 bytes, real cadence rule) |
| WITHOUT file | same file, stubbed to HTML comment (479 bytes) |
| Model | `Gemini 3.7 Flash (Medium)` via `agy --new-project --sandbox -p` |
| Scenario | 3 turns (N=2,3,4), 2 companions present, no active arcs |
| Variable | WITH variant appends the cadence file content to the prompt body; WITHOUT variant does not |

| Result | No cadence | With cadence |
|---|---|---|
| Turn 2 `companion_arc_event` | 0 | 0 |
| Turn 3 `companion_arc_event` | 1 | 1 |
| Turn 4 `companion_arc_event` | 1 | 1 |
| **TOTAL** | **2** | **2** |

**Verdict: INCONCLUSIVE** (not PASS). Both variants emitted the field.
The LLM knew the cadence rule from training data — the static body
hint plus the output schema was enough.

**Why the prompt-position bug doesn't reproduce:** the production fix
moves the cadence rule from byte 700K-820K of a 1MB prompt (99.7%
offset, lost-in-the-middle) into the dynamic-instruction channel
(recency window). A short-prompt A/B has the rule at byte 3500 of a
3500-char prompt in BOTH variants — fully attended, no recency issue.

**What would prove the fix:** a 1MB-prompt A/B where the control
variant has the cadence rule at 99.7% offset (matching production's
pre-PR state) and the treatment variant has it mirrored into the
dynamic-instruction channel (matching PR #9101's fix). Out of scope
for this targeted A/B.

## When the verdict is INCONCLUSIVE — what to do

Don't pretend PASS. The right output is:

1. State the counts plainly (both variants, total, per-turn).
2. State the interpretation (LLM inferred the rule from the schema,
   so the A/B can't isolate the prompt's contribution).
3. Propose the next experiment that WOULD isolate the contribution
   (the 1MB full-prompt A/B, or a controlled LLM-forgetting
   experiment).
4. Capture the evidence files for audit anyway — even inconclusive
   results are useful: a future session can compare what changed
   between this A/B and the next.

## Pitfalls

- **The LLM knows more than your prompt.** Modern Gemini / Claude / GPT-OSS
  variants are trained on D&D companion-arc patterns. A short prompt
  that mentions `companion_arc_event` in the output schema is enough for
  the LLM to freeform a reasonable cadence. To prove the prompt
  matters, you need either (a) the full 1MB production prompt where
  the rule's position matters, or (b) a smaller model with weaker
  training that doesn't already know the rule.
- **Static prompt body too rich.** If the static body already mentions
  the rule's effect, both variants emit. Make the static body
  deliberately SPARSE for the variable under test — the cadence echo
  in the WITH variant is the ONLY signal.
- **`{class}` in `.format()`.** Python's `str.format` treats `{class}` as
  a keyword. Use `{klass}` (or escape with `{{class}}`).
- **AGY `--print` mode stdin doesn't work.** Verified 2026-08-20: piping
  the prompt via stdin while `--print` is set results in the LLM
  responding to a meta-question about CLI tool flags. Use `-p
  "<prompt>"` instead.
- **`structured_output` not `response`.** AGY wraps the schema-conforming
  model output in `structured_output`. The `response` field is the raw
  model text (often includes tool-call meta-commentary). Extract
  `structured_output` for the test's assertion surface.

## File layout

Save the test script to a worktree at
`<repo>/testing_mcp/test_<pr>_<topic>_a_b.py` and run from there. The
evidence files go to `/tmp/<pr>_<topic>_a_b_evidence/` (not committed)
with a `VERDICT.md` summary for Slack-thread attachment.