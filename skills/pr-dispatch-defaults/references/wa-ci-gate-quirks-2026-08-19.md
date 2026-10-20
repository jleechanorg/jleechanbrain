# WorldArchitect.AI CI gate quirks (added 2026-08-19, PR #9098)

Three real-world failures that aren't obvious from the gate name alone. The
WA repo has a more complex presubmit matrix than the default `jleechanorg/`
template — these quirks only surface on `jleechanorg/worldarchitect.ai`.

## 1. `Prompt / Tool Contract Hash Validation` gate (silent version drift)

The presubmit gate (workflow: `Presubmit Checks`, job: `Prompt / Tool
Contract Hash Validation`) tracks versioned sha256 hashes of every file
that defines a prompt or tool contract. The manifest lives at
`mvp_site/schemas/prompt_tool_contracts.json`. Tracked files include:

- `mvp_site/narrative_response_schema.py` (parser/schema)
- `mvp_site/mcp_api.py` (MCP tool surface)
- `mvp_site/prompts/**` (LLM prompts)
- `mvp_site/schemas/prompt_tool_contracts.json` (the manifest itself)

Any commit that changes a tracked file's content (even whitespace, even
an import-order swap) invalidates its hash. The gate surfaces the failure
as `FAILURE` on the job name with no log line about which file drifted.
The check-runs API also returns the same — no actionable text.

**One-line fix** from the worktree root:

```bash
python3 scripts/validate_prompt_tool_contracts.py --update
```

The script recomputes every tracked hash, prints `old_hash -> new_hash`
per file, and rewrites the manifest. The diff is one or two lines per
file (a stale `version` and the new `version`). Commit it on the same
branch; on the next push the gate goes from `FAILURE` to `SKIPPED`
(file no longer in the changed-path set, or all contract files in
the diff are correctly hashed).

**When to anticipate it proactively** (don't wait for CI to fail):

- Adding a new field to a `mcp_api.py` tool schema
- Adding a new `prompt_tool_contracts.json` manifest entry
- Refactoring a function in `mvp_site.narrative_response_schema`
- Touching any file under `mvp_site/prompts/`

If the worker brief includes any of these, add the script to the
pre-push self-audit list so the worker runs it before `git push`.

**Why this isn't a generic CI failure**: the gate is silent. The natural
first reaction is to fetch the failing job's logs — which are often
gone by the time you look (GitHub's retention window). The script
exists exactly to avoid that loop. Hand-editing the manifest's `version`
field without recomputing the hash is the wrong fix and will be caught
by a re-run.

## 2. Multiple helpers with the same contract pattern

The "god mode narrative" contract (placeholder literal instead of empty
string when only `god_mode_response` is present) was re-implemented in
THREE different files in PR #9098. Each helper had the same shape:
takes a structured response, returns a string, branches on `is_god_mode`:

| Helper | File | Function |
|---|---|---|
| `_combine_god_mode_and_narrative` | `mvp_site/narrative_response_schema.py:4600` | parser |
| `_correct_god_mode_narrative_field` | `mvp_site/llm_service.py:1954` | post-parse correction |
| `_resolve_empty_narrative` | `mvp_site/world_logic.py:541` | action-flow fallback |

Updating only helpers 1 + 2 cost an extra CI cycle (helper 3 in
`world_logic.py:541` was the cause of 2 more CI failures, found only
when the test suite ran in the self-hosted `core-mvp-{1,2,3}` shards).
The contract name "god-mode narrative must be placeholder" is
implemented in 3+ files for 3+ different call sites in this codebase.

**Proactive sweep** before pushing a contract change:

```bash
# 1. Grep for the contract name in mvp_site/ — every file is a candidate
rg -i "god.mode.*narrative\|god.mode.response" mvp_site/ -l

# 2. For each candidate, look for a function that returns "" in
#    the same shape (returns string, has an is_god_mode branch, takes
#    a structured response)
rg -B2 -A15 "def _resolve.*narrative\|def _correct.*narrative" mvp_site/

# 3. Update all of them in the same commit. A single contract
#    change that updates 1 of 3 helpers is an incomplete fix.
```

**Why this matters for `/green`**: each incomplete fix costs a rebase +
force-push + CI roundtrip (5-10 min wall, 1 worker turn). The 5-minute
grep before the first commit saves 20+ minutes of CI roundtrips.

**When to anticipate it**: any time a PR is changing a string-emission
contract (placeholder, error message, default value) that the LLM
output flows through. The contract usually exists in 2-3+ files
because each call site (parser, post-parse, action-flow) has its own
fallback path.

## 3. MagicMock auto-truthy leaks when a helper starts branching on field types

When a helper starts branching on `isinstance(structured.narrative, str)`
or similar type checks, every test that uses `MagicMock()` for the
structured response silently starts failing. `MagicMock().narrative` is
not a string, so the `not isinstance(...)` branch flips to a different
return path. Same problem in reverse for `prepared.is_god_mode_command`:
a `MagicMock()` for the `prepared` object returns a truthy
`is_god_mode_command`, and any new "is_god_mode" branch in the helper
fires for non-god-mode tests.

**Symptom**: `AssertionError: '[God Mode turn — no narrative]' !=
'expected_value'` in tests that don't use god mode at all. The failure
mode is opaque — it looks like a contract bug, not a test setup bug.

**Fix**: when a test creates `MagicMock()` for an object whose
attributes feed into a new branch, set the relevant attributes
explicitly:

```python
prepared = MagicMock()
prepared.model_to_use = "gemini-3-flash-preview"
# ... other explicit attrs ...
prepared.is_god_mode_command = False          # explicit so the
                                              # is_god_mode branch
                                              # doesn't auto-fire

phase1_structured = MagicMock()
phase1_structured.tool_requests = [...]
phase1_structured.state_updates = {...}
# Set any field the new branch reads, with a real-typed value:
phase1_structured.god_mode_response = ""      # string, not MagicMock
phase1_structured.narrative = ""              # string, not MagicMock
```

**When to anticipate it**: any time a PR adds a new `isinstance` /
truthy check to a helper that downstream tests mock. Run the full test
file for that helper BEFORE pushing — the affected tests fail with
the assertion mismatch above and the failure mode is opaque.

## Diagnostic order when CI fails on `jleechanorg/worldarchitect.ai`

1. **Read the failing job name first** — it's the only signal GitHub
   gives you. Match against the quirks above before fetching logs.
2. **Run the local equivalent of the failing gate BEFORE re-running
   CI** — most WA gates have a corresponding `scripts/check_*.py` or
   `scripts/validate_*.py` entry point. Per SOUL.md "Slow/backlogged
   CI" rule: if any check has been queued >10 min, the local
   equivalent is mandatory. Don't wait.
3. **If the gate is in the presubmit matrix and the job name matches
   quirk #1 (Prompt / Tool Contract Hash Validation)**: skip the
   log fetch entirely, run the script, commit, push.
4. **If the gate is in the self-hosted MVP Shards (core-mvp-{1,2,3})**:
   log fetch is your only signal — the local equivalent doesn't
   exist. Be patient: those shards are queued behind the self-hosted
   runner pool and can take 15-30 min wall time.
5. **If the gate is `Design Doc Gate 0` and the diff is >50 non-test
   `mvp_site/*.py` lines**: see `pr-dispatch-defaults` SKILL.md
   "WA-specific pitfall: Design Doc Grep Gates Gate 0" — the PR body
   needs a `## Tenets` or `## Design Decision` section with a linked
   `.md` artifact, and the linked file must be committed on the
   branch.
