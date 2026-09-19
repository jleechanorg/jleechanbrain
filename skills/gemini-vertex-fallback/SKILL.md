---
name: gemini-vertex-fallback
version: 1.0.0
description: "When gemini CLI fails, use Vertex AI via gcloud bearer auth."
when_to_use: "Use when Gemini API call fails with 403 PERMISSION_DENIED (leaked key) or 404 ModelNotFoundError and you need a headless fallback. Trigger phrases: 'gemini failed', 'GEMINI_API_KEY leaked', 'gemini model not found', 'call gemini from terminal'. Do NOT use for production CI/CD or high-volume async workloads."
category: devops
last_verified: 2026-08-14
---

# Gemini fallback: Vertex AI via gcloud bearer auth

When the standard Gemini path is blocked on this machine, this works.

## When the standard Gemini path fails

Two failure modes have been observed (2026-08-14):

1. **Leaked API key** — `GEMINI_API_KEY` in `~/.zshenv` (and possibly `~/.bashrc`) was reported leaked by Google. Any call returns:
   ```
   403 PERMISSION_DENIED — your API key was reported as leaked
   ```
   This is a perma-block from Google's side; rotating the key in AI Studio does not help if the leak-block is already in place.

2. **Model not found** — `GEMINI_MODEL=gemini-3.6-flash-high` returns:
   ```
   404 ModelNotFoundError
   ```
   The named model doesn't exist in the Gemini API surface. Check the current model list at https://ai.google.dev/gemini-api/docs/models before retrying.

In both cases, the standard `gemini` CLI and any code path that uses `GEMINI_API_KEY` directly will fail.

## The working fallback

**Vertex AI on the `worldarchitecture-ai` GCP project**, authenticated via `gcloud auth print-access-token`, calling `gemini-2.5-flash` (currently available, low-quota cost).

```bash
TOKEN=$(gcloud auth print-access-token)

curl -fsS -X POST \
  "https://us-central1-aiplatform.googleapis.com/v1/projects/worldarchitecture-ai/locations/us-central1/publishers/google/models/gemini-2.5-flash:generateContent" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "contents": [{
      "role": "user",
      "parts": [{"text": "Your prompt here"}]
    }],
    "generationConfig": {
      "temperature": 0.7,
      "maxOutputTokens": 2048
    }
  }'
```

The Vertex AI service account `dev-runner@worldarchitecture-ai.iam.gserviceaccount.com` already has `aiplatform.endpoints.predict` on `worldarchitecture-ai`. If you're a different principal (jleechan-af, etc.), check your IAM bindings.

## Python helper (stdlib only)

```python
import subprocess, json, urllib.request

def gemini_via_vertex(prompt: str, model: str = "gemini-2.5-flash") -> dict:
    token = subprocess.check_output(
        ["gcloud", "auth", "print-access-token"], text=True
    ).strip()
    req = urllib.request.Request(
        f"https://us-central1-aiplatform.googleapis.com/v1/projects/worldarchitecture-ai/locations/us-central1/publishers/google/models/{model}:generateContent",
        data=json.dumps({
            "contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {"temperature": 0.7, "maxOutputTokens": 2048},
        }).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())

# Usage
result = gemini_via_vertex("Summarize this in 200 words: ...")
text = result["candidates"][0]["content"]["parts"][0]["text"]
```

Token cost in the response: `result["usageMetadata"]` carries `promptTokenCount`, `candidatesTokenCount`, `thoughtsTokenCount` (Gemini 2.5 returns thinking tokens separately), and `totalTokenCount`.

## Model availability (verified 2026-08-14)

| Model | Status | Notes |
|---|---|---|
| `gemini-2.5-flash` | ✅ works | Fast + cheap; default fallback |
| `gemini-2.5-pro` | ✅ works (assumed) | Higher quality, slower, pricier |
| `gemini-2.0-flash` | ✅ works (assumed) | Older but stable |
| `gemini-3.6-flash-high` | ❌ 404 | Doesn't exist in API surface |
| Any `gemini-3.x` | ❌ 404 | Not released yet at last verify |

Verify live with: `curl -fsS -H "Authorization: Bearer $(gcloud auth print-access-token)" "https://us-central1-aiplatform.googleapis.com/v1/projects/worldarchitecture-ai/locations/us-central1/publishers/google/models" | jq '.models[].name'`

## Quota and rate limits

Vertex AI on a free-tier service account caps at:
- 60 requests/min per region
- ~1000 requests/day before throttling

For batch workloads (10+ parallel scene rewrites), serialize via Python's `concurrent.futures.ThreadPoolExecutor(max_workers=3)` — 3-way parallelism hits quota headroom without bursting.

## Anti-pattern: hardcoding tokens in scripts

Don't bake the `gcloud auth print-access-token` output into a script's source. Tokens expire in 1 hour. The Python helper above re-fetches per call — slower but correct.

If you need a longer-lived token for a CI/CD run, use a service-account JSON key:

```bash
gcloud auth activate-service-account --key-file=/path/to/sa-key.json
```

But for local interactive use, the bearer-token-via-subprocess pattern is fine.

## Pre-flight checklist (run before dispatching a Gemini job)

1. `unset GEMINI_MODEL AGY_MODEL WORLDAI_DEFAULT_GEMINI_MODEL REALISTIC_TEST_AGY_MODEL` — clear the bad default
2. `gcloud auth print-access-token` — verify you have a token
3. Test with `curl` against `gemini-2.5-flash:generateContent` using a 5-word prompt. If that returns 200, you're good.
4. Then run your real workload.

## Related

- `gdrive-rclone-access` — same pattern: standard CLI fails, headless fallback works
- `claude-code-claudem-over-direct-api` (SOUL.md commit) — same principle: don't hardcode API keys, use the canonical wrapper
- `add-minimax-provider` — alternate LLM provider if Gemini fallback is also blocked