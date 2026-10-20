# Inbound video extraction (user-attached video files)

Companion to `vision-extract-large-image` (which covers large static
images and scanned PDFs). This reference covers the **video-attachment
case**: the user (or upstream system) attaches an `.mp4` / `.mov` / `.webm`
to a Slack message or chat, the agent has to read the file off disk,
sample frames, and extract structured evidence.

Triggered by:

- A Slack message that begins with `[The user sent a video attachment: '<file>.mp4' ...]`
- A user path like `${HOME}/.smartclaw/cache/videos/<file>.mp4` referenced in any prompt
- Any chat that says "see the attached video" / "look at the recording" / "watch this"
- PR / audit requests where a Playwright `.webm` or screen-capture `.mp4` was uploaded to a channel

The `[OUT-OF-BAND USER MESSAGE]` and `[The user sent a video attachment: ...]`
markers in the Hermes prompt mean the file is **already on disk at the
path shown in the system prompt** — the agent does NOT need to ask
the user where the file is or how to obtain it.

## Quick recipe (the loop that actually works)

```bash
# 1. Confirm the file is real and grab dimensions/duration
ffprobe -v error -show_entries format=duration,size,bit_rate \
    -show_entries stream=width,height,codec_name,nb_frames,r_frame_rate \
    -of default=noprint_wrappers=1 /path/to/video.mp4

# 2. Sample N frames evenly across the duration
mkdir -p /tmp/frames && rm -f /tmp/frames/*.png
for t in 1 5 10 15 20 25 30 35 40 45 50 55 60 66 72; do
  ffmpeg -v error -ss $t -i /path/to/video.mp4 \
    -frames:v 1 -q:v 2 /tmp/frames/f_$(printf '%02d' $t)s.png
done
```

Then in the agent loop, call `vision_analyze` on the most diagnostic
frames (start, midpoints, last frame) **in parallel** with targeted
transcription questions. Merge the answers in the reply.

## Frame-budget rules of thumb

| Recording length | Recommended frame count | Why |
|---|---|---|
| < 15 s | 3–5 frames every 2–3 s | One transition, no scroll |
| 15–60 s | 8–12 frames every 5 s | Covers wizard flows + click + result |
| 60–180 s | 12–18 frames, every 8–10 s + state-change moments | Long demos; cluster around apparent transitions |
| > 180 s | 18–25 frames + re-sample around points of interest | Don't blow context on redundant frames |

The single biggest mistake is sampling too few frames and missing the
actual state-change moments (e.g. capture 15 frames across 75 s of a
Playwright run, but the click that opens a modal happens between
samples). When in doubt, **sample densely, then ask vision about
specific frames** — vision can tell you "this looks like a modal opening"
and you can re-sample around the moment it noticed.

## Reading frames — what to ask vision

Frame the question so vision returns **specific text, not impressions**:

- "Transcribe every visible field label and its entered value verbatim"
- "Is this a loading/generation state? What text and progress fill is shown?"
- "Transcribe all narrative text and UI panels verbatim"
- "Count the input fields; transcribe each label"

Do NOT ask "describe what's on screen" — that returns prose about layout
and you still have to ask for the text. Go straight for the data.

For UI / wizard captures the formula is: sample 3–4 frames at evenly
spaced timestamps, then ask vision "what is the visible state at this
moment — wizard step X, or game view, or loading?" That tells you
whether to dig further on the wizard or pivot to in-game evidence.

## Pitfalls

- **The video may be a still image inside an .mp4 container** (single
  I-frame, tiny file, 0-duration). `ffprobe` will show 1 frame or
  fractional duration. Skip frame sampling and treat as an image.
- **`vision_analyze` returns "[screenshot removed to save context]"**
  when the same image is passed twice in a long session. Re-sample
  the frame (ffmpeg again, same offset, new file path) to get a fresh
  load.
- **"In-game streaming" is captured as a pill, not as prose.** A
  Playwright recording of an LLM streaming response will show
  `Loading story...` / `NPCs are discussing...` / `Checking the rulebook...`
  indicator text while the actual content streams underneath. Capture
  multiple frames at 4–8 s intervals through the streaming window so
  you can show the indicator evolving.
