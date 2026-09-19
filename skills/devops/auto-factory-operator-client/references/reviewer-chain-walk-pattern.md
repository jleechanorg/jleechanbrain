# Reviewer chain-walk on rate-limit — reusable pattern

**Landmark PR:** [jleechanorg/dark-factory#654](https://github.com/jleechanorg/dark-factory/pull/654) (commit `67ee5867b1`, 2026-08-18).

## What this pattern is

When a subprocess-backed service (reviewer, gate, validator, etc.) fails on **transient** errors — vendor rate-limit / quota exhausted / network timeout — don't fail the entire gate. Walk a priority queue of substitute vendors and let the next one try. Three properties make this work:

1. **Detection** — a regex over the captured error text identifies a transient failure (vs a real verifier verdict that must NOT trigger fallback).
2. **Queue** — a single source of truth (config + JSON + parity loaders between Python and Rust).
3. **Bind/allow-list extension** — the security check that binds "which CLI produced this verdict" must accept every vendor in the queue, not just the legacy ones.

This generalizes to: gate runners, CI linters, MCP fallbacks, package-manager retries, anything that calls multiple equivalent implementations and needs to degrade gracefully.

## Detection (the dispatcher's `_detect_rate_limit`)

```python
_RATE_LIMIT_PATTERNS = (
    "rate limit", "rate_limit", "ratelimit",
    "quota", "usage limit", "usage_limit",
    "429", "too many requests",
    "rate exceeded", "exceeded your quota",
    "hit your limit", "exceeded your monthly",
    "billing", "insufficient_quota", "insufficient quota",
)

def _detect_rate_limit(err: Optional[str]) -> bool:
    if not err:
        return False
    return any(p in err.lower() for p in _RATE_LIMIT_PATTERNS)
```

Substring match beats exact match: vendor error wording is non-portable. Match on the substring family, not the full sentence. The cost is a tiny false-positive risk (a vendor calls its retry budget "quota" for an unrelated reason); mitigate by checking that the wrapped CLI returned a non-zero exit AND `err` matches, not just `err` alone.

## Queue (single source of truth)

`config/<system>_priority.json`:

```json
{
  "reviewer_priority": ["claudem", "agy", "cursor-agent"],
  "default_coder": "agy",
  "coder_fallback_chain": ["claudem"]
}
```

Loaded identically by:
- Python: `runner/reviewer_priority.py` (with `lru_cache` on the JSON read, list comprehension that strips + validates non-empty strings, raises `ValueError` on shape mismatch).
- Rust: `daemon/src/reviewer_priority.rs` (via `include_str!` macro + `serde_json::from_str` — the JSON is compile-time embedded so daemon and Python cannot drift).

Parity test (`tests/test_<system>_priority_parity.py`): invoke both readers, assert their returned lists are equal. Catches drift early.

## Chain-walk (the dispatcher's `_chain_walk_reviewer`)

```python
def _chain_walk_reviewer(self, *, rule, prompt, original_reviewer, original_model, ...):
    from runner.reviewer_priority import skeptic_reviewer_priority
    priority = list(skeptic_reviewer_priority())

    if original_reviewer in priority:
        start_idx = priority.index(original_reviewer)
        queue = priority[start_idx:]
    else:
        queue = [original_reviewer] + [v for v in priority if v != original_reviewer]

    last_err, last_vendor = None, original_reviewer
    for vendor in queue:
        last_vendor = vendor
        try:
            stdout, err = _cli.invoke_reviewer(vendor, original_model, prompt)
        except Exception as exc:
            stdout, err = None, str(exc)
        if err and _detect_rate_limit(err):
            last_err = err
            continue  # walk to next vendor
        result = _cli.evaluate(..., reviewer=vendor, contract=contract)
        if vendor != original_reviewer:
            result = dataclasses.replace(
                result,
                reason=f"{(result.reason or '').rstrip()} (fallback_used=true; fallback_from={original_reviewer})"
            )
        return result

    # All vendors exhausted — fail closed with a transparent trail
    return SkepticResult(
        check_state="failure", verdict=None,
        reason=f"all reviewers exhausted (vendors tried: {', '.join(queue)}; last error: {last_err})",
        reviewer=last_vendor,
    )
```

Key properties:
- **Hard cap = queue length.** `for vendor in queue` is the upper bound; no nested retries.
- **Annotation on success.** When the walk lands on a non-original vendor, the result's `reason` carries `fallback_used=true; fallback_from=<original>` for the comment trail.
- **Fail-closed exhaustion.** When the queue is exhausted, return a `check_state="failure"` result with `verdict=None` and `reason="all reviewers exhausted ..."` — the operator can grep the reason and see exactly which vendors tried.
- **Security checks still run.** The post-walk `bind_reviewer_identity(actual_reviewer, parsed.reviewer_identity)` and `verify_provenance(implementation_identity, parsed.reviewer_identity)` calls fire on the fallback vendor. The chain-walk is NOT a bypass.

## Bind-table extension (the hidden gotcha)

When `REVIEWER_CLI_TO_IDENTITY = {"codex": "codex", "gemini": "gemini"}` is hardcoded, the bind check rejects every chain-walk vendor (`bind_reviewer_identity("cursor-agent", "claudem")` returns *"declared identity claudem, but cursor-agent must declare cursor-agent"*). **Symptom**: the chain-walk lands on cursor-agent, bind rejects, dispatcher returns a `check_state="failure"` instead of the success verdict. Test trace shows `bind_calls=[('claudem', 'claudem')]` instead of `('cursor-agent', 'cursor-agent')`.

**The fix pattern**: at module import time, extend the bind table from the same config the chain-walk reads. Idempotent: `setdefault` never overwrites an existing binding.

```python
# Place at the very bottom of the security module so all other names resolve.
def _extend_bind_table_from_priority() -> None:
    try:
        from runner.reviewer_priority import skeptic_reviewer_priority
    except ImportError:
        return  # tests / older deployments may run without the config
    for vendor in skeptic_reviewer_priority():
        REVIEWER_CLI_TO_IDENTITY.setdefault(vendor.strip(), vendor.strip())

_extend_bind_table_from_priority()
```

Why this is safe:
- **Self-binding**: each CLI declares its own name (`"claudem": "claudem"`), so the original security invariant holds — vendor A cannot impersonate vendor B.
- **Idempotent**: legacy codex/gemini are left untouched; new CLIs are appended.
- **Degrades gracefully**: `ImportError` swallows the call when the config reader is unavailable (older deployment still runs).

## Test design for chain-walk contracts

```python
@pytest.fixture
def dispatcher():
    return VerifierDispatcher(
        premium_reviewer="claudem",
        cheap_reviewer="cursor-agent",
    )

def _stub_invoke_reviewer(plan):
    seen = []
    def _fake(reviewer, model, prompt, *a, **kw):
        seen.append(reviewer)
        return plan.get(reviewer, (None, "unknown reviewer"))
    return _fake, seen  # NB: tuple return -- unpack before patching!

def test_chain_walk_falls_back(monkeypatch, dispatcher, stub_evaluate):
    fake_invoke, seen = _stub_invoke_reviewer({
        "claudem":     (None, "claude: 429 rate limit exceeded"),
        "agy":         (None, "agy: 429 rate limit exceeded"),
        "cursor-agent": (VALID_OUTPUT, None),
    })
    monkeypatch.setattr("runner.skeptic_gate_cli.invoke_reviewer", fake_invoke)
    results = dispatcher.dispatch(...)
    _, res = results[0]
    assert res.reviewer == "cursor-agent"
    assert "fallback_used" in res.reason
    assert seen == ["claudem", "agy", "cursor-agent"]
```

**Five pitfalls** that each delayed this PR by 5-15 minutes; capture them when writing the next chain-walk test:

1. **Pre-existing `match_glob` regex bug for `**/*` patterns** (in `runner/dispatcher.py:match_glob`). Use `target_globs=["*.py"]` in test fixtures. Out of scope to fix here.
2. **`_stub_invoke_reviewer` returns `(fn, seen_list)` -- a tuple.** If you assign the raw return value to a variable and `monkeypatch.setattr("...invoke_reviewer", that_tuple)`, the dispatcher calls a tuple as a function and gets `TypeError`, treats it as a non-rate-limit failure, and the test reads the original-verdict branch. Always unpack before patching.
3. **`_cli.evaluate` mock must declare the actual vendor's identity.** `SkepticResult(reviewer="cursor-agent", parsed=ParsedVerdict(reviewer_identity="claudem"))` makes bind reject with *"declared identity claudem, but cursor-agent must declare cursor-agent"*. Mirror `kwargs.get("reviewer")` into `parsed.reviewer_identity`.
4. **`REVIEWER_CLI_TO_IDENTITY` allow-list** -- derive from the same config the chain-walk reads, or every new vendor gets rejected upstream.
5. **Worker time-budget**. A clean chain-walk PR (5 files + tests + ~6 fixtures) takes ~600s wall-clock minimum. `delegate_task` budgets of 600s leave nothing for commit + push + open-PR. Allocate >=900s next time.

## When NOT to use this pattern

- **Verdict-side errors that are NOT transient.** A failed `verdict: fail` from a code review must never trigger a fallback to another reviewer (the no-reviewer-shopping rule). The discriminator is the OUTPUT structure, not the err string: `parsed.reviewer_identity is None and verdict != "PASS"` is a verdict; `err matches _detect_rate_limit` is transient.
- **Side-effects.** If the first invocation produces external state (writes a comment, posts to Slack, mutates GitHub), the chain-walk must not be a silent second attempt -- the operator should see the first call's effect and decide.
- **Authenticated chains.** Some vendors accept different env vars and tokens. Falling back to a vendor that doesn't have the right credentials just produces `auth_error`, which the queue will then walk past to a different vendor. Validate auth at queue resolution time, not inside the walk loop.