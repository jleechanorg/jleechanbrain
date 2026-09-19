---
name: inline-attach-evidence
description: Inline-attach visual evidence to PR+Slack every time.
---

# Inline-attach evidence (PR + Slack, every time)

When you generate or capture visual evidence (PNGs, webm, MP4, GIF, PDF), it MUST land inline in both delivery channels. The user has been burned multiple times by replies that only listed paths/URLs — those render as literal text in Slack and reviewers don't open terminals in PR comments.

## Rule (non-negotiable)

Every evidence request produces TWO inline-attach artifacts:

1. **Slack thread** — image files uploaded via the 3-stage Slack API; shows in the thread as inline image cards.
2. **PR description** — image syntax `![caption](https://github.com/OWNER/REPO/blob/<branch>/path?raw=true)` pointing at the binary committed in the PR branch.

Bare file paths, gist URLs, or "see /tmp/foo.png" lines are NOT evidence — they are invisible.

## Slack upload (3-stage `files.getUploadURLExternal`)

```bash
# Stage 1: getUploadURLExternal — USE FORM FIELDS, not JSON (returns invalid_arguments)
curl -fsS -X POST https://slack.com/api/files.getUploadURLExternal \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -F "filename=01_dashboard.png" \
  -F "length=83157"
# → {"ok":true,"upload_url":"https://files.slack.com/...","file_id":"F0BN..."}

# Stage 2: POST file body to upload_url
curl -fsS -X POST "$upload_url" -F "file=@01_dashboard.png;filename=01_dashboard.png"

# Stage 3: completeUploadExternal — channel+thread_ts+initial_comment at top level
curl -fsS -X POST https://slack.com/api/files.completeUploadExternal \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d '{"files":[{"id":"F0BN...","title":"01_dashboard.png"}],"channel_id":"C...","thread_ts":"1785...","initial_comment":"📎 Evidence inline-attached..."}'
```

DO NOT use `MEDIA:/abs/path` tokens through `mcp__slack__conversations_add_message` — that convention does not work.

## PR body inline-attach

Commit the binary in the PR branch under `evidence/<pr-number>/<topic>/` (NOT in /tmp). Then embed:

```markdown
![Frame 1 — Dashboard with Quick Start button](https://github.com/OWNER/REPO/blob/feat/my-branch/evidence/8422/quick_start/01_dashboard.png?raw=true)
```

For videos GitHub markdown doesn't autoplay MP4 — use an HTML `<video>` tag:

```markdown
<video src="https://github.com/OWNER/REPO/blob/feat/my-branch/evidence/8422/quick_start/captioned.mp4?raw=true" controls preload="metadata" width="640" height="360"></video>
```

For GIFs, markdown `![]()` works and they autoplay inline.

## Captioned video generation (for /es)

When user requests `/es` evidence on a PR with a Playwright webm, generate captioned MP4 + GIF(s) using ffmpeg with burned-in `drawtext` captions:

```bash
# Generate MP4 with captions
ffmpeg -y -i raw.webm \
  -vf "drawtext=text='1/N Dashboard loaded':fontcolor=white:fontsize=28:box=1:boxcolor=black@0.75:boxborderw=14:x=(w-text_w)/2:y=h-th-40:enable='between(t,0,1)',drawtext=text='2/N ...':enable='between(t,1,2)',..." \
  -c:v libx264 -pix_fmt yuv420p -preset fast -crf 23 -movflags +faststart \
  captioned.mp4

# Generate GIF (use palettegen + paletteuse for quality)
ffmpeg -y -i captioned.mp4 -vf "fps=10,scale=640:-1:flags=lanczos,palettegen" palette.png
ffmpeg -y -i captioned.mp4 -i palette.png \
  -lavfi "fps=10,scale=640:-1:flags=lanczos [x]; [x][1:v] paletteuse" \
  captioned.gif
```

Then commit MP4 + GIF to the branch and embed in PR body per above.

## Pitfalls

- **Slack `files.getUploadURLExternal` REQUIRES form fields** (`-F filename= -F length=`), NOT JSON body. JSON returns `{"ok":false,"error":"invalid_arguments","warning":"missing_charset"}`.
- `MEDIA:/abs/path` is NOT a Slack API convention — only a Hermes gateway convention for some transports. Don't use it through `mcp__slack__conversations_add_message`.
- `<video>` tag works in GitHub PR markdown; `![video](url)` does not autoplay.
- GIF inline-attach: max ~5MB recommended for PR rendering. Use 640x360@10fps for the standard GIF; 960x540@12fps for HD if the diff is significant.
- `evidence/` directory is NOT gitignored in jleechanorg/worldarchitect.ai — binaries commit fine.
- Always recompute checksums.sha256 after adding new files.

## Verification

After inline-attach, post ONE confirmation message with the PR URL and head SHA so the user can verify the artifacts are visible.

## Memory

Save the user's "always inline-attach" preference to memory the FIRST time you drop it.