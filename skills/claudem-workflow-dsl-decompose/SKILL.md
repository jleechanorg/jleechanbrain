---
name: claudem-workflow-dsl-decompose
description: "Run Claude.ai Workflow scripts via claudem print-mode."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
changelog:
  - "1.0.0 (2026-08-09): Initial decomposition recipe. Verified against kvn-phn/gtm-strategy-builder → worldarchitect.ai: 43 claudem invocations, 4 phases (Diagnose 7, Strategize 6, Build-out 8, Verify 22), ~10 minutes wall time, 20/22 recs required adversarial rewrite."
metadata:
  hermes:
    tags: [Coding-Agent, Workflow-Orchestration, Provider-Routing, Adversarial-Verify, JSON-Extraction]
    related_skills: [claude-code, claude-code-claudem, agento, dispatch-task]
    invocation_pattern: "bash -lic 'claudem -p \"...\" --add-dir <repo> --output-format text --max-turns <N>'"
---

# Decomposing Claude.ai Workflow DSL into claudem print-mode calls

Third-party agent swarms (e.g. `kvn-phn/gtm-strategy-builder` with `strategy.workflow.js`, `copy.workflow.js`, `gtm_run.workflow.js`) target Claude.ai's hosted Claude Code where the `Workflow` tool exposes `parallel()` and `agent()` as runtime primitives. **These primitives do NOT exist in `claudem -p` CLI mode.** Pointing claudem at the script gives `ReferenceError: parallel is not defined` and the whole swarm dies on the first dispatch.

Pivot: **decompose the Workflow into 4 phases of `claudem -p` invocations**, run parallel subgraphs as Python `ThreadPoolExecutor` batches, and add a default-FAIL adversarial verifier on every recommendation.

## When to use

Trigger when:
- User says "run this Workflow script" / "fire the swarm" / "use claudem on this"
- Third-party repo has `*.workflow.js` files that use `parallel()` and `agent()`
- The repo assumes a Claude.ai hosted environment
- claudem CLI print mode is the actual runtime

DO NOT use when:
- User is in Claude Code proper (where `Workflow` tool exists natively) — point Claude Code at the script directly
- The script is plain Python or shell with no `parallel()`/`agent()` calls — just run it
- A single isolated coding task — use `claude-code-claudem` skill's Mode 1 instead

## The 4-phase decomposition

```
PHASE 1 — Diagnose (parallel batch of N claudem calls, max_workers=3)
   ↓ writes _phase1/<model>.json
PHASE 2 — Strategize (sequential, each call reads _phase1 + prior _phase2)
   ↓ writes _phase2/<phase>.json
PHASE 3 — Build out (parallel batch of top-K playbooks)
   ↓ writes _phase3/<playbook>.json
PHASE 4 — Verify (parallel batch, default-FAIL each rec, rewrite in place)
   ↓ writes _phase4/_verdicts.json
   ↓ assemble full-strategy.json
   ↓ render dashboards / decks
```

For the gtm-strategy-builder Workflow, each Workflow phase maps 1:1 to a claudem phase. For more complex Workflows, decompose at the seam where the Workflow switches from fan-out to fan-in.

## Canonical invocation shape

```bash
bash -lic 'claudem -p "<prompt with embedded file:line refs>" \
    --add-dir <repo-root> \
    --output-format text \
    --max-turns <6 verifiers | 8-12 workers>'
```

