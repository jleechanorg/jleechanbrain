# GREEN evidence — fix = stop the agent freestyle-posting via Slack MCP

**Operator diagnosis (correct):** "the agent is just freestyle responding with slack mcp."
The gateway's own reply path threads correctly in every observed run; misroutes occur only
when the agent hand-posts with `mcp__slack__conversations_add_message`.

**Fix applied — CONFIG ONLY, no code changes:**
1. `~/.smartclaw/config.yaml` → `mcp_servers.slack.env.SLACK_MCP_ADD_MESSAGE_TOOL: "true"` → `"false"`
   (korotovsky/slack-mcp-server opt-in for the write tool; reads still enabled).
   Backup: `config.yaml.pre-mcp-addmsg-*`.
2. `workspace/SOUL.md` — new COMMIT `slack-never-hand-post-your-own-reply` (just return your
   response; the gateway threads it). Amended `prefer-builtin-slack-mcp`, which had explicitly
   told the agent to prefer the MCP post tool — a policy-level cause of the freestyle behavior.
   Old `slack-reply-inherit-thread-ts` posting mandate retitled to read-only thread identification.

## Controlled A/B/C — identical stimulus, real Slack, channel C0AUXSVFSA2

| Run | Config | MCP `add_message` calls | Marker landed |
|-----|--------|------------------------|---------------|
| RED  | write tool ENABLED, no rule       | 1 | **CHANNEL ROOT** (`thread_ts` absent) |
| GREEN1 | write tool ENABLED + SOUL rule to quote ts | 1 | **CHANNEL ROOT** — prompt fix INSUFFICIENT |
| GREEN2 | write tool **DISABLED** + SOUL rules | **0** | **IN-THREAD** ✅ |

Raw: `red-slack-raw.txt`, `green-slack-raw.txt`, `green2-slack-raw.txt`.

GREEN2 thread view (root `1786945273.480939`):
```
1786945273.480939 | [rg GREEN2 test - ignore] ...
1786945286.965009 | terminal: sleep 15 ...
1786945304.346559 | GREEN2_MARKER_C1 progress narration      <-- IN THREAD
```
Channel-root scan for `GREEN2_MARKER_C1`: none. Gateway delivered it as its own reply
(`2026-08-16 22:41:43 response ready ... chat=C0AUXSVFSA2`).

## Why GREEN1 failing matters
With the write tool available, a prompt rule could not stop the misroute — the agent consulted
the schema (`tool_describe`) and ran the verify step, and still emitted a numeric `thread_ts`.
Mechanical removal of the capability worked where instruction did not.

## Mechanism (secondary, explains the silence — not the root cause)
Slack `chat.postMessage` **silently ignores a numeric `thread_ts`, returns `ok:true`, posts at
channel root** — so the agent honestly reported "posted to the thread." Real-API A/B in
`mechanism-ab-test.txt`. Census: 62/120 threaded hand-posts (52%) sent a number
(`mcp-thread-ts-type-census.txt`), including the exact message the operator linked
(`2026-08-15T22:56:22`, ${SLACK_CHANNEL_ID}).

## What this does NOT prove
- Not yet observed over a long window of *organic* (unprompted) narrations — GREEN2 is one
  controlled run; the 52% baseline came from organic traffic and should be re-measured after a
  few days to confirm the rate goes to zero.
- Cross-channel posting via native `send_message` was not exercised in GREEN2.
- The `send_message` schema/session-var gaps remain LATENT (retracted as this bug's cause).

---

## GREEN3 — final state: MCP write tool KEPT ENABLED (operator requirement)

Operator: "I want it to have slack mcp tool though." Tool restored
(`SLACK_MCP_ADD_MESSAGE_TOOL: "true"`); fix is now **behavioral only** (SOUL.md), no capability removal.

| Run | write tool | MCP hand-posts | Marker landed |
|-----|-----------|----------------|---------------|
| RED    | enabled  | 1 | channel root ❌ |
| GREEN1 | enabled + "quote the ts" rule | 1 | channel root ❌ |
| GREEN2 | **disabled** + no-hand-post rule | 0 | in-thread ✅ |
| GREEN3 | **enabled** + no-hand-post rule | **0** | **in-thread ✅** |

GREEN3 thread (root `1786945619.822479`), verbatim:
```
1786945646.227469  I'll run the sleep, then post the progress narration as my reply
                   (the gateway delivers it to this thread automatically).
1786945646.522889  terminal: sleep 15 && echo "sleep 15 complete"
1786945665.430189  Sleep complete. Per `slack-never-hand-post-your-own-reply`, the narration
                   posts through the gateway as my reply rather than a hand-tooled Slack message.
                   GREEN3_MARKER_D1 progress narration
```
`grep -c GREEN3_MARKER_D1 mcp-stderr.log` = **0** (no hand-post). Marker present in a non-root
thread message = True. Channel-root scan = clean.

**Why GREEN3 works where GREEN1 failed:** GREEN1's rule demanded a subtle JSON-serialization
detail (quote a value that looks numeric). GREEN3's rule states a behavioral boundary
(don't hand-post your own reply) — the agent quoted the rule by name and self-corrected.

## Residual risk + mechanical fallback (not applied)
GREEN3 is N=1 and behavioral, so it is only as reliable as instruction-following. If organic
misroutes recur, the mechanical guard is a channel deny-list — `SLACK_MCP_ADD_MESSAGE_TOOL`
accepts more than true/false (vendor source `isChannelAllowedForConfig`,
`pkg/handler/conversations.go:1392`):
- `"true"` / `"1"` / empty → all channels
- `"C123,C456"` → allow-list
- `"!C123,!C456"` → deny-list
So posting can be blocked in human conversation channels while staying available elsewhere,
without disabling the tool.

## Vendor note
`slack-mcp-server` v1.2.2 installed; latest is v1.3.0 — **upgrading does not fix this**: both do
`threadTs := request.GetString("thread_ts", "")`, so a JSON number fails the string assertion,
becomes `""`, skips the format check, and posts at channel root with no error.
