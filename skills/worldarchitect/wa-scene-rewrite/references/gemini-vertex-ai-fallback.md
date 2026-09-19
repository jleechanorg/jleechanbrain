# Gemini → Vertex AI fallback (when Gemini CLI is broken)

**Verified:** 2026-08-14 by jleechan on initial 5-scene run; subsequent run same day required one regen on `royal_audience_re_estize` (855 → 508 words) after tightening the prompt with explicit word-count guardrail — see Pitfall #6 below.

## TL;DR

`gemini` CLI is currently broken on this machine:

- `GEMINI_API_KEY` in `~/.zshenv` is reported **leaked** by Google (`403 PERMISSION_DENIED: Your API key was reported as leaked. Please use another API key.`).
- `GEMINI_MODEL=gemini-3.6-flash-high` is **not found** (`404 ModelNotFoundError: models/gemini-3.6-flash-high is not found for API version v1beta`).

**Working path:** bypass the CLI entirely. Call Gemini directly via **Vertex AI** on the `worldarchitecture-ai` GCP project, using `gcloud auth print-access-token` for the bearer token and POSTing to the publisher-models REST endpoint with `gemini-2.5-flash`. The `dev-runner@worldarchitecture-ai.iam.gserviceaccount.com` already has `aiplatform.endpoints.predict` on this project.

## Working recipe (Python stdlib only)

```python
#!/usr/bin/env python3
"""Helper to call Gemini via Vertex AI on the worldarchitecture-ai project."""
import json, os, subprocess, sys, urllib.request, urllib.error

PROJECT = 'worldarchitecture-ai'
LOCATION = 'us-central1'
PUBLISHER = 'google'
MODEL = os.environ.get('GEMINI_MODEL', 'gemini-2.5-flash')

def call(prompt: str, max_tokens: int = 8192) -> dict:
    token = subprocess.check_output(
        ['gcloud', 'auth', 'print-access-token', f'--project={PROJECT}'],
        text=True
    ).strip()
    url = (
        f"https://{LOCATION}-aiplatform.googleapis.com/v1/projects/{PROJECT}"
        f"/locations/{LOCATION}/publishers/{PUBLISHER}/models/{MODEL}:generateContent"
    )
    body = {
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": {
            "maxOutputTokens": max_tokens,
            "temperature": 0.7,
        },
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode('utf-8'),
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
        method='POST',
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            return json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        return {'error': e.code, 'body': e.read().decode('utf-8', errors='replace')}
```

## Critical pitfalls

### 1. `GEMINI_MODEL` env var in `~/.zshenv` will silently override your model

```bash
unset GEMINI_MODEL AGY_MODEL WORLDAI_DEFAULT_GEMINI_MODEL REALISTIC_TEST_AGY_MODEL
```

Without this, every Python subprocess inherits `GEMINI_MODEL=gemini-3.6-flash-high` and the API returns 404. Even setting `os.environ.get('GEMINI_MODEL', 'gemini-2.5-flash')` in Python isn't enough — you have to unset BEFORE the Python process starts.

### 2. Wrong project = 403 PERMISSION_DENIED

The `dev-runner` service account has `aiplatform.endpoints.predict` on:
- ✅ `worldarchitecture-ai` (use this for WA work)
- ❌ `ai-universe-2025` (will return `Permission 'aiplatform.endpoints.predict' denied`)

If you see the denied error, you have the wrong project. Check which is active:

```bash
gcloud auth list  # look for ACTIVE ACCOUNT
gcloud config get-value project
```

### 3. `usageMetadata.thoughtsTokenCount` is real and non-zero

Gemini 2.5 Flash reports THREE token counters in `usageMetadata`:

```json
{
  "promptTokenCount": 3163,
  "candidatesTokenCount": 551,
  "thoughtsTokenCount": 1086,
  "totalTokenCount": 4800
}
```

Report all four fields in `meta.json`. The orchestrator (Step 5) sums them; if you conflate `thoughts` into `response`, totals drift by 30-50%.

### 4. `maxOutputTokens=8192` is overkill but harmless

I used 8192 and `temperature=0.7`. Gemini 2.5 Flash reliably lands 350-675 words of clean prose from a ~3000-token prompt without hitting the cap. No continuation-extension needed (unlike Grok-4.3 — see `references/grok-4.3-iterative-rewrite.md`).

### 5. MCP servers in `~/.gemini/settings.json` will try to start on every CLI invocation

If you DO have to use the CLI for some reason (e.g. testing a different MCP server), expect `[MCP error] Error during discovery for MCP server 'grok-mcp'` spam. The errors don't break the CLI but slow startup. Use `--allowed-tools` to disable specific tools, or just don't use the CLI.

