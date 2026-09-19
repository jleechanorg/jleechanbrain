---
name: prompt-discovery-prompt-fix-delivery / contract-test-rule-shape-changes
version: 1.0.0
date: 2026-08-20
trigger: when a user asks to handle review-thread comments that change the SHAPE of a prompt rule (e.g. "make X freeform", "remove the fixed list", "drop the code pointer") — the contract test that pinned the OLD rule shape must be updated IN THE SAME COMMIT.
---

# Contract test must change with the rule shape

When a user correction flips a prompt rule from one shape to another
(e.g. fixed enum → freeform string, file-pointer → inline rule,
mandatory output → optional output), the contract test that asserted
the OLD shape will block the change at `pytest` time. The patch and
the test edit are one commit.

## Anti-pattern (verified PR #9101, 2026-08-20)

A PR shipped with a contract test
`test_pc_arc_prompt_references_eight_arc_types` that asserted all 8
arc-type enum names were present in the served prompt. The user posted
an inline comment: *"llm should freeform make arcs not pick them from a
list"*. The fix removed the 8-arc enum and replaced it with a freeform
rule — but the contract test still expected the old enum, so the test
suite went red.

The fix is **rename the test and rewrite the assertion**:

```python
# Before (asserts OLD shape — now wrong):
def test_pc_arc_prompt_references_eight_arc_types(self):
    content = _load_instruction_file(PROMPT_TYPE_PLAYER_CHARACTER_ARCS)
    for arc_type in constants.COMPANION_ARC_TYPES:
        assert arc_type in content or "COMPANION_ARC_TYPES" in content

# After (asserts NEW shape — matches user's correction):
def test_pc_arc_prompt_declares_freeform_arc_type(self):
    content = _load_instruction_file(PROMPT_TYPE_PLAYER_CHARACTER_ARCS)
    assert "Freeform arc type" in content
    assert "never pick from a fixed list" in content
    assert "COMPANION_ARC_TYPES" not in content   # negative pin
    # The four canonical phases stay fixed.
    for phase in constants.COMPANION_ARC_PHASES:
        assert phase in content
```

Three principles for the rewrite:

1. **Rename the test** so the failure message points at the new rule
   shape, not the old one. `test_pc_arc_prompt_declares_freeform_arc_type`
   beats `test_pc_arc_prompt_references_eight_arc_types` because the
   new name encodes the user's correction.
2. **Add a negative pin** when the user explicitly FORBADE something.
   `assert "COMPANION_ARC_TYPES" not in content` ensures the LLM
   doesn't get a runtime-enum pointer back in the served prompt.
3. **Keep invariant parts as positive pins**. The four canonical
   phases stayed fixed even though the arc_type went freeform — pin
   them explicitly so a future regression can't silently break the
   invariant.

## Where this fits in the skill

Phase 2 (gateway-as-editor verification) MUST add this check to the
verification list:

- [ ] Did the user's correction change the rule SHAPE, not just the
      rule TEXT?
- [ ] If yes: is the contract test renamed + assertion rewritten to
      pin the new shape?
- [ ] Is there a negative pin against the OLD shape (so a future
      re-introduction fails loudly)?
- [ ] Are the SHAPE-INVARIANT parts (e.g. canonical phases that
      stayed fixed) still pinned as positive assertions?

If any of these is missing, the shipper pass will leave the test
suite red and the PR will fail CI. Catch it in Phase 2 — before
shipping the commit.

## Worked example — jleechanorg/worldarchitect.ai PR #9101 (2026-08-20)

User correction: three inline review-thread comments on the PR's
served-prompt file.

| Comment | Rule-shape change | Test rename |
|---|---|---|
| "Don't include code pointers" (L56) | Drop runtime-enum pointer from `master_directive.md` template entry | (no test pins this line) |
| "llm should freeform make arcs" (L5) | 8-arc fixed enum → freeform noun phrase | `references_eight_arc_types` → `declares_freeform_arc_type` |
| "llm wont know this code" (L98) | Drop entire `## Cross-Reference` section | (no test pins this section) |

End state: 6 surgical patches, 1 commit (`53f6db2504`), all 226 prompt
tests green. 3 user review threads resolved via GraphQL
`ResolveReviewThread`. The gateway-as-editor pattern handled it in one
pass — no worker dispatch needed because the scope was small
(3 files, +23/-22) and the contract test rewrite was mechanical.