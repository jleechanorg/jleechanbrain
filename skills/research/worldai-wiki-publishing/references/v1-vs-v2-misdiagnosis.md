# V1/V2 Wizard Misdiagnosis Pattern

Authored 2026-08-05 after PR #7 conversation. Applies any time an agent encounters `mvp_site/tests/test_v1_vs_v2_campaign_comparison.py` or sees a "V2" reference in `worldarchitect.ai` and assumes a parallel React app exists in this repo.

## The trap

The test file `mvp_site/tests/test_v1_vs_v2_campaign_comparison.py` documents two wizard versions:

```python
V1_PORT = os.environ.get("PORT", "8081")       # Flask
V1_BASE_URL = f"http://localhost:{V1_PORT}"
V2_BASE_URL = "http://localhost:3002"          # React
```

A casual reader (and any agent that doesn't grep further) assumes both exist in this repo. They do not.

## Reality (verified 2026-08-05)

```bash
$ ls mvp_site/frontend_v1/
app.js, api.js, auth.js, style.css, css/, js/, themes/, images/, ...
# 5.4MB of vanilla JS + Bootstrap — the LIVE wizard

$ ls mvp_site/static/v2/
index.html   # 779 bytes, just a placeholder
# No JS, no CSS, no routes — NOT a wizard

$ grep -nE 'frontend_v1|static/v2' mvp_site/main.py | head -10
# main.py:1467  @app.route("/frontend_v1/<path:filename>")
# This route serves the V1 vanilla JS bundle to the browser
# Static/v2 is referenced as a static asset but never mounted as a route
```

The live site (https://worldarchitect.ai) is served by Flask from `/frontend_v1/`. The V2 server the test file references — `localhost:3002` — does NOT exist in this repo. It's either:

- A separate React frontend project (different repo, possibly `jleechanorg/worldarchitect.ai-frontend` or a Cloud Run service)
- A planned future migration
- Dead reference code that survived a refactor

## How an agent falls into the trap

The "delete V1" decision was discussed for this wiki walkthrough. The reasoning chain that leads to a wrong answer:

1. Test file mentions "V2 React app on port 3002" → assume V2 exists in this repo
2. `mvp_site/static/v2/index.html` exists → "ah, V2 is here, just needs to be wired up"
3. Static file is 779 bytes (placeholder) → agent either:
   a. Skips the size check, assumes "I can build V2 in a separate PR"
   b. Tries to "delete V1" first because the placeholder makes it look optional
4. Either way, the answer is wrong — V1 is the only thing keeping the live site alive, and deleting it would break production.

## Correct diagnostic pattern (use before any "delete X" PR)

```
1. Find the served frontend in mvp_site/main.py:
   grep -nE 'frontend|static' mvp_site/main.py | head -20

2. Find what the Flask routes serve:
   grep -nE '@app\.route' mvp_site/main.py | grep -iE 'frontend|static|asset' | head -10

3. Verify the size of every candidate frontend:
   du -sh mvp_site/frontend_v1/ mvp_site/static/v*/ 2>/dev/null
   # Anything < 1MB is a placeholder, not a real frontend

4. Check CI workflows for explicit frontend references:
   grep -lE 'frontend_v1|static/v' .github/workflows/*.yml
   # If a workflow tests mvp_site/frontend_v1/* paths, that's the LIVE one

5. Check deployment configs:
   grep -lE 'frontend_v1|static/v' Dockerfile docker-compose.yml cloudbuild.yaml 2>/dev/null
   # The actual deployed bundle path

6. Cross-reference with the live site:
   curl -s https://worldarchitect.ai | grep -oE 'src="[^"]+\.js"' | head -3
   # The served URLs confirm which bundle is live
```

Only after all 6 steps confirm V1 is dead code should you draft a "delete V1" PR. And even then, the PR needs to migrate the route + update CI workflows + remove the static `mvp_site/static/v2/index.html` placeholder reference.

## What to do today (verified 2026-08-05)

V1 cannot be safely deleted because:

- It's the only real frontend (5.4MB vanilla JS)
- Flask serves it via `/frontend_v1/<path>` route
- 2 GH Actions workflows explicitly test against `mvp_site/frontend_v1/*` paths:
  - `.github/workflows/mobile-auth-regression.yml`
  - `.github/workflows/wizard-mobile-scroll-regression.yml`
- The V2 in `mvp_site/static/v2/index.html` is a 779-byte placeholder

Safe subset that ships value without breaking prod:

- Delete `mvp_site/tests/test_v1_vs_v2_campaign_comparison.py` (the misleading test scaffolding)
- Delete the obsolete V1-vs-V2 evidence folders under `docs/campaign_creation_evidence/v1_*` (3 dirs, ~30 files, no live behavior)

Destructive actions to AVOID without explicit operator confirmation:

- `rm -rf mvp_site/frontend_v1/`
- Removing the `/frontend_v1/<path>` Flask route
- Updating the CI workflows to drop `frontend_v1/*` path filters
- Touching `mvp_site/static/v2/` (placeholder, but harmless)

## Pattern recognition for future agents

Any time you see a filename with `_v1` and `_v2` prefixes in this repo, run the 6-step diagnostic BEFORE drafting any cleanup PR. The pattern of "test scaffolding that references a parallel service that doesn't exist in this repo" is recurring — same trap exists in `mvp_site/tests/test_*v2*.py` files.

When in doubt, **post the diagnosis + safe subset + destructive option as 3 separate yes/no questions in Slack** (not as a single combined question) so the operator can pick the one they want without re-explaining the trade-off.