### 6. Gemini overshoots word caps even with explicit ranges (verified 2026-08-14)

On a brief asking for 400–700 words, the first `royal_audience_re_estize` rewrite landed at **855 words** — over the 700 cap by 22%. Gemini 2.5 Flash treats a soft "400–700" range the same as "as much as you can fit" and pads internal-monologue beats and second-cycle dialogue turns to fill. Mitigation, applied successfully on re-run:

1. In the prompt, write the constraint as **`STRICTLY 450–650 words (count carefully — under no circumstances exceed 650 words)`** — capitals, parenthesized imperative, and a tight upper bound all together.
2. Add a final `## Word-count guardrail` section telling the model to **count before submitting** and to **cut redundant internal-monologue beats / condense NPC descriptions** if it overshoots.
3. If it still overshoots on retry, just re-run with the same prompt — the model lands in-band on the second attempt most of the time (saw 855 → 508 words on a second-pass retry of the same prompt, and 733 → 514 on `imperial_audit_e_rantel`). Treat the first pass as a "draft that informs the second" rather than a final.
4. Always backup the overshot file to `<slug>.v1_oversized.md` BEFORE re-running so the audit trail is preserved.

This is Gemini-specific. Grok-4.3 routinely *undershoots* with the same instruction; the two models have opposite biases.

## Probe before batching

Always run a 10-token probe:

```bash
unset GEMINI_MODEL AGY_MODEL WORLDAI_DEFAULT_GEMINI_MODEL REALISTIC_TEST_AGY_MODEL
python3 -c "from gemini_call import call; print(call('Say OK and nothing else.'))"
```

Expected: `OK` (1 token response, ~20 tokens total). If you see any error → check the project, the model name, and the service-account permissions BEFORE batching 5 scene rewrites.

## Cost / quota notes

- Vertex AI on `worldarchitecture-ai` uses project-level quotas, not API-key quotas. Quota exhaustion surfaces as `429 RESOURCE_EXHAUSTED`.
- `gemini-2.5-flash` is a low-cost Flash model — 5 scene rewrites × ~4500 tokens ≈ 22.5K input + 3.5K output = well under $0.01.
- The `thoughts` tokens DO count against quota. Plan for ~30-40% of "tokens spent" being thoughts.

## File layout per scene (Gemini sibling)

```
/tmp/avatar_scene_gen/scenes/<slug>/
├── gemini.md           # final vignette
├── meta.json           # {campaign_id8, entry_range, avatars_used, prompt_tokens, response_tokens, thoughts_tokens, total_tokens, model_used: "gemini-2.5-flash", provider: "vertex-ai"}
├── prompt.md           # full prompt (re-runnable)
├── source_entries.json # trimmed raw entry slice (idx 1-based, ≤ 8 KB text per entry)
├── <short>_raw.md      # raw Gemini response
└── <short>_usage.log   # stderr: [usage] prompt_tokens=N response_tokens=N thoughts=N total=N
```

The Grok sibling writes `grok.md` / `grok_prompt.txt` / `meta.json` / `grok.vN.md` in the SAME scene dir. The two siblings do NOT race on shared files.

## Re-running a single scene

**Two equivalent patterns** — both verified 2026-08-14:

```bash
unset GEMINI_MODEL AGY_MODEL WORLDAI_DEFAULT_GEMINI_MODEL REALISTIC_TEST_AGY_MODEL
GEMINI_MODEL=gemini-2.5-flash python3 /tmp/avatar_scene_gen/gemini_call.py < /tmp/avatar_scene_gen/scenes/<slug>/prompt.md
```

OR:

```bash
unset GEMINI_MODEL AGY_MODEL WORLDAI_DEFAULT_GEMINI_MODEL REALISTIC_TEST_AGY_MODEL
PROMPT=$(cat /tmp/avatar_scene_gen/scenes/<slug>/prompt.md)
python3 /tmp/avatar_scene_gen/gemini_call.py "$PROMPT"
```

**Trap:** Setting `PROMPT` as a shell env var (`PROMPT=$(cat ...); python3 gemini_call.py "$PROMPT"`) DOES work for the second pattern (script reads `sys.argv[1]`), but setting it as an env var and expecting Python to read `os.environ['PROMPT']` does NOT — the script has no such code path. If the API returns `400 INVALID_ARGUMENT: Model input cannot be empty`, you passed the prompt wrong — either pipe via stdin or pass it as the first positional argument. This is a recurring foot-gun because the helper script does NOT validate an empty prompt client-side.

## Future-fix candidate

Long-term: rotate the leaked `GEMINI_API_KEY` in the user's Google Cloud console and update `~/.zshenv`. The Vertex-AI fallback above is a workaround, not a fix. Note in `MEMORY.md` so the user remembers to rotate.
