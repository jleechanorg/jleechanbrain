# Upstream Issue Map (streaming-cut family)

All issues are on `NousResearch/hermes-agent`. Verified 2026-08-19. Statuses reflect the API response on that date — re-check before quoting to the user.

## TIER 1 — direct cause of the `[response interrupted]` symptom

### [#74990](https://github.com/NousResearch/hermes-agent/issues/74990) — open, 2 comments, 2026-07-30
**Title:** `[Bug]: after a mid-stream transport cut, the model refuses to call tools on continuation`

Body excerpt:
> When a streamed response is cut off mid-stream by a transport/network error, Hermes re-prompts the model to continue via `_get_continuation_prompt(is_partial_stub=True)`. In practice the model sometimes concludes it is now in a "text-only" or "compatibility layer" session and **refuses to call tools on the continuation**, stalling the task — even though nothing about its capabilities changed. The transport interruption is the only thing that happened.

**Proposed fix:** tighten the partial-stub continuation prompt to (a) state the interruption was transport-only, (b) reassert that tools remain fully available, (c) tell the model to ignore earlier claims of lacking tools.

### [#75004](https://github.com/NousResearch/hermes-agent/issues/75004) — open, 1 comment, 2026-07-30
**Title:** `fix(agent): clarify tool availability in continuation prompt after transport cut (#74990)`

Body excerpt:
> Fixes #74990 — continuation prompt now says **'You may still use tool calls if needed — all tools remain available.'** instead of **'Finish the answer directly.'**

This is the **fix PR**. One-line prompt change. Currently **open** (not merged as of 2026-08-19). When it merges, our `pip install --upgrade hermes-agent` resolves the symptom entirely.

## TIER 2 — adjacent streaming / partial-finish issues

### [#75801](https://github.com/NousResearch/hermes-agent/issues/75801) — open, 6 comments, 2026-08-01
**Title:** `[Bug]: OpenCode Go gpt-5.6-luna omits finish_reason → 4 fake 'network mid-stream' continuations; desktop strips the streamed answer`

**What to copy into the user reply:** Two compounding bugs — (a) Luna omits `finish_reason`, so Hermes wrongly treats the response as a mid-stream cut and asks the model to "continue" 4 times; (b) on desktop, the streamed answer is then stripped after the false continuations. Same family as #74990 — the `_get_continuation_prompt` path is the culprit, but here the trigger is "missing finish_reason" rather than "tool-result injection."

### [#89765](https://github.com/NousResearch/hermes-agent/issues/89765) — open, 2026-08-19
**Title:** `fix(slack): surface rejected streamed attachments`

### [#89760](https://github.com/NousResearch/hermes-agent/issues/89760) — open, 2026-08-19
**Title:** `[Bug]: Streamed Slack MEDIA path rejection is silent after a delivery claim`

Both opened **the same day as our incident** (2026-08-19), both Slack-side streamed-attachment handlers. These are leading indicators that the Slack-side streaming path is currently being reworked in `NousResearch/hermes-agent` HEAD — worth noting when explaining why the symptom is multi-axis (gateway + agent + provider all touch this path).

### [#80151](https://github.com/NousResearch/hermes-agent/issues/80151) — open, 1 comment, 2026-08-06
**Title:** `Desktop: switching away and back mid-stream loses earlier streamed content — only post-switch output shows`

Confirms 0.20.0 is a known bad streaming generation across multiple transports (desktop too, not just Slack).

## TIER 3 — older adjacent issues (history)

| Issue | Date | Note |
|---|---|---|
| [#57323](https://github.com/NousResearch/hermes-agent/issues/57323) | 2026-07-02 | `fix(gateway): finish interrupted turn on non-interactive platform resume` — gateway-side sibling to #74990; pre-existing branch in the same family |
| [#69000](https://github.com/NousResearch/hermes-agent/issues/69000) | 2026-07-22 | `[Bug]: System prompts treated as user input causing task abandonment` — continuation-prompt misclassification, different root cause, same symptom class |
| [#69011](https://github.com/NousResearch/hermes-agent/issues/69011) | 2026-07-22 | `fix(agent): delimit continuation prompts as system instructions (#69000)` — sibling fix to a different continuity-prompt mis-classification |
| [#63894](https://github.com/NousResearch/hermes-agent/issues/63894) | 2026-07-13 | `fix(gateway): surface flagged agent failures in streaming /v1/responses` — related path |
| [#60127](https://github.com/NousResearch/hermes-agent/issues/60127) | 2026-07-07 | `fix(telegram): report truncated mid-stream preview as partial delivery` — same class on a different transport |
| [#80822](https://github.com/NousResearch/hermes-agent/issues/80822) | 2026-08-07 | `fix: skip None chunks in streaming API responses` — adjacent, prevents crash but does NOT prevent partial-stub continuation |

## Re-check cadence

Re-query before quoting to user:
```bash
curl -fsSL "https://api.github.com/repos/NousResearch/hermes-agent/issues/74990" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"[{d['state']}] cmts:{d['comments']} updated_at:{d['updated_at'][:10]}\")"
curl -fsSL "https://api.github.com/repos/NousResearch/hermes-agent/issues/75004" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"[{d['state']}] cmts:{d['comments']} updated_at:{d['updated_at'][:10]} merged_at:{d.get('merged_at','-')}\")"
```

When #75004 shows `merged_at: <iso>`, schedule the `pip install --upgrade hermes-agent` and remove this skill from "active bug class."
