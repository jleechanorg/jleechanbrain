---
name: gws-slides-decks
description: Create Google Slides decks via gws CLI.
version: 0.1.0
author: Hermes agent
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [google, slides, presentations, gws, cli]
    related_skills: [google-workspace, productivity/powerpoint]
---

## When to use

Use this skill when the user asks to create a Google Slides deck, presentation, pitch, or talk outline — or pastes a Google Slides URL of a reference deck and wants a new one matching the style. The `google-workspace` Python skill doesn't cover raw batchUpdate or custom layouts — for those, reach here.

DO NOT use this when:
- User wants a PPTX file (use `productivity/powerpoint`)
- User wants HTML/Slidev/Deckset (build directly, no Slides API needed)
- User wants a Keynote file

---

# ⚠️ DEPRECATED — use `gog` for personal Slides, not `gws`

**Canonical CLI for personal Slides is now `gog`** (a.k.a. `gogcli`, v0.37.0+, Homebrew tap `openclaw/tap/gogcli`). `gws` is BANNED for personal Workspace calls (Gmail, Drive, Docs, **Slides**, Sheets, Calendar, etc.) as of 2026-08-22 — see SOUL.md `## COMMIT: gws-banned-for-personal-workspace`. `gws` is still permitted for Firebase Admin SDK / Cloud Run admin / GCP project ops against `worldarchitecture-ai` service-account credentials.

The `gws` CLI was uninstalled from this Mac on 2026-08-22. The slides-specific functionality in `gws` is replaced by `gog slides ...` (which covers all the same batchUpdate operations).

**This skill is preserved for historical reference only.** New work should use:

```bash
unset GOG_KEYRING_BACKEND
gog --account jleechan@gmail.com slides create "<title>" --no-input --json
gog --account jleechan@gmail.com slides batch-update <PRESENTATION_ID> --file /tmp/slides-requests.json
```

If you need the `gws` API shape (the underlying Google Slides API request/response JSON schema), consult `gws schema slides.presentations.batchUpdate --resolve-refs` was the old approach — for `gog`, the same JSON shape works as the input to `slides batch-update`.

**Do not invoke `gws` for any personal call.** If a future task requires gws-like API schema, load `~/.smartclaw/skills/google-workspace-via-gog/SKILL.md` and use `gog` instead.

## Quick start

```bash
gws auth status                                              # check auth state
gws auth login                                               # if unauth — default scopes
gws auth login --services slides,drive                       # narrower scope
gws schema slides.presentations.create                       # show API shape
gws schema slides.presentations.batchUpdate --resolve-refs   # batch update schema
```

## Recipe

```bash
# 1. Create blank deck
gws slides presentations create \
  --params '{}' \
  --json '{"title":"My Deck","pageSize":{"width":9144000,"height":5143500}}'
# Response includes {"presentationId":"abc...","slides":[{"objectId":"..."}]}

# 2. Add slides
gws slides presentations batchUpdate \
  --params '{"presentationId":"<ID>"}' \
  --json '{"requests":[{"createSlide":{"objectId":"slide2","insertionIndex":1,"slideLayoutReference":{"predefinedLayout":"TITLE_AND_BODY"}}}]}'

# 3. Add text
gws slides presentations batchUpdate \
  --params '{"presentationId":"<ID>"}' \
  --json '{"requests":[{"insertText":{"objectId":"<titleShapeId>","text":"Hello","insertionIndex":0}}]}'
```

## Subcommand syntax gotcha

`gws` uses SPACE-separated subcommands, not dots:

```bash
# WRONG
gws slides presentations.create --params '{}'      # "unrecognized subcommand 'presentations.create'"

# RIGHT
gws slides presentations create --params '{}'      # space-separated
```

`gws <service> --help` shows the precise subcommand shape — check it before guessing.

## Pitfalls

### 1. `auth_method: keyring` with no Slides scope

Service account or stale OAuth consent without Slides scope → `gws slides presentations create` returns `403 caller does not have permission`. Fix: re-consent.

```bash
gws auth logout
gws auth login --services slides,drive,gmail,calendar,sheets,docs
```

Verify with `gws slides presentations create --params '{}' --json '{"title":"probe"}'` then delete the probe on success.

### 2. `gcloud auth application-default login` requires `cloud-platform` first

If bootstrapping ADC because keyring is missing, the FIRST scope must be `https://www.googleapis.com/auth/cloud-platform` or gcloud rejects the call:

```
ERROR: Invalid value for [--scopes]: cloud-platform scope is required but not requested.
```

Working Slides-write scope set: `cloud-platform, drive.file, presentations, spreadsheets, userinfo.email, openid`.

Run with `--no-launch-browser --quiet` in a PTY/background. `process poll` — gcloud prints a `https://accounts.google.com/o/oauth2/auth?...` URL and waits for the `4/0A...` verification code. Paste the code via `process action=submit data="<code>\n"`.

### 3. POST/PATCH/PUT need `--json` even for empty body

```bash
# WRONG — 400 missing request body
gws slides presentations create --params '{}'

# RIGHT
gws slides presentations create --params '{}' --json '{"title":"My Deck"}'
```

### 4. Page-size units are EMU (English Metric Units), not pixels

`pageSize` width/height take EMU (9144000 EMU = 10 inch = standard widescreen).

### 5. Batch update order matters

`createSlide` must complete (returns slide objectId) before `insertText` can reference its shape. Two separate batchUpdate calls = simpler reasoning.

### 6. Visual style — verify before assuming

When matching a reference deck's style, render the source to PNG and inspect via vision BEFORE writing any CSS/RGB:

```bash
mkdir -p /tmp/deck_pages
pdftoppm -r 110 -f 1 -l 11 source.pdf /tmp/deck_pages/p -png
# Then vision_analyze(image_url="/tmp/deck_pages/p-01.png", question="...")
```

Don't trust memory notes about color hexes / font names from prior sessions — visual evidence wins.

## Reference / details

- `references/gws-cli-workflow.md` — gws CLI in general (auth, scopes, recipes for gmail/drive/calendar)

## Verification checklist

Before claiming "deck is ready":

1. `gws slides presentations get --params '{"presentationId":"<ID>"}'` — confirm slides count matches plan
2. Extract `webViewLink` from response and paste to user
3. If a write succeeded and you got `403`/`5xx` partway: re-fetch, do NOT assume partial state
