# Decomposing Claude.ai Workflow DSL into claudem print-mode calls

When a third-party repo (e.g. `kvn-phn/gtm-strategy-builder` with `strategy.workflow.js`) is designed for Claude.ai's hosted Claude Code where `parallel()` and `agent()` are runtime primitives, **those primitives do not exist in claudem's CLI print mode**. The script fails immediately: `ReferenceError: parallel is not defined`. Pivot to a 4-phase decomposition: each Workflow phase becomes one (or a small parallel batch of) `claudem -p` invocations.

## Pattern: 4 phases of claudem invocations

```
PHASE 1 — Diagnose (parallel batch of N claudem calls, max_workers=3)
   ↓ writes _phase1/<model>.json
PHASE 2 — Strategize (sequential, each call reads _phase1 + prior _phase2)
   ↓ writes _phase2/<phase>.json
PHASE 3 — Build out (parallel batch, max_workers=3)
   ↓ writes _phase3/<playbook>.json
PHASE 4 — Verify (parallel batch, default-FAIL each rec)
   ↓ writes _phase4/_verdicts.json
   ↓ rewrite FAIL/WEAK recs in place
   ↓ assemble full-strategy.json
   ↓ run make_deck.py / make_status.py / serve.py
```

## Canonical invocation shape

```bash
bash -lic 'claudem -p "<prompt with embedded file:line refs>" \
    --add-dir <repo-root> \
    --output-format text \
    --max-turns <6 for verifiers, 8-12 for workers>'
```

- `bash -lic` forces bashrc sourcing so the `claudem` function is visible.
- `--add-dir <repo>` is required for the worker to use `Read`/`Edit`/`Bash` against the repo.
- `--output-format text` keeps stdout plain (no JSON wrapping noise).
- `--max-turns` budget: verifiers 6, workers 8-12, builders 8.

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
        # …parse JSON from raw, save to unique path…
```

## JSON extraction from claudem stdout

claudem -p stdout mixes:
- The answer (your JSON on one line)
- Bash subprocess warnings (`bash: cannot set terminal process group`, `bash: no job control in this shell`)
- `⚠ claude.ai connectors are disabled because ANTHROPIC_API_KEY ...`

Robust extraction:

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

**Truncation recovery:** if the rec clearly got cut mid-string (max-turns hit), pull the leads of the recommendations list (`re.finditer(r'\{"rec":"', raw)`), then hand-complete the JSON with the captured findings + rec-starts.

## Adversarial verify (default-FAIL)

The verifier is the most important phase. Spawn one per recommendation. Common catches:

- **Confabulated framework names** — e.g. "Demand Metric Value-Based Pricing" is not one of the canonical 6 Maturity Models (the canonical 6 are Demand Generation, Demand Forecasting, Account-Based Marketing, Lead Management, Pipeline Management, Sales Enablement). Workers WILL invent framework names; the verifier catches them.
- **Generic recs** — recs that don't reference brief evidence by file:line or quoted text.
- **Off-fit recs** — recs that would only make sense for a B2B SaaS (e.g. "MQL→SQL pipeline", "enterprise account tiers") applied to a B2C/PLG product.

Verifier prompt pattern (default-FAIL):

```python
PROMPT = f"""You are an adversarial reviewer. Default to FAIL. Only PASS if the
recommendation is BOTH (a) grounded in a real Demand Metric framework name AND
(b) a fit for THIS client.

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

Then apply the rewrites: in the assembled `full-strategy.json`, swap the original `rec` text for `verdict.improved_rec` wherever verdict ∈ {WEAK, FAIL}. Leave PASS recs alone.

## Worked example — kvn-phn/gtm-strategy-builder → worldarchitect.ai

Run on 2026-08-09 against `~/scratch/gtm-strategy-builder/`:

| Phase | Calls | Wall time | Output |
|---|---|---|---|
| 1 Diagnose | 7 (6 score + 1 synthesis) | ~100s | 6 maturity scores + 5 ranked top-gaps |
| 2 Strategize | 6 sequential | ~196s | 6 GTM phases × findings + recs + playbooks |
| 3 Build out | 8 parallel | ~113s | 8 filled playbook plans (4-6KB each) |
| 4 Verify | 22 parallel | ~186s | 20 PASS/FAIL/WEAK verdicts + 20 in-place rewrites |

**Total: 43 claudem invocations, ~10 minutes.**

Verifier stats:
- 17/22 recs had confabulated Demand Metric framework names → rewritten
- 3/22 recs were WEAK (vague citations) → rewritten
- 2/22 hit `--max-turns 6` → needed manual pass
- 20/22 PASS after rewrite

Composite maturity: **0.13 / 1.0** (very early-stage). Top gaps: zero email/re-engagement infra + zero attribution — both P0.

Final artifacts on disk:
- `runs/worldarchitect/_phase{1,2,3,4}/*.json` + `*.raw` (36 raw files, ~95KB)
- `runs/worldarchitect/full-strategy.json` (83KB assembled payload)
- `runs/worldarchitect/decks/*.pptx` (14 decks)
- `STATUS.md` / dashboard at http://localhost:8099/

## When to use this pattern

Trigger when a user says "run this Workflow script" or "fire the swarm" and the script is a third-party artifact with `parallel()` / `agent()` calls. Don't try to make claudem -p execute it; decompose.

Don't use when the user is already in Claude Code proper (where `Workflow` tool exists natively). In that case, point Claude Code at the script directly.

## Pitfalls catalog (from the worldarchitect run)

1. **The 500ms `setTimeout` trap doesn't help here** — claudem's first-call warmup is ~3-5s, not 500ms. Don't expect fast retries.
2. **`--max-turns` is the verifier ceiling.** A verifier that needs to both judge AND rewrite needs at least 6 turns; if you give 4-5, half the recs come back parse-failed.
3. **`--dangerously-skip-permissions` is baked in by the wrapper.** Don't pass it again — Claude Code accepts the duplicate silently but it's noise.
4. **`bash -lic` for non-interactive callers.** `subprocess.run(['claudem', …])` fails with `claudem: command not found` because subprocesses don't inherit the parent shell's function table. Always wrap in `bash -lic`.
5. **JSON truncation is recoverable, not fatal.** If a rec is mid-string when max-turns hit, the raw transcript has the rec's leading text. Reconstruct from findings + rec-starts + the framework citation.
6. **Verifier workers WILL fail some real Demand Metric recs.** The verifier I used flagged "Demand Metric Value-Based Pricing" as confabulated even though it's a real framework name in some Demand Metric taxonomies (just not the canonical 6 Maturity Models). Tune the verifier prompt to specify which taxonomy you're anchoring on.
7. **The 4-phase pattern isn't sacred.** Some Workflows have only 2 phases (build + verify); some have 6. Decompose at fan-out/fan-in boundaries, not at the workflow's declared phase boundaries.