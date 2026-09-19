# gtm-strategy-builder — full worked walkthrough (2026-08-09)

Session: Hermes runtime (Slack), user asked to clone `kvn-phn/gtm-strategy-builder`, test it locally, and use it to evaluate their actual product (https://worldarchitect.ai). No Claude Code Workflow tool available.

## What was produced

| Artifact | Path | Size |
|---|---|---|
| Cloned repo | `~/scratch/gtm-strategy-builder` | 37 files |
| WA brief | `briefs/worldarchitect.md` | 4,669b |
| WA strategy JSON | `runs/worldarchitect/full-strategy.json` | 13,199b |
| WA brand JSON | `brand-worldarchitect.json` | 488b |
| WA STRATEGY.md | `runs/worldarchitect/STRATEGY.md` | 2,392b |
| 6 WA decks | `runs/worldarchitect/decks/01-06*.pptx` | 8/12/15/3/3/3 slides |
| Sample client (for comparison) | `runs/sample/` | 5 decks |
| Dashboard | `http://localhost:8099/` | served via `python3 serve.py 8099` |
| Tests | `python3 -m pytest tests/ -v` | 5 passed, 1 skipped |

## Step-by-step commands (verbatim)

```bash
# 1. Clone
cd ~ && mkdir -p scratch && cd scratch
git clone https://github.com/kvn-phn/gtm-strategy-builder.git

# 2. Install deps (NOT --user — that fails in venv)
cd gtm-strategy-builder
pip3 install -q python-pptx python-docx pillow
python3 -c "import pptx, docx, PIL; print('OK', pptx.__version__)"

# 3. Verify the rendering layer works on the bundled sample
python3 make_status.py sample          # rc=0
python3 serve.py 8099 &                # start server; curl / returns dashboard HTML
sleep 2 && curl -fsS -o /dev/null -w "%{http_code}\n" http://localhost:8099/

# 4. Hand-author the WA strategy (grounded in ~/worldarchitect.ai evidence)
#    ...write runs/worldarchitect/full-strategy.json per the schema...

# 5. Brand BEFORE rendering (else decks say "northlight advisory (sample)")
cat > brand-worldarchitect.json <<EOF
{
  "firm_name": "WorldArchitect.AI — GTM Eval",
  "tagline": "Growth, grounded. — for the only AI GM that can't cheat its own dice",
  "mode": "dark",
  "bg": "0F1216",
  "surface": "171B21",
  "text": "E7E9EC",
  "muted": "8B939C",
  "ink": "E7E9EC",
  "primary": "1F1B14",
  "accent": "C2542D",
  "footer": "Internal GTM evaluation — prepared against the worldarchitect.ai production codebase, 2026-08-09",
  "head_font": "Baskerville",
  "body_font": "Helvetica Neue"
}
EOF

# 6. Render the WA deck set
python3 make_deck.py worldarchitect worldarchitect --set
# → 6 decks generated in runs/worldarchitect/decks/

# 7. Regenerate status
python3 make_status.py
# → STATUS.md + status.html shows 2 clients: Sample (5 decks) + Worldarchitect (6 decks)

# 8. Confirm bundled tests still pass
python3 -m pytest tests/ -v
# → 5 passed, 1 skipped (test_deck_footer.py::test_add_footer_writes_text_when_set)

# 9. Verify content (not just file size) via python-pptx
python3 -c "
from pptx import Presentation
p = Presentation('runs/worldarchitect/decks/03 Worldarchitect — Go-To-Market Plan.pptx')
print(f'{len(p.slides)} slides')
for i, s in enumerate(p.slides):
    texts = []
    for shape in s.shapes:
        if shape.has_text_frame:
            for para in shape.text_frame.paragraphs:
                t = ''.join(r.text for r in para.runs).strip()
                if t: texts.append(t[:130])
    if texts:
        print(f'  S{i+1}: ' + ' | '.join(texts[:3]))
"
# → 15 slides, each with real content (DIAGNOSTIC, STRATEGY FINDINGS, RECOMMENDATIONS, BUILD-OUT, etc.)

# 10. Screenshot dashboard via headless Chrome
#    navigate browser_navigate → http://localhost:8099/ → browser_vision → dashboard.png

# 11. Kill server
kill <pid from /tmp/serve.pid>
```

## What worked, what didn't

### Worked
- **The Python rendering layer is fully usable without Claude Code.** README implies you need it; you don't.
- **Hand-authoring the JSON is fast** once you read `examples/the-ledger/full-strategy.json` for the schema (~13KB reference, 5 minutes to read).
- **The brand JSON controls the visual identity** end-to-end — set it before rendering or every deck says the wrong firm name.
- **Dashboard discovery is glob-based** — `runs/<client>/` is auto-detected. Just make a subdirectory per client.
- **Content verification with python-pptx** is the right move after render — confirms slides have real text, not just a title.

### Didn't work / gotchas hit
- `pip3 install --user` fails with "User site-packages are not visible in this virtualenv" in the active venv. Use plain `pip3 install`.
- `python3 serve.py 8099` in a foreground `terminal()` call times out — that's the server running, not a hang. Background it.
- `python-pptx` works in system `python3` but the `execute_code` sandbox python is a different env. Run python-pptx via `terminal()`, not `execute_code()`.
- First deck set rendered with the default brand (`northlight advisory (sample)`) — had to regenerate after writing `brand-worldarchitect.json`. Brand is baked at render time.
- `runs/` originally had a `runs/README.md` which made `make_status.py` glob trip with `NotADirectoryError`. Renamed it out of `runs/`.

## What this session was actually about (WA product context)

The user wasn't just testing the repo — they wanted a GTM evaluation of their actual product (https://worldarchitect.ai) grounded in real product evidence, not aspirational copy. Every claim in `briefs/worldarchitect.md` and `runs/worldarchitect/full-strategy.json` traces to:

- `${HOME}/worldarchitect.ai/README.md` (394K LOC, 14 agents, anti-cheat)
- `${HOME}/worldarchitect.ai/docs/design/system-architecture.md` (architectural claims)
- `${HOME}/worldarchitect.ai/docs/user-stories-general.md` (100 player user stories)
- `${HOME}/worldarchitect.ai/mvp_site/frontend_v1/app.js:3586, :4297` (the 500ms setTimeout + pushState bugs)
- `${HOME}/worldarchitect.ai/mvp_site/dice_integrity.py` (1,566 lines of anti-cheat)
- `~/llm_wiki/wiki/sources/2026-08-04-wa-retention-7-weeks-later.md` (the 1.6% activation number, 73% wizard-trap cliff)

The GTM take:
1. **Wizard eats 73% of first sessions** — 3 small PRs would recover most of the cliff.
2. **1.6% activation, June→Aug collapse unexplained** — the single biggest open question.
3. **Anti-cheat + MCP + 14-agent routing are buried in /docs** — invisible to D&D players who would pay for integrity.

Recommended order: **Foundation (3 small PRs) → Re-engagement (gmail SMTP) → Positioning (anti-cheat as player benefit) → Content (100 user stories as 100 blog posts) → Measure (weekly review + A/B).**

## What I did NOT do

- Run the Workflow-tool pipelines (strategy.workflow.js, copy.workflow.js, gtm_run.workflow.js) — they require Claude Code's Workflow tool, which Hermes doesn't have.
- Modify `examples/the-ledger/` — left the bundled example untouched for reference.
- Commit or push — local-only as the user asked ("cloen this locally and test it").

## If you want to fire the full swarm

When you have Claude Code available:

```bash
cd ~/scratch/gtm-strategy-builder
# Open in Claude Code, then ask: "run the Workflow tool with strategy.workflow.js"
# (set const CLIENT = "worldarchitect" at the top of the script first)

python3 make_deck.py worldarchitect worldarchitect --set
python3 render_deliverables_docx.py worldarchitect    # .docx handoffs
python3 serve.py 8099                                  # dashboard
```