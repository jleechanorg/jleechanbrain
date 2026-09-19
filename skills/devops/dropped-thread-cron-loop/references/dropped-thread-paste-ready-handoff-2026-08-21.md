# Dropped-thread partial-success deliverable — "draft X in a Google Doc" with kix-canvas wall

**Skill:** `dropped-thread-cron-loop`
**Added:** 2026-08-21
**Source thread:** Slack `${SLACK_CHANNEL_ID}/p1787222330.239339` (AO testimonial — Prateek's request to land a testimonial on the AO landing page)
**Class:** **"done / partial — paste-ready handoff"** — new sub-class of the existing daily-batch triage table

## The pattern

A dropped-thread cron fires on a thread whose underlying task **was finished in a prior session** OR **needs a 1-step manual paste to finish**, but the in-thread agent reply was posted in such a way that the cron either ignored it (per the `conversations.replies`-visibility bug at the top of this SKILL.md) or the work shape itself was "delivered-but-not-final-pasted."

In this specific case, the user asked: *"Write a testimonial similar length to other ones and draft it in a google doc. Focus on how I've been using it in my /af dark factory."* The agent drove Google Docs via the user's signed-in Aside `u0` profile (jleechan@gmail.com), set the doc title, hit Google Docs' kix-canvas wall on body paste, and shipped a partial-success deliverable: doc created + titled + body text on user's clipboard + 1-Cmd-V handoff.

The cron will keep firing because the work isn't fully landed (body not in doc yet). Marking `gave_up=true` would be wrong — the work isn't done, it's just done-as-far-as-automation-can-go. The right move is to acknowledge the partial-success in-channel, mark the thread for ONE more cron tick so the user sees the surfaced handoff, then let the user finish with Cmd+V.

## The 5th triage class

Existing triage table from `dropped-thread-cron-loop` SKILL.md has 4 classes:

| Class | Description |
|---|---|
| Done / no-op | Thread already closed in prior session; cron is looping |
| Shipped | Real PR exists and is OPEN/MERGEABLE; user just needs to review |
| Awaiting decision | Analysis on record but build not dispatched because user hasn't picked a winner |
| Real new work | Genuine unfinished task surfaced by the escalation |

Add this 5th:

| Class | Description | Cron-loop safe action |
|---|---|---|
| **Done / partial — paste-ready handoff** | Deliverable produced via automation up to the platform's wall; user needs to perform 1 manual step (Cmd+V, click-to-confirm, OAuth-grant) to finish. The work is not "shipped" but it is "done-as-far-as-the-agent-can-do." | **Do NOT mark `gave_up=true`** — that would let the cron permanently skip a thread whose work is genuinely incomplete. Instead: (1) post the paste-ready handoff in-thread; (2) mark `partial_handoff=true` (new state field — see below); (3) the cron keeps firing until the user pastes + replies, at which point normal closeout applies. |

## Why mark `gave_up=true` would be wrong here

The current `dropped-thread-state.json` schema has only two terminal states: `gave_up: true` (one-way ack, never re-pinged) and `nudged` (re-pinged on next tick). For paste-ready-handoff:

- `gave_up: true` → cron skips forever, user thinks the work was abandoned
- `nudged` only → cron keeps firing 10+/day even after the agent has surfaced the handoff

A third state is needed: `partial_handoff: true` (the deliverable is ready, user just needs to perform 1 manual step). The cron should still fire (the work is genuinely incomplete) but at lower frequency (e.g. 4-hour cooldown instead of 30-min), AND the in-thread reply should reference the latest paste-ready handoff rather than repeat the full deliverable.

## Schema addition (proposed)

```json
{
  "nudged": {
    "${SLACK_CHANNEL_ID}_1787222330.239339": {
      "first_nudged_at": "2026-08-21T...",
      "last_nudged_at": "2026-08-21T...",
      "reason": "AO testimonial — Google Doc created + titled; body paste blocked by kix-canvas wall; user Cmd+V from clipboard completes work",
      "deliverable_url": "https://docs.google.com/document/d/1LgSxno_MI-g4pIuUClJJszMwn8_zyK_cRtLnwIvhpSU/edit",
      "deliverable_state": "title_set; body_on_clipboard; 1-Cmd-V handoff",
      "paste_step": "open URL → click body → Cmd+V → submit form on aoagents.dev/testimonials",
      "partial_handoff": true,
      "gave_up": false
    }
  }
}
```

The `partial_handoff: true` flag tells the cron to:

1. Fire at lower frequency (4-hour cooldown instead of 30-min)
2. Reference `deliverable_url` + `paste_step` in the in-channel reminder text
3. Stop firing automatically once the user's next in-thread reply mentions "pasted", "submitted", "done", or any other completion signal

## Recipe for the agent (next session sees this cron)

1. **Run `conversations.replies(channel_id, thread_ts=<cited_thread_ts>)`** — check for an in-thread agent reply with a deliverable URL. If yes, classify by `deliverable_state` field:
   - `title_set; body_on_clipboard; 1-Cmd-V handoff` → paste-ready-handoff class
   - `pr_open_and_green` → shipped class
   - `closed_in_prior_session` → no-op class
2. **For paste-ready-handoff class**: post ONE in-thread ack that references the existing deliverable + the specific 1-step manual paste action. Do NOT redo the work.
3. **Mark the state file**: `jq '.nudged["<chan>_<ts>"].partial_handoff = true'` + `.paste_step = "<one-line instruction>"` + `.last_partial_handoff_at = "<ISO>"`.
4. **Do NOT mark `gave_up: true`** unless the user explicitly says "skip this thread, I'll do it later" or it's been >7 days with no user reply.

## Verified case (2026-08-21)

- Thread: `${SLACK_CHANNEL_ID}/p1787222330.239339` (AO testimonial)
- Doc URL: `https://docs.google.com/document/d/1LgSxno_MI-g4pIuUClJJszMwn8_zyK_cRtLnwIvhpSU/edit`
- Title verified: `"AO Testimonial — Jeffrey Lee-Chan"` (set via `input.docs-title-input` click + `keyboard.insertText`)
- Body paste attempts: 6 (all failed due to kix-canvas wall)
- Clipboard state: `osascript -e 'set the clipboard to "<testimonial text>"'` — verified text on system clipboard
- Next action for user: open the doc URL → click into body → Cmd+V → submit on aoagents.dev/testimonials

## Companion reference (if google-workspace skill is later curator-managed)

The kix-canvas limitation is a per-platform behavior that should ideally live in the `google-workspace` skill's "Docs" section as a pitfall. For now, since `google-workspace` is bundled (NousResearch shipped) and not patchable by the autonomous curator, this dropped-thread-cron-loop reference is the canonical home for the partial-success Google Doc shape.

The 6 dead-end paste approaches (insertText, Control+V, simulated mouse events, raw CDP key events, DOM DragEvent, paste from clipboard) are documented in the dropped-thread follow-up Slack message at `${SLACK_CHANNEL_ID}/p1787222330.239339` (latest reply) — search for "What I did right this time" in that thread for the full table.
