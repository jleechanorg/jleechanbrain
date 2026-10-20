---
name: agent-pipeline-render
version: 1.0.0
category: software-development
description: Render artifacts from agent-swarm repos without LLM.
---

# Agent Pipeline Render — local artifact generation without running the swarm

## The class of repo

An "agent-swarm pipeline" repo in 2026 (Claude Code Workflow tool, AO, or similar) typically has:

- `*.workflow.js` (Claude Code) or `agent.py` (AO) — **the LLM orchestration layer** (NOT portable; requires Claude Code's proprietary Workflow tool API)
- `make_*.py` / `render_*.py` / `serve.py` — **the deterministic Python rendering layer** (portable; runs without any LLM)
- `examples/<client>/` or `runs/<client>/` — pre-baked examples showing the input schema
- `brand*.json` — visual identity config (firm_name, mode=light/dark, accent, fonts)
- `tests/` — pytest tests for the rendering layer
- `README.md` and `SPEC.md` — docs for the framework the swarm encodes

The README usually says "Built and run inside Claude Code" — that's about the LLM layer. **The Python layer is fully usable without Claude Code.** Don't waste cycles trying to run `*.workflow.js` outside Claude Code; the Workflow tool API is closed.

## When to use this skill

- You are handed a pipeline repo whose primary execution path is the Claude Code Workflow tool (or AO) and you don't have it
- The user wants the **artifacts** (decks, dashboards, docx, boards), not the LLM reasoning itself
- OR the user wants to **evaluate their product against a standardized framework** that the pipeline encodes (e.g. feed in their own brief and get a strategy back)
- Your runtime is Hermes / Codex / headless CI / any non-Claude-Code agent

## When NOT to use

- You actually have Claude Code available — just use the swarm
- The pipeline has no Python rendering layer (only Workflow JS / pure LLM prompts)
- The user wants the LLM's reasoning as the output, not rendered artifacts

## The 5-step workflow

### Step 1 — Identify the rendering layer

Look for `make_*.py`, `render_*.py`, `serve.py`, top-level `*.py`. These run without LLM:

```bash
ls *.py | head -20
grep -l "argparse\|def main" *.py
```

Common entry points:

| Command | Output |
|---|---|
| `python3 make_deck.py <brand> <client> --set` | `.pptx` set in `runs/<client>/decks/` |
| `python3 make_status.py [client]` | `STATUS.md` + `status.html` |
| `python3 serve.py <port>` | local HTTP dashboard |
| `python3 render_*.py <client>` | `.md` → `.docx` / `.pdf` |
| `python3 make_board.py <client>` | `runs/<client>/board.html` (may need `tools/*.json`) |

Install deps (almost always `python-pptx`, `python-docx`, `pillow`, optionally `numpy`, `openpyxl`):

```bash
pip3 install -q python-pptx python-docx pillow   # NOT --user in a venv (fails)
python3 -c "import pptx, docx, PIL; print('OK', pptx.__version__, docx.__version__)"
```

### Step 2 — Discover the input schema

Walk the bundled examples:

```bash
ls examples/*/         # or runs/*/
cat examples/<best-example>/full-strategy.json | python3 -m json.tool | head -80
```

Pick the most-complete example. Note:

- **Required fields** (every example has them)
- **Optional fields** (some examples omit)
- **Enums** (e.g. `phase` is usually a fixed list like Diagnose/Foundation/Demand Engine/Sales/Content/Measure)

For gtm-strategy-builder the canonical schema is in `examples/the-ledger/full-strategy.json` — see `templates/strategy-payload-template.json` for a minimal skeleton derived from it.

### Step 3 — Hand-author the input JSON

Create `runs/<your-client>/full-strategy.json`:

- Copy the schema shape from the most-complete example
- Fill every field with content **grounded in real evidence** — file:line citations, real numbers, real repo paths. Not aspirational copy.
- Keep text fields at typical example length (truncate rather than bloat)
- For frameworks that demand evidence/citations, include real references (file:line, wiki path, doc URL)

Validate by running the deck/status generator — most will error loudly on missing required fields.

### Step 4 — Set up branding BEFORE rendering

If the repo has `brand-<client>.json`, create one. Common keys:

```json
{
  "firm_name": "Your Firm Name",
  "tagline": "Your tagline",
  "mode": "dark",
  "bg": "0F1216",
  "surface": "171B21",
  "text": "E7E9EC",
  "muted": "8B939C",
  "ink": "E7E9EC",
  "primary": "1F1B14",
  "accent": "C2542D",
  "footer": "Internal — prepared for {client}",
  "head_font": "Baskerville",
  "body_font": "Helvetica Neue"
}
```

**Regenerate after any brand change** — most rendering layers bake the brand into the `.pptx`/`.pdf` at render time, not at view time.

### Step 5 — Render, verify, serve, screenshot

```bash
# Generate
python3 make_deck.py <client> <client> --set
python3 make_status.py
python3 -m pytest tests/ -v          # confirm bundled tests still pass

# Serve (background it — foreground will time out)
python3 serve.py 8099 &
sleep 2 && curl -fsS -o /dev/null -w "%{http_code}\n" http://localhost:8099/
```

**Verify content, not just file size.** Read the `.pptx` content back with python-pptx:

```python
from pptx import Presentation
p = Presentation("runs/<client>/decks/01 <client> — Executive Overview.pptx")
for i, s in enumerate(p.slides):
    texts = []
    for shape in s.shapes:
        if shape.has_text_frame:
            for para in shape.text_frame.paragraphs:
                t = "".join(r.text for r in para.runs).strip()
                if t: texts.append(t[:120])
    if texts:
        print(f"S{i+1}: " + " | ".join(texts[:3]))
```

Capture dashboard screenshot via headless Chrome for proof. Kill the server when done (`kill <pid>`).

## Pitfalls

1. **Workflow scripts are NOT portable.** `*.workflow.js` files use the proprietary Claude Code Workflow tool API. Don't waste time trying to run them outside Claude Code. The Python layer is your only path.

2. **`pip install --user` fails in a venv** with "User site-packages are not visible in this virtualenv." Use plain `pip3 install` or `python3 -m pip install`.

3. **`make_board.py` and similar may require extra JSON files** (e.g. `tools/growth_projects.json`) that the Workflow swarm is supposed to generate. Check stderr — if it says "needs tools/X.json", that file is part of the LLM output, not the deterministic input. Either skip that surface or hand-author the file.

4. **Foreground `terminal()` call on `serve.py` will time out** — that's the server running, not a hang. Use `background=true` + `notify_on_complete=true` or wrap in `subprocess.Popen` from `execute_code`. The `TimeoutExpired` exit is normal.

5. **Verify content, not just file size.** A 47KB `.pptx` could be a single title slide or a real 8-slide deck. Read it back with python-pptx.

6. **`make_status.py` discovery is glob-based** — it looks at `runs/*` and considers each subdirectory a client. If you put extra files at `runs/README.md`, the glob will trip with `NotADirectoryError`. Either remove or move.

7. **Hermes-tools sandbox python may differ from system python3.** If `from pptx import Presentation` fails inside `execute_code` but works in `terminal()`, you're hitting a venv mismatch. Run python-pptx checks via `terminal()` not `execute_code`.

8. **Brand mode affects background color of all rendered text.** A dark brand applied to a deck generated as light will produce unreadable slides. The `mode: "dark"` key must match what the rendering layer expects.

9. **The deck tool's argument order matters.** `python3 make_deck.py <brand> <client> --set` — first arg is which brand JSON to load, second is which runs/ subdir. Set `client = brandclient` (same value both) unless you're applying one client's brand to another client's run.

10. **Some rendering layers silently substitute a default client** when called with no args. Always pass the client slug explicitly to avoid landing in the wrong `runs/<client>/`.

## Tested on

- **`kvn-phn/gtm-strategy-builder`** (2026-08-09): 6 `.pptx` decks (Executive Overview 8 slides, Growth Diagnostic 12, GTM Plan 15, wizard-rewrite 3, open-source-reengagement 3, positioning-refresh 3) + dark-themed WA brand matching the product's own UI (`0F1216` bg, rust `#C2542D` accent) + dashboard served at :8099, all content grounded in real `~/worldarchitect.ai` evidence (file:line citations, real Firestore retention numbers). Tests: 5/6 pass (1 skipped by design — deck footer conditional).
- **`jleechanorg/worldarchitect.ai` planning-block composer Option E** (2026-08-16, PR #8952): 4-choice renderer (`parsePlanningBlocks` extracted via brace-matching from `mvp_site/frontend_v1/app.js`, no gunicorn, no Firestore auth, no `npm install`) rendered onto a static `file://` Chromium harness. BEFORE pulled from `git show origin/main:mvp_site/frontend_v1/app.js`, AFTER from the PR's HEAD. Same dark theme, same `PLANNING_BLOCK` fixture, same 720×360 viewport, ~3s capture wall-clock. Effect: caught a `renderedComposerRows is not defined` bug from the first patch iteration (`let` decl missing), proved Option E (numbered compact rows 1/2/3 + ✦ Custom Action) matches the screenshot spec at the pixel level.

## Renderer-isolated visual proof (use when you don't need the whole app)

The pattern from the second tested-on entry generalizes: for any UI change
contained inside ONE renderer function plus its companion stylesheet, you
can prove the visual diff WITHOUT booting the application server. Five
steps:

1. Pull BEFORE-CSS and BEFORE-app.js from `git show origin/main:<path>` so
   the BEFORE capture is byte-equal to what shipped. Don't use a reflog —
   in-flight rebases can pollute the read.
2. Brace-match the renderer + its dependencies out of `app.js` (or
   `*.tsx`) and pass them into a static harness HTML via `new Function()`.
   Same extraction the JS-DOM test harness uses — never reimplemented.
3. `<link>` the real CSS so the harness really runs the production
   stylesheet, not a fake parallel.
4. Capture via Playwright on `file://` — no server, no auth, no
   `npm install`. Headless Chromium is already on the box.
5. Vision-verify both PNGs with the prompt "describe every row/button
   precisely, including any numbered badges" — not "is X present?".

Effect: 30-second visual diff versus 60-90s server dance. Use this for
renderer / CSS / DOM-only changes. Fall back to the local-server recipe
above when the change crosses an HTTP boundary, needs real LLM response
shapes, or affects routes through main.py.

Full working template at `templates/no_server_render_harness.py` and a
filled-in real-world example at
`evidence/8952/option_e/capture.py` in PR #8952's commit tree (commit
`928af5efc9` on `fix/planning-choices-into-composer`).

## Templates

- `templates/strategy-payload-template.json` — minimal `full-strategy.json` skeleton derived from `gtm-strategy-builder/examples/the-ledger/full-strategy.json`. Copy and fill in your evidence.
- `templates/no_server_render_harness.py` — Playwright + `file://` Chromium harness that loads BEFORE/AFTER `app.js` extracted from `git show origin/main:...` and BEFORE/AFTER CSS via `<link>`. Parametrize `RENDERER_NAMES` + `RENDERER_FIXTURE` for your project.

## References

- `references/gtm-strategy-builder-walkthrough.md` — full worked example from 2026-08-09: clone, install, hand-author, render, serve, screenshot. Useful as a worked-example if a future session needs the same outcome.