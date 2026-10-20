# Canonical reviewer priority queue

**Source**: `${HOME}/projects/dark-factory/config/skeptic_reviewer_priority.json`

```json
{
  "reviewer_priority": ["claudem", "agy", "cursor-agent"],
  "default_coder": "agy",
  "coder_fallback_chain": ["claudem"],
  "_comment": "Single source of truth for daemon skeptic/er and GHA skeptic_gate_cli. Operator 2026-08-18: claudem (MiniMax via claude --print) -> agy -> cursor-agent. Gemini CLI and Codex are not default reviewers."
}
```

## Invariants

- The Python reader (`runner/reviewer_priority.py`) and the Rust reader (`daemon/src/reviewer_priority.rs`) MUST read the same JSON in the same order.
- `tests/test_reviewer_priority_parity.py` enforces this — green means daemon and GHA won't drift.
- **Codex and Gemini CLI are NOT in the default list** as of 2026-08-18. Overriding to include codex requires explicit operator approval.
- The default priority exists in this exact order so that a claudem (MiniMax via `claude --print`) call goes first — that's the path with the most available capacity.
- `default_coder = "agy"` — the implementing-agent lane uses agy first, falls back to claudem.
- `coder_fallback_chain = ["claudem"]` — only one fallback entry; widen if your coder lane needs more.

## How to override

- Set `DARK_FACTORY_ADVERSARIAL_PRIORITY=claude-sonnet,agy,codex` (env var) to change the queue at runtime. The resolver in `daemon/src/reviewer_priority.rs` reads this env var; the runner-side `runner/reviewer_priority.py` reads the JSON file.
- To add a new vendor: add the binary to `~/.local/bin/`, add to `config/skeptic_reviewer_priority.json`, and bump the parity test.

## Why this file exists

Before 2026-08-18, the daemon and the GHA gate each had their own hardcoded priority list. They drifted — daemon preferred `codex` first, GHA preferred `claudem` first. PRs would land on one path's gate before the other. The single JSON source of truth + the parity test closed that gap.
