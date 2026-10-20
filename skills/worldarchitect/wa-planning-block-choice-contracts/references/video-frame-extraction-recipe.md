---
name: video-frame-extraction-recipe
description: "ffmpeg + vision_analyze workflow for inspecting user-attached videos when the bug is visual."
tags: [worldarchitect, video, ffmpeg, vision-analyze, debugging, mobile-ui]
---

# Video frame-extraction + vision_analyze recipe

When the user attaches a video (`.mp4`/`.mov`) showing a UI bug — typically a mobile interaction (tap, scroll, expand, animation), a modal flow, or a layout glitch — and `vision_analyze` rejects the video file with `"source is not a recognized image"`, do NOT ask the user to describe what they see. Run this recipe instead.

**Recipe (verified 2026-08-19 on ${HOME}/.smartclaw/cache/videos/video_2031326c1b8e.mp4, Slack C0BDEAJH8PK/p1787125293.103429):**

1. **Extract frames with ffmpeg at 2 fps.** Default frame rate captures a 10-second interaction as ~20 frames — enough to see state transitions without flooding context.
   ```bash
   mkdir -p /tmp/<slug>_frames && cd /tmp/<slug>_frames
   ffmpeg -i <video.mp4> -vf "fps=2" frame_%03d.png 2>&1 | tail -3
   ls -la /tmp/<slug>_frames/ | head -25
   ```
   Adjust fps up for fast interactions (3-4 fps for scroll/animation, 1 fps for long load flows).

2. **Identify transition frames.** Use the file-size column from `ls -la` — PNGs captured during motion are larger (delta between frames); static moments produce smaller, similar-sized PNGs. Look for size deltas to find the exact frame where the user tapped something.

3. **Inspect key frames via vision_analyze in batches.** Call `vision_analyze(image_url=<png>, question="<targeted question>")` in PARALLEL (3-4 per turn) on the transition frames and the immediate before/after frames. Do NOT pass the video path itself to `vision_analyze` — it returns `"source is not a recognized image"`.

4. **Ask targeted questions per frame.** Generic "describe what's on screen" is wasteful. Use specific prompts like:
   - "What is on screen? Is the X panel collapsed or expanded? Describe state in detail."
   - "Compare this view to the previous. What got pushed/hidden/overlapped?"
   - "Look at this frame. Is the X panel about to be tapped? Are there visible text content like Z details?"
   - "Describe the screen. (1) Is X collapsed or expanded? (2) How many items are visible? (3) What is the position relative to Y?"

5. **Synthesize the bug class, then read code.** Once you have identified the precise state transition (e.g. "tap on chevron X → choice-detail block expands inside scroll container Y"), grep the codebase for the relevant handlers and CSS rules. The video evidence tells you WHAT; the code tells you WHY.

**Pitfalls:**

- **Don't pass the video path directly to vision_analyze.** Returns `"source is not a recognized image"` and burns a tool turn. Extract frames first.
- **Don't extract at full frame rate.** A 30s video at 30 fps = 900 frames = 100k tokens. 2 fps is the default; only bump up when the transition is genuinely missed.
- **Don't ask the user "what does it show" instead.** The user attached the video so you can read it — that's the WHOLE POINT of the attachment.
- **Don't load frames into context one at a time.** Batch 3-4 vision_analyze calls in the same turn — the runtime executes independent calls concurrently.
- **Don't skip the frame-extraction step when the user describes the bug verbally.** If they say "watch the video", the video is in `${HOME}/.smartclaw/cache/videos/` and they expect you to read it. Asking them to re-describe wastes a turn.

**When to use this skill vs. delegate to a worker:**

- Use inline (5-10 vision_analyze calls + 2-3 file reads) when you can produce a self-contained diagnosis in the same session.
- Delegate to a claudem worker (`bash -lic 'claudem -p "..."'` on a clean worktree) when the bug requires multi-file fix + before/after screenshot capture + PR workflow.

**Companion reference:** `references/frontend-render-fallback-layer3.md` — use when the video reveals a UI bug that is a frontend/backend state coordination failure.