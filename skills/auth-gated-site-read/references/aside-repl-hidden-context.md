# Aside REPL — `openTab` puts tabs in a HIDDEN context, not the user's visible Aside GUI

The `aside repl` CLI (and the `mcp__aside-mcp__repl` tool) runs JavaScript in a **sandboxed REPL context inside the Aside daemon process**. This is **separate from the `Aside.app` GUI window** you see in the dock.

## What this means in practice (CLI path)

- `await openTab('https://...')` opens a tab in the **REPL's hidden context** — NOT in the visible Aside window
- The `✔︎ Opened a new tab and set it active: tabs[N]` log line refers to the REPL's internal tab index, not the GUI's active tab
- Form fills (paste, click, fill) go into the REPL's hidden tabs, not the ones the user can see
- `listBrowserTabs()` returns `{}` (empty) — you cannot enumerate visible tabs
- `attachActiveBrowserTab()` returns `{}` (empty) — you cannot attach to the GUI's active tab
- There is NO `setActive` / `showTab` / `focusTab` / `selectBrowserTab` / `bringToFront` — verified 2026-08-05

## The trap (CLI path)

If you call `openTab` 7 times in a row via `aside repl`, you end up with 7 hidden tabs that the user **cannot see**. The visible Aside window keeps showing whatever tab it was on when you started. The user will report "I only see one tab" — but the other 6 actually exist, just in the hidden REPL context.

## CORRECTION (verified 2026-08-05) — the Aside HTTP MCP at 127.0.0.1:8013/mcp DOES expose the visible GUI's tabs

The CLI path described above (`aside repl`, `mcp__aside-mcp__repl`) is incomplete. There is a **separate HTTP MCP server** at `http://127.0.0.1:8013/mcp` (started by `aside mcp` per the `aside-browser-default` skill) that exposes the full async Playwright API and CAN enumerate visible GUI tabs:

```bash
# 1) Initialize MCP session (read mcp-session-id header from response)
SID=$(curl -sS -i --max-time 15 -X POST "http://127.0.0.1:8013/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"my-agent","version":"1.0"}}}' \
  | grep -i 'mcp-session-id' | sed 's/.*: //;s/\r//')

# 2) Call tools/call — listBrowserTabs() returns the REAL visible GUI tabs
curl -sS --max-time 30 -X POST "http://127.0.0.1:8013/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "mcp-session-id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"repl","arguments":{"title":"List GUI tabs","code":"const t = await listBrowserTabs(); console.log(JSON.stringify(t.map(x => ({title: x.title, url: x.url, windowId: x.windowId, active: x.active})), null, 2));"}}}'
```

Returns real tab objects with `targetId`, `windowId`, `url`, `title`, `active` — verified 2026-08-05 in the House-of-the-Dragon social-poster run with 9 visible tabs across LinkedIn/X.

**Key differences: CLI vs HTTP MCP path**

| Aspect | `aside repl` / `mcp__aside-mcp__repl` (CLI) | `http://127.0.0.1:8013/mcp` (HTTP MCP) |
|---|---|---|
| `listBrowserTabs()` | sync stub, returns `{}` | async, returns real tabs |
| `attachActiveBrowserTab()` | sync stub, returns `{}` | async, returns real `Page` |
| `attachBrowserTab(targetId)` | not exposed | async, returns real `Page` |
| `openTab(url)` | spawns into hidden REPL context | spawns into NEW Aside window per call |
| Visible to user? | NO (hidden context) | YES (but in NEW windows per call) |

## MCP `openTab()` pitfall (verified 2026-08-05)

Each `openTab(url)` via the HTTP MCP spawns a **NEW Aside window**. Batching N platforms into one MCP call creates N separate Aside windows, only one of which is visible to the user at a time. `listBrowserTabs()` only returns tabs from the most-recently-active window. To keep tabs accumulating in the visible window, call `attachActiveBrowserTab()` between `openTab` calls, OR run batches that fit in one window (close previous windows with `closeTab(p)` after capturing screenshots if you need to reset).

## MCP session lifecycle (verified 2026-08-05)

- Read `mcp-session-id` from the `initialize` response header — send on every subsequent `tools/call`.
- Sessions expire after 2-3 minutes of inactivity. Re-initialize in the same `bash` invocation if running multiple batches.
- Per-MCP-call budget is ~5-8 `openTab`+`fill`+`screenshot` blocks before the daemon degrades (returns `Bad Request: No valid session ID provided`).
- **DO NOT send `notifications/initialized`** — breaks subsequent calls with `No valid session ID provided`. (Confirmed 2026-07-15 + 2026-08-05.)

## How to surface the work to the user

Pick one of these BEFORE calling `openTab`:

1. **Open in the user's default browser via `open -a "Google Chrome" <url>`** — tabs are visible immediately, but you cannot paste programmatically (no signed-in session for the agent, no extension bridging)
2. **Display the draft text in the reply** and have the user paste manually — reliable but tedious
3. **Use the `social-poster` skill's `stage_in_aside_mcp.py`** — this script bridges to the visible Aside GUI via the MCP HTTP server (separate from the REPL CLI). Verified working 2026-07-17 for HN, Twitter, Reddit, Mastodon, Dev.to. **Updated 2026-08-05:** also works for LinkedIn/Reddit/HN when batched per window with `attachActiveBrowserTab()` between calls.

## What NOT to trust (CLI path)

- The REPL output `✔︎ Opened a new tab and set it active: tabs[N]` — N is the REPL's internal index, not the GUI's tab strip
- The fact that `openTab` returns a `page` object you can `snapshot` / `screenshot` — the screenshot is real, but the user's visible browser shows nothing
- `listBrowserTabs()` returning `{}` — this is not a bug, it's the API correctly reporting nothing in the CLI's hidden context

## Verified

- 2026-08-05 (House-of-the-Dragon social-poster run): opened 7 platforms in CLI REPL via `openTab`, all with drafts pasted. User reported "I only see the Twitter thing." Root cause: REPL had 7 hidden tabs, GUI had 1 visible tab. **Recovery:** switched to the HTTP MCP path at `127.0.0.1:8013/mcp` — `listBrowserTabs()` returned real tabs; `attachActiveBrowserTab()` / `attachBrowserTab(targetId)` worked; `openTab()` opened into new Aside windows. Per-window batching with `attachActiveBrowserTab()` between `openTab` calls kept the user's visible window populated.