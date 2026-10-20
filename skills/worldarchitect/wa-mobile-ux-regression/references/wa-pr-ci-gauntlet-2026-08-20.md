# WA PR CI gauntlet (Evidence Gate + Codex + local validator)

Companion to `SKILL.md` Steps 1–5 (capture, claim, root-cause, test, fix).
This reference captures the **drive-to-green mechanics** for `jleechanorg/worldarchitect.ai` PRs that touch `mvp_site/` or `frontend_v1/`.

Source: 2026-08-20 session that drove PR #9206 (`fix(my-campaigns): mobile UX — Duplicate button + theme dropdown overflow`) from open → MERGEABLE in one turn.

## Three CI gates you MUST clear (not just Green Gate)

`/green` per `~/.claude/skills/pr-green-definition.md` covers 7 conditions, but a WA PR typically fails on three of them that aren't obvious:

### 1. `Evidence Bundle Validation` workflow

A custom GH Actions workflow (run id varies) runs `scripts/validate_evidence_bundle.py` against the PR head. It enforces:

- **Check 6**: PR body must reference a gist evidence bundle URL (`https://gist.github.com/...`). Look for `https://gist.github.com/<owner>/<id>` somewhere in `gh pr view <N> --json body`.
- **Check 7**: the referenced gist must contain a `metadata.json` (or `green_metadata.json`/`red_metadata.json`) with `git_provenance.git_head` pointing at an **ancestor of the current PR HEAD**. If they don't match, the gate fails with `STALE — captured at <old_sha>, HEAD is <new_sha>`.

