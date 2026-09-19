# Edge-Case Spotters for Validator / Constructor / Serializer Reviews

Narrow reference for the Step 6 spot-check. Each entry is a 5-second probe
worth running on any PR that adds a validator, a constructor parameter, or a
default-fill behavior. Cover the spotter → bug pattern; reasoning is in the
PR review.

---

## Validators and conditional required-field lists

### 1. `field is None` vs missing key

**Spotter:**

```python
validated = {"mechanics": None, "reinterpreted": False}
required = ["mechanics"]
missing = [f for f in required if f not in validated]
# missing = [] — None IS in validated
```

**Bug:** Most required-field checks use `field not in validated`. They do
**not** catch `field = None`. So `{"mechanics": None}` passes the missing-field
guard but is semantically missing.

**Probe:** Construct a payload with `field: None` and check whether the warning
fires. If it doesn't, that's a half-fix — flag it.

**Fix:** Use `if field not in validated or validated[field] is None:`.

### 2. Empty string `""` vs missing key

**Spotter:** Does the validator treat `""` and missing the same way for string
fields? E.g. if `player_input=""` is supposed to mean "user input but empty"
vs "user input not recorded" and the validator accepts both without warning.

**Probe:** Construct a payload with `"player_input": ""` and one without the
key, and confirm the behavior is consistent and matches the documentation.

### 3. List defaulting — mutation hazard

**Spotter:** `default=[]` or `default=list()`. The default argument is
**shared across all instances** of the function or class — every call sees the
same list object. `validated.setdefault("audit_flags", [])` returning the same
list across calls is a mutation hazard.

**Probe:** Construct two instances with the same missing-key payload, verify
that `is instance1.audit_flags is instance2.audit_flags` is `False`.

### 4. `**kwargs` that swallow new params silently

**Spotter:** Constructors that end in `**kwargs: Any` quietly accept new
parameters and store them nowhere. The PR might add `requires_dice_resolution`
between existing params, the caller might pass it, but the constructor never
reads it — the value is silently dropped.

**Probe:** Pass the new param via `**kwargs`; verify the constructor reads it
and the validation flow is actually gated on it. (In PR #8811, the constructor
stores `self._requires_dice_resolution`, which is then used by the validator —
correct.)

---

## Constructor signature changes

### 5. Positional ordering breakage

**Spotter:** New param between existing params. Existing positional callers
silently bind to the wrong parameter.

```python
# BEFORE:
def __init__(self, requires_action_resolution, validate_level_up_signal, ...)  # slot 1, 2

# AFTER (PR #8811):
def __init__(self, requires_action_resolution, requires_dice_resolution, validate_level_up_signal, ...)
# Slot 2 changed meaning for any positional caller.
```

**Probe:** `grep -rn 'ClassName(' --include='*.py' | grep -v 'test_' | grep -v 'class_def'`,
then eyeball each callsite for whether they use kwargs after the first positional.

### 6. New required kwarg with no default

**Spotter:** Adding a parameter without `= None` or `= False` makes it
required. Any caller that doesn't pass it breaks.

**Probe:** Are there callers that construct the class via dict-unpacking or
`**some_dict`? Those will break if the dict doesn't have the new key.

### 7. Renamed parameter (silent drop)

**Spotter:** Renaming `requires_action_resolution` to `requires_action` keeps
the keyword name working for callers passing `requires_action_resolution=...`
only by accident, not design. Most classes don't support keyword rename.

**Probe:** Search for the OLD name in callers vs the NEW name in the
constructor signature. Mismatches break.

---

## Serializers and `to_dict()` round-trips

### 8. Defaults don't round-trip through `to_dict()` and back

**Spotter:** Validator defaults a field when missing. `to_dict()` serializes.
Re-parsing through the constructor deserializes. If the deserialization
re-defaults or re-validates differently, the round-trip changes.

**Probe:** Construct → `to_dict()` → reconstruct → `to_dict()` → assert
equal.

### 9. Private `_field` vs public `field` serialization

**Spotter:** `to_dict()` might serialize `self._requires_dice_resolution`
under one key but the constructor reads from `requires_dice_resolution`. If
the key names don't match, the round-trip silently drops the value.

**Probe:** Round-trip a constructed instance through `to_dict()` and check
that all conditional-validation parameters are present in the output.

### 10. Dict-key conflict between parent and child defaults

**Spotter:** Parent class defaults `{"a": 1, "b": 2}`. Child overrides
`{"a": 99}`. Constructor call without arg uses parent defaults if child
overrides aren't explicit. `to_dict()` shows `{"a": 99, "b": 2}` — round-trip
might re-default `a` to parent.

**Probe:** Construct with no args, `to_dict()`, reconstruct, compare.

---

## LLM-payload-shaped inputs (the special edge case)

Most validators exist to clean LLM output. LLMs do **weird** things:

- `null` / `None` everywhere
- List of one element when dict expected
- Snake_case and camelCase mixed
- Trailing commas / unclosed braces in JSON (caught by parser, not validator)
- Boolean `false` where string `""` expected
- Number `0` where string `"0"` expected

**Probe:** Run all of the above through the validator, confirm each is either
coerced or warns explicitly.

---

## Probe templates

```python
from mvp_site.narrative_response_schema import NarrativeResponse
from unittest.mock import patch

# Probe 1: None vs missing
with patch("mvp_site.narrative_response_schema._log_thresholded_warning") as mock_log:
    NarrativeResponse(
        narrative="x",
        action_resolution={"mechanics": None, "reinterpreted": False},
        requires_dice_resolution=True,
    )
# Did the missing_required_fields warning fire? It SHOULD have.

# Probe 3: Mutation hazard
r1 = NarrativeResponse(narrative="x", action_resolution={})
r2 = NarrativeResponse(narrative="x", action_resolution={})
assert r1.action_resolution["audit_flags"] is not r2.action_resolution["audit_flags"]

# Probe 5: Positional ordering
r = NarrativeResponse(
    "x",                       # narrative
    None,                      # entities_mentioned
    "Unknown",                 # location_confirmed
    None,                      # turn_summary
    None,                      # state_updates
    None,                      # debug_info
    None,                      # god_mode_response
    None,                      # directives
    None,                      # session_header
    None,                      # faction_header
    None,                      # planning_block
    None,                      # dice_rolls
    None,                      # dice_audit_events
    None,                      # resources
    None,                      # tool_requests
    None,                      # rewards_box
    None,                      # level_up_signal
    None,                      # social_hp_challenge
    True,                      # requires_action_resolution
    True,                      # requires_dice_resolution  <-- new positional slot
    True,                      # validate_level_up_signal  <-- did NOT shift
)
```

If `validate_level_up_signal` doesn't actually equal `True` after this call,
the constructor positional ordering is broken. Most well-tested codebases
explicitly use kwargs for everything past `narrative`.