- **Wizard forms scroll.** A 720p capture of a long wizard will only
  show the first 3–4 fields. If the user mentions "7-field IP wizard"
  but your frames only show 3, that is the recording's viewport, not
  the form's length — note it explicitly in the response ("only fields
  1–3 visible in viewport, 4–7 below the fold") and offer to capture
  the rest by scrolling the live wizard.
- **Don't paste MEDIA:/path/.mp4 tokens in the reply.** The
  `evidence-attach-to-slack` skill explains why this fails; for the
  video case the same rule applies. The user's Slack thread already
  has the attachment from the inbound delivery — do not re-attach.
- **Cache the ffmpeg output once per session.** If you sample 15
  frames and vision asks for the same one twice, re-running ffmpeg is
  cheap but the duplication burns context. Reuse file paths.

## Output format

A video-extraction reply should include:

1. **What the recording actually shows** — 2–3 sentence summary of
   the captured flow (wizard → generation → in-game).
2. **Key transcribed evidence** — bullet list with timestamp ranges,
   each one paired with the visible text vision returned.
3. **What the video does NOT show** — fields below the fold, narrative
   text still streaming, modal interactions cut off. This is the part
   that makes the reply useful: the user can see at a glance whether
   the recording captured what they thought it did.
4. **Next-step options** — save the trimmed clip, capture more by
   scrolling, move on. Single concrete question, not a menu.

## Companion skills

- `vision-extract-large-image` — parent umbrella; static image /
  scanned PDF extraction.
- `evidence-attach-to-slack` — outbound sibling: 3-stage upload
  recipe for sending binary evidence to a Slack thread. **Not** the
  recipe to use for the inbound video (the user already delivered it).
- `wa-visual-proof-playwright` — BEFORE/AFTER visual proof for
  worldarchitect.ai PRs; uses Playwright PNG capture, not video.
- `web-page-screenshots` — Playwright CLI for OG thumbnails, not
  relevant here.

## Worked example (2026-08-22, WorldAI campaign wizard recording)

A 75 s Playwright capture was attached to a DM:

- `ffprobe` confirmed 1280×720, 25 fps, 1884 frames, 75.36 s, h264, 2 MB
- Sampled 15 frames at 1, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 66, 72 s
- Re-sampled at 0.2, 1.5, 3, 4, 6, 7, 8, 9 s and 56, 58, 62, 64, 68, 70, 74, 75.2 s to
  catch scroll-into-view and the final streaming state
- 26 `vision_analyze` calls in parallel across two batches; the gateway
  returned "[screenshot removed to save context]" on 6 of them —
  re-ran ffmpeg with the same offsets to fresh file paths and the
  re-issued vision calls succeeded
- Vision confirmed: Step 1 of 2 ("Choose Type") wizard, fields 1–3
  visible (Game of Thrones / Westeros, Timeline / Era optional,
  Chosen Protagonist), then a "Building your world..." spinner at
  ~0:08, then the in-game view "A Song of Ice and Fire: The Winter
  King" with companion roster (Howland Reed, Martyn Cassel) and
  the live `Loading story...` / `NPCs are discussing...` /
  `Checking the rulebook...` streaming indicators
- Reported: "fields 1–3 of the wizard visible, fields 4–7 below the
  fold not captured by the recording's viewport" and "in-game
  stream captured as the loading pill, not as completed narrative
  prose" — explicit gaps so the user can decide whether to re-capture

## Known limitations

- **Frame sampling is blind to audio.** A video with narration but
  no on-screen transcript cannot be queried about spoken content. If
  the user expects speech content, ask them whether the audio
  matters before spending the ffmpeg budget.
- **No OCR fallback for tiny text.** If vision returns "I see some
  text but cannot read it clearly", upsample that specific frame
  with `-vf scale=2:2` (Pillow equivalent: 2× `thumbnail` then
  re-thumbnail) before re-asking.
- **Long videos explode context.** 30 frames × ~120 KB each is ~3.6 MB
  of in-context images even when truncated by the gateway. Cap at
  25 frames for the first pass; re-sample around moments of interest.
- **Codec weirdness.** Some screen-capture MP4s use unusual codecs
  (`hevc`, `vp9`) that ffmpeg decodes but with high CPU. If frame
  extraction is slow, re-encode to h264 first:
  `ffmpeg -i input.mp4 -c:v libx264 -preset ultrafast /tmp/transcoded.mp4`