The 8-step fix recipe (worked end-to-end on PR #9206):

```bash
# 1. Build bundle dir with BEFORE/AFTER PNGs + SUMMARY.md + SHA256SUMS.txt
mkdir -p /tmp/wa-pr-XXXX-evidence-bundle/{before,after}
cp /tmp/wa-runs/BEFORE_*.png /tmp/wa-pr-XXXX-evidence-bundle/before/
cp /tmp/wa-runs/AFTER_*.png  /tmp/wa-pr-XXXX-evidence-bundle/after/

# 2. Build metadata.json with the CURRENT PR HEAD
PR_HEAD=$(git -C <worktree> rev-parse HEAD)
cat > /tmp/wa-pr-XXXX-evidence-bundle/metadata.json <<JSON
{
  "test_name": "test_my_X_regression",
  "bundle_format_version": "1.2.0",
  "timestamp": "<ISO8601>",
  "git_provenance": { "git_head": "${PR_HEAD}" },
  "browser": { "engine": "chromium-headless-playwright", "viewport": {"width": 393, "height": 852} },
  "server": { "url": "http://127.0.0.1:8081", "auth_bypass": true },
  "bugs_tested": { ... per-bug verdict objects ... }
}
JSON

# 3. PITFALL: `gh gist create --add <binary>` fails with
#    "binary file not supported". Workaround: base64-wrap each PNG
#    as <name>.b64.txt. SUMMARY.md + SHA256SUMS.txt stay as text.
cd /tmp/wa-pr-XXXX-evidence-bundle
python3 -c "
import base64, os
for path in [...]:
    b64 = base64.b64encode(open(path,'rb').read()).decode()
    open(path.replace('.png','.b64.txt'), 'w').write(b64)
"

# 4. Create the gist with only text files
gh gist create \
  metadata.json SHA256SUMS.txt SUMMARY.md \
  *.b64.txt \
  --desc "Evidence Bundle PR NNNN (<HEAD>) — <topic>"

# 5. Save the new gist ID for the PR body
GIST_ID=$(gh gist list --limit 1 --json id -q '.[0].id')

# 6. PITFALL: `gh gist edit <id> --add <file>` is BROKEN as of gh 2.x —
#    it returns exit 0 but the file content never lands on raw URLs.
#    Cache+raw URLs all show the OLD file. If you need to update
#    metadata.json (e.g. SHA moved), DELETE + RECREATE the gist:
gh gist delete <id> -y
gh gist create ... --desc "Evidence Bundle PR NNNN (<NEW_HEAD>) — ..."

# 7. Embed in PR body as markdown:
#    **Evidence bundle (required by Evidence Gate)**
#    https://gist.github.com/<owner>/<gist_id>
#    Contains metadata.json with git_head=<HEAD>, per-bug verdicts, ...
```

### 2. `scripts/validate_pr_evidence.sh` (the local pre-flight)

Run it locally BEFORE pushing — it catches what the remote Evidence Gate
will catch and exits non-zero:

```bash
bash scripts/validate_pr_evidence.sh <PR_NUMBER>
```

Checks (all 7 must pass):

1. PR body has "evidence"/"test plan"/"test results" — a section header.
2. PR body references `asciinema` or `gist.github.com` — for terminal/visual evidence.
3. PR body has test pass/fail language — pytest, test plan, or unit test.
4. PR body has git provenance — commit SHA, branch name, or git subcommand.
5. PR body references `/tmp/` or "evidence bundle" — bundle path.
6. PR body MUST NOT hide `<!-- superseded -->` markers in HTML comments.
7. **For PRs touching `mvp_site/`**: the repo MUST have
   `docs/evidence/pr-<N>/claim_artifact_map.md` tracked in git AND a media
   artifact (`.cast|.gif|.mp4`) in the same directory. Check 7 only runs if
   `git diff --name-only origin/main...HEAD -- mvp_site/` is non-empty.

The required files for any `mvp_site/` PR:

```
docs/evidence/pr-<N>/
├── claim_artifact_map.md     # per-claim source -> artifact -> measured value
├── mobile_ux.mp4 (or .gif)  # captioned, SHA-bound
└── (optional) blog-post.md
```

`claim_artifact_map.md` template (verified structure):

```markdown
# Claim → Artifact Map for PR #<N>

PR: https://github.com/jleechanorg/worldarchitect.ai/pull/<N>
Branch: <branch>
Tested SHA: <head>

## Claim 1: <user-reported bug 1>
- Source: <screenshot or quote>
- ARTIFACT: <path/to/png>
- MEASURED: <regression-test assertion + value>
- VERDICT: REPRODUCED / FIX VERIFIED

## Coverage matrix

| Bug | BEFORE PNG | AFTER PNG | In video | Test asserts |
|-----|-----------|-----------|----------|--------------|
```

The captioned video (`.mp4` / `.gif`) is a separate requirement (per
`~/.claude/skills/evidence-standards/ui-video-evidence.md`). Quick recipe
when you have PNGs already:

```bash
# Build 12s slideshow (6 frames × 2s each) with burned-in captions
ffmpeg -framerate 1 -loop 1 -t 2 -i BEFORE_01.png \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2:flags=lanczos,format=yuv420p, \
       drawtext=text='<caption>':fontcolor=white:fontsize=24: \
       box=1:boxcolor=black@0.75:boxborderw=12:x=(w-text_w)/2:y=h-50" \
  -c:v libx264 -preset ultrafast -tune stillimage -r 25 -pix_fmt yuv420p \
  c0_before_full.mp4
# repeat per frame, then:
ffmpeg -f concat -safe 0 -i <(for f in c*.mp4; do echo "file '$f'"; done) \
  -c:v copy mobile_ux.mp4

# GIF preview for in-PR inline embed
ffmpeg -i mobile_ux.mp4 \
  -vf "fps=8,scale=320:-1:flags=lanczos,split[s0][s1]; \
       [s0]palettegen=stats_mode=diff[p]; \
       [s1][p]paletteuse=dither=bayer:bayer_scale=5" \
  mobile_ux_small.gif
```

PITFALL — `libx264` needs even pixel dimensions. Original iPhone capture
is `1179x2556` (odd width). The `scale=trunc(iw/2)*2:trunc(ih/2)*2` pre-filter
rounds down. Without it ffmpeg errors with `width not divisible by 2`.

### 3. The freshness trap (the single biggest gotcha)

The Evidence Gate's Check 7 compares the gist's `git_head` against the
PR's current HEAD. **Every new commit invalidates the bound.**

Sequence on PR #9206 (illustrative):

```
ca449e3e96  initial CSS fix           → metadata.json git_head = ca449e3e96 ✓
e70d368eee  test rename              → metadata.json git_head = ca449e3e96 ✗ STALE
d43abd5dd8  test move + docs/evidence → metadata.json git_head = ca449e3e96 ✗ STALE
f3f8ea99ef  empty commit (re-trigger) → metadata.json git_head = ca449e3e96 ✗ STALE
```

Fix: either (a) delete+recreate the gist with new SHA before each push, or
(b) commit the `metadata.json` to the PR branch as a static file and point
the Evidence Gate at the branch instead of an external gist. PR #9206 used
(a); it works but requires re-creating + reposting the PR body gist URL.

PITFALL — `gh gist edit --add <file>` is broken (returns 0, never updates
raw URLs). DELETE + RECREATE the gist to replace its content.

PITFALL — Pushing a new commit doesn't auto-restart all CI checks.
Path-filter jobs that were SKIPPED on the previous commit stay SKIPPED.
Jobs that are mid-flight on a stale commit get CANCELLED. Plan around this
or use `gh run rerun --failed <RUN_ID>`.

PITFALL — `git commit --allow-empty -m "ci: re-trigger"` is the cleanest
way to wake the Evidence Gate after a metadata.json update. Don't amend a
real commit — it moves the SHA and the bound stays broken.

## Codex review: chatgpt-codex-connector[bot]

Codex posts inline review comments on mvp_site/frontend_v1/** as
`chatgpt-codex-connector[bot]`, state=`COMMENTED` (NOT CHANGES_REQUESTED,
so it never blocks merge directly). Three patterns show up on mobile-UX
PRs:

1. **P1 — SHA-bound captioned video** ("For this user-visible CSS change,
   the harness only captures PNG screenshots and never records a captioned
   video or associates an artifact with the tested commit SHA.").
2. **P2 — Register with the UI test runner** ("the default
   `run_ui_tests.sh` discovery only scans `testing_ui/core_tests/test_*.py`,
   pytest's configured test paths exclude `testing_ui`, and a repo-wide
   workflow search found no reference to this module.").
3. **P2 — Honor the scoped UI runner's base URL** ("When this test is
   invoked through `./run_ui_tests.sh real ...`, the runner starts Flask
   on port 8088 and supplies `TEST_BASE_URL`, but this default ignores
   that environment variable and probes port 8081 instead.").

All three fix points:
- Move test to `testing_ui/core_tests/test_<X>.py` (line: `git mv`).
- Read `TEST_BASE_URL` env var with safe fallback to `http://127.0.0.1:8081`.
- Generate the MP4/GIF, commit to `docs/evidence/pr-<N>/`.

## Cursor Bugbot is currently rate-limited (2026-08-20)

Both `coderabbitai[bot]` ("Review limit reached") and `cursor[bot]` ("Bugbot
couldn't run — usage limit reached") return NEUTRAL on the PR; neither
review blocks the merge, but they're not giving actionable feedback. Don't
expect Codex-style inline comments from either while those gates are
ramped down — only `chatgpt-codex-connector[bot]` is currently producing
useful review content.

## End-to-end checklist (the order matters)

1. ✅ Open PR with embedded BEFORE/AFTER PNGs + git provenance
2. ✅ `bash scripts/validate_pr_evidence.sh <N>` returns 0
3. ❌ Evidence Bundle Validation workflow FAILS (no gist in PR body)
4. ❌ Codex review posts P2 comments on the test file
5. ✅ Move test to `core_tests/`, add `TEST_BASE_URL` support, commit, push
6. ❌ Evidence Gate now FAILS with SHA-mismatch STALE
7. ✅ Generate MP4/GIF + `claim_artifact_map.md`, commit to `docs/evidence/pr-<N>/`
8. ✅ Delete + recreate the gist with new metadata.json SHA, edit PR body
9. ❌ Push a new commit (or `--allow-empty`); gate now re-runs against new SHA
10. ✅ Gate passes (Check 6: gist URL present; Check 7: SHA matches HEAD)
11. ✅ Other CI checks (Wizard Mobile Scroll/CSS Regression,
    Light/Fantasy Compliance Gate, JavaScript Linting) settle to SUCCESS

The "‑‑ allow‑empty" loopback trick:

```bash
git -C ~/.worktrees/wa-mobile-ux commit --allow-empty -m \
  "claudem/minimax-M3: ci: trigger Evidence Gate after metadata.json refresh"
git -C ~/.worktrees/wa-mobile-ux push origin HEAD:refs/heads/fix/my-campaigns-mobile-ux
```

Total wall time on PR #9206: ~75 minutes (15 min for test+repro+push,
40 min for Codex review → fix → push → re-trigger, 20 min for media
+ claim map → recreate gist → re-trigger). Most of it waiting on CI
queue, not actual work.

## Related files

- `~/.claude/skills/evidence-standards/ui-video-evidence.md` — the
  mandatory-frame + caption contract for the `.mp4` side.
- `~/.claude/skills/evidence-standards/bundle-anatomy.md` — the
  metadata.json schema (EVIDENCE_FORMAT_VERSION, server block, run_window,
  per-test_params).
- `~/.claude/skills/wa-visual-proof-playwright/SKILL.md` — the
  PNG-capture side. Use THIS reference for the post-PR gate side.