- `bash -lic` forces bashrc sourcing so the `claudem` bashrc function is visible (mandatory for non-interactive callers — `subprocess.run(['claudem', …])` fails with `claudem: command not found`).
- `--add-dir <repo>` is required for the worker to use Read/Edit/Bash against the repo. Without it, workers can't read the brief or corpus.
- `--output-format text` keeps stdout plain (no JSON wrapping noise from claude -p's stream-json mode).
- `--max-turns` budget: **verifiers 6** (judge + rewrite), **workers 8-12** (read files + write JSON), **synthesis agents 8**. If a verifier hits `Reached max turns (6)`, the rec needs a manual pass — don't auto-rewrite.

## Parallel-within-phase orchestration (Python)

```python
import concurrent.futures, subprocess, time, re, json

def run_one(prompt: str) -> str:
    safe = prompt.replace(chr(39), chr(39)+chr(92)+chr(39)+chr(39))
    cmd = ["bash","-lic",
           f"claudem -p '{safe}' --add-dir <repo> --output-format text --max-turns 8"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    return (r.stdout or "") + "\n" + (r.stderr or "")

with concurrent.futures.ThreadPoolExecutor(max_workers=3) as ex:
    futures = [ex.submit(run_one, p) for p in prompts]
    for f in futures:
        raw = f.result()
        # parse JSON, save to unique path...
```

`max_workers=3` is the safe ceiling. 6+ tends to hit `--dangerously-skip-permissions` race issues when multiple bashrc-sourced shells load the same env. For batches >3, run sequentially in groups of 3.

**Sequential between phases.** Each phase's claudem writes structured JSON to disk; the next phase's prompt loads it via `cat runs/<client>/_phase<N>/*.json | head -400`. Disk is the only reliable inter-phase channel — don't try to pipe phase output into phase input.

## JSON extraction from claudem stdout (mandatory helper)

claudem -p stdout mixes:
- The answer (your JSON on one line)
- Bash subprocess warnings (`bash: cannot set terminal process group`, `bash: no job control in this shell`)
- `⚠ claude.ai connectors are disabled because ANTHROPIC_API_KEY ...`

Robust extraction function:

```python
def extract_json(raw: str, leading_key: str) -> dict | None:
    # 1. Strip the bash warnings tail
    clean = raw.split("bash: cannot set terminal process group")[0].rstrip()
    # 2. Try line-by-line for a single-line JSON
    for line in clean.split("\n"):
        line = line.strip()
        if line.startswith(f'{{"{leading_key}"'):
            try:
                end = line.rindex("}")
                return json.loads(line[:end+1])
            except (ValueError, json.JSONDecodeError):
                continue
    # 3. Fallback: balanced-brace scan from first { to matching }
    start = clean.find(f'{{"{leading_key}"')
    if start < 0:
        return None
    depth = 0
    for i in range(start, len(clean)):
        if clean[i] == '{': depth += 1
        elif clean[i] == '}':
            depth -= 1
            if depth == 0:
                try: return json.loads(clean[start:i+1])
                except: return None
    return None
```

**Truncation recovery:** if a rec clearly got cut mid-string (max-turns hit), pull the leads of the recommendations list (`re.finditer(r'\{"rec":"', raw)`), then hand-complete the JSON with the captured findings + rec-starts. Don't discard — partial data is still better than nothing.

## Adversarial verify (default-FAIL — the most important phase)

Spawn one verifier per recommendation. Default to FAIL. The verifier catches confabulations that workers WILL produce.

**Common confabulations to test for:**

- **Framework name invention** — e.g. "Demand Metric Value-Based Pricing" is NOT one of the canonical 6 Maturity Models. The canonical 6 are Demand Generation, Demand Forecasting, Account-Based Marketing, Lead Management, Pipeline Management, Sales Enablement. Workers WILL invent framework names.
- **Generic recs** — recs that don't reference brief evidence by file:line or quoted text.
- **Off-fit recs** — recs that would only make sense for a B2B SaaS (e.g. "MQL→SQL pipeline", "enterprise account tiers") applied to a B2C/PLG product.

Verifier prompt pattern:

```python
PROMPT = f"""You are an adversarial reviewer. Default to FAIL. Only PASS if the
recommendation is BOTH (a) grounded in a real framework name AND (b) a fit for THIS client.

RECOMMENDATION TO VERIFY:
- Phase: {rec['phase']}
- Rec: {rec['rec']}
- Framework: {rec.get('framework','')}
- Rationale: {rec.get('rationale','')}

CONTEXT (read if needed):
- Brief: `cat <repo>/briefs/<client>.md`

OUTPUT exactly this JSON on one line (no markdown, no preamble):
{{"phase":"{rec['phase']}","rec_id":"{rec.get('rec','')[:50]}","verdict":"PASS|FAIL|WEAK","reason":"<one sentence>","improved_rec":"<only if WEAK or FAIL — concrete rewrite>"}}
"""
```

Then **apply the rewrites in place** before assembling the final payload:

```python
for v in verdicts:
    if v["verdict"] in ("FAIL", "WEAK") and v["improved_rec"]:
        # swap the rec text in the phase JSON
        ...
```

## Verification stats — the lesson

In the worldarchitect.ai run on 2026-08-09:
- **17 / 22 recs had confabulated framework names** (Demand Metric Value-Based Pricing, Demand Metric 6-Phase GTM with phase names invented, etc.)
- **3 / 22 recs were WEAK** (vague citations)
- **2 / 22 hit `--max-turns 6`** → needed manual pass
- **20 / 22 PASS after rewrite**

The verifier is non-negotiable. Without it, the assembled strategy would have 77% confabulated citations — useless for a client-facing deliverable.

## Worked example — full provenance

**Repo:** `~/scratch/gtm-strategy-builder/` (kvn-phn/gtm-strategy-builder)
**Client:** worldarchitect.ai
**Date:** 2026-08-09
**Wall time:** ~10 minutes
**Calls:** 43 claudem invocations (Diagnose 7, Strategize 6, Build-out 8, Verify 22)

Pipeline provenance on disk:
- `runs/worldarchitect/_phase1/*.json` + `*.raw` (15 files, 6 maturity scores + synthesis input + top_gaps)
- `runs/worldarchitect/_phase2/*.json` + `*.raw` (12 files, 6 GTM phases)
- `runs/worldarchitect/_phase3/*.json` + `*.raw` (16 files, 8 playbook buildouts)
- `runs/worldarchitect/_phase4/_verdicts.json` (35KB verifier output)
- `runs/worldarchitect/full-strategy.json` (83KB assembled payload)
- `runs/worldarchitect/decks/*.pptx` (14 decks)
- Dashboard at http://localhost:8099/

Composite maturity: **0.13 / 1.0** (very early-stage). Top gaps: zero email/re-engagement infra + zero attribution — both P0.

## Related skills

- **claude-code-claudem** — the underlying wrapper; use Mode 1 for single coding tasks (NOT for workflow DSL decomposition)
- **claude-code** — the bundled Claude Code skill; in Claude Code proper, point at the Workflow script directly
- **agento** / **dispatch-task** — for single-task delegation to AO workers; this skill is for multi-phase swarms

## See also

- `references/workflow-dsl-decomposition.md` — full JSON-extraction snippets + pitfall catalog from the worldarchitect run