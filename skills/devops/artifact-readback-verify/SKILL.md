---
name: artifact-readback-verify
version: 1.3.0
description: |
  Read back after write, grep for a token, then claim success. Also covers
  verifying an UPSTREAM agent's claim ("I attached the screenshots", "mocks are
  in the PR") and proving CSS/layout claims with a computed-style probe rather
  than a screenshot.
when_to_use: |
  When crossing a system boundary to post, upload, push, merge, or commit and about to assert the artifact landed.
  ALSO when inheriting a handoff that claims an artifact already exists (attachments, PR, branch, commit) —
  verify before restating it. ALSO before claiming any sticky/fixed/pinned/responsive UI behavior.
triggers:
  - "where's my screenshot"
  - "did the upload land"
  - "I don't see the file"
  - "verify upload"
  - "proof readback"
  - "uploaded the mockups"
  - "screenshots attached"
  - "sticky action bar"
  - "responsive mobile viewport"
  - "verify this claim"
  - "did that actually land"
allowed-tools:
  - terminal
  - read_file
context: inline

---

# artifact-readback-verify

A readback-and-grep pass between "I sent it" and "I claim it worked" eliminates the most common agent failure pattern: posting a status message that asserts an artifact landed, when actually the artifact was lost, attached to the wrong target, or generated but never uploaded.

## The contract

```
write(spec) → readback(target) → grep(token) → THEN assert success
```

1. **write(spec)** — issue the write with the exact artifact / target / payload.
2. **readback(target)** — fetch back from the destination what should now be present.
3. **grep(token)** — search the readback response for an unambiguous token (file_id, URL, SHA, branch name, row id) that can ONLY be present if the write landed.
4. **THEN assert success** in your user-facing reply. NEVER skip step 3 — the absence of a verification token is a failure signal you must report.

## Slack uploads specifically (files.completeUploadExternal)

This is the canonical case. The 3-stage API returns `ok:true` for Stage 3 even when the file-share is broken in subtle ways (missing channel permission, wrong thread_ts, file already deleted from team file space, etc.). The user-visible cost is exactly the failure on `C0AH3RY3DK6/p1785953173.319919` 2026-08-06: agent said "files attached" → user said "where's the screenshot" → agent re-fetched and the files were actually attached (but at a different `ts` than the most recent message, so the agent's first verification fetch missed them).

### The verification command

After Stage 3 returns `ok:true`, run the readback with a tight time window around the upload:

```bash
UPLOAD_TS="1785990850.842849"   # capture from the Stage 1 response, or the share ts printed by Stage 3
LOWER=$((${UPLOAD_TS%.*} - 5))
UPPER=$((${UPLOAD_TS%.*} + 5))
curl -fsS \
  "https://slack.com/api/conversations.replies?channel=C0XXXXXXX&ts=1783038068.695729&limit=200&oldest=${LOWER}.000000&latest=${UPPER}.999999" \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  | jq '[.messages[] | select(.files != null) | {ts: .ts, file_ids: [.files[].id]}]'
```

Confirm `file_ids` from Stage 1 appear in the windowed response before claiming "uploaded."

### Why the open-ended fetch fails

```bash
# BAD — silently misses file-shares that aren't in the most recent N messages
curl -fsS "https://slack.com/api/conversations.replies?channel=C0XXXXXXX&ts=1783038068.695729&limit=10"
```

The `limit=10` (or 30, or 50) only returns the most recent N messages. The file-share is a separate bot-message that can land 1, 5, or 20 messages AFTER your summary text post. If the conversation accumulated messages during the multi-second upload window (CI polling, babysit cron firings, other agent activity), the file-share is NOT in the recent-N window and the verification looks like a failure even though it succeeded.

## GitHub operations

| Operation | Readback contract |
|---|---|
| `gh pr create` | `gh pr view <N> --json url,state,headRefOid` — verify the URL returned by create matches a real PR. |
| `gh pr comment <N>` | `gh api repos/<owner>/<repo>/issues/<N>/comments?per_page=3 \| jq '.[] \| select(.user.login == "your-bot") \| .body'` — verify your bot posted it. |
| `gh pr merge <N>` | `gh pr view <N> --json state,mergedAt,mergeCommit` — verify `state=MERGED` and `mergedAt` non-null. |
| `git push` | `git ls-remote origin <branch>` and compare SHA — verify the remote SHA matches your local HEAD. |
| `gh gist create` | `gh api gists/<gist-id>` — verify the gist exists and contains the expected files. |
| `gh workflow run` | `gh run list --workflow <name> --limit 1 --json databaseId,status,conclusion` — verify a run got created and isn't stuck in `queued`. |

## MCP returns ok:true ≠ wrote successfully

The MCP gateway can return `ok:true` for tools that produce side-effects, but the actual side-effect may not have landed (token scope missing, target object archived, downstream rate limit returned before propagation). For every MCP write that says `ok:true`, run a follow-up readback that proves the side-effect landed. Examples:

- `mcp__slack__conversations_add_message` returning `ok:true` and a `ts:` → verify with `conversations_replies(thread_ts=<channel>)` that the message actually appears.
- `mcp__github__create_or_update_file` returning success → verify with `mcp__github__get_file_contents` that the file matches.
- `mcp__git__git_commit` returning a SHA → verify with `git show <sha>` that the commit tree matches what you wrote.

## Direct curl `chat.postMessage` readback (cron / gateway-bypass path)

When the Hermes gateway is wedged or you need to bypass MCP entirely (cron jobs use `bash -lic` to source `SLACK_BOT_TOKEN` and post via direct curl), the readback pattern is identical but with one extra parsing step. The Stage 1 response (`{"ok":true,"channel":"C0XXX","ts":"1786417664.207229","message":{...}}`) contains a full Slack message envelope with the bot identity — but the message body often embeds MP4 HLS metadata as base64 control characters that break naive `json.loads`.

**Verification recipe (verified 2026-08-10 EA sweep, post ts=1786417664.207229):**

```bash
# 1. Tight-window fetch around the post ts (same as the MCP readback pattern)
curl -fsS "https://slack.com/api/conversations.history?channel=C0AJQ5M0A0Y&limit=1" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" | head -c 500

# 2. Fallback regex extraction when JSON.parse fails on embedded media:
curl -fsS "https://slack.com/api/conversations.history?channel=C0AJQ5M0A0Y&limit=20" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  | grep -oE '"ts":"[0-9.]+"' | head -20

# 3. Confirm the new ts matches what chat.postMessage returned
#    Expected: 1786417664.207229 should appear in the ts_list from step 2.
```

**Pitfall — JSON.parse on Slack API responses with file attachments:**
The `files[].hls_embed` and `mp4` metadata fields contain base64-decoded MP4 headers with control characters. Python's `json.loads(resp)` raises `JSONDecodeError: Invalid control character at: line 1 column 19971` even with `strict=False`. Two fixes:
- Write the raw response to `/tmp/replies.json` and parse with `json.load(open(path), strict=False)` — this works for the channel-history case.
- For threaded replies where the body is huge: extract via regex, e.g. `re.findall(r'"ts":"([\d.]+)"', body)` + `re.findall(r'"text":"([^"\\]{0,300})"', body)`, then join by index. Crude but reliable.

**Token source for cron / bypass path:**
```bash
# In a cron job or bash -lic subshell:
TOKEN=$(bash -lic 'echo "$SLACK_BOT_TOKEN"')
# The bash -lic form sources ~/.bashrc which exports the token from the
# launchd-env-wrapper contract. Do NOT read it from a non-login shell —
# see memory `bashrc-profile-xapp-drift-blocks-launchd` for the gotcha.
```

**Critical anti-pattern — "delivery succeeded, gateway must be fine":**
A successful cron delivery via direct curl is NOT proof the Hermes gateway is healthy. Verified case 2026-08-10: EA cron posted normally at 16:01 PT (ts=1786402898) while the gateway had been silently wedged since 16:45 PT (3h20m of no #ai-general channel activity). The cron bypasses the gateway HTTP entirely. Always include an explicit gateway health probe in any sweep brief — see `hermes-health-check` skill: `lsof -p $(pgrep -f 'hermes gateway run') | grep LISTEN` must show `*:8643` (or whatever port). If empty, surface the wedged state as `:large_red_circle:` regardless of whether the current post landed.

## Readback applies to *inherited* claims, not just your own writes

The contract above guards your own writes. The same readback guards an **upstream
agent's claim** that it wrote something. A handoff message is an assertion, not
evidence — and it fails in exactly the same ways.

Verified 2026-08-14 (worldarchitect.ai PR [#8915](https://github.com/jleechanorg/worldarchitect.ai/pull/8915)):
a handoff read *"Uploaded the 4 visual mockups to this DM: 1. Mock 1 (Desktop)... 2. Mock 2..."*
with four labelled paragraphs. The message's `files` array was **empty**. Nothing
had ever been uploaded — the agent narrated its intent as completed fact. Repeating
that claim onward would have propagated a fabrication.

**Rule: before you restate any inherited "I attached / I pushed / I created X"
claim, readback the target yourself.** One call each:

| Inherited claim | Readback | Failure signal |
|---|---|---|
| "screenshots attached to thread" | `conversations.replies?channel=…&ts=…&limit=20`, inspect `files[]` | `files= []` on a message whose text claims attachments |
| "mocks are in the PR" | `gh pr view <N> --json body --jq .body \| grep -c '!\[` | `0` = no inline images; reviewer sees filenames, not images |
| "PR is open at #N" | `gh pr list --head <branch> --state all --json number,url` | `[]` = the PR does not exist yet |
| "pushed to branch" | `git ls-remote origin refs/heads/<branch>` | SHA absent, or ≠ the SHA they named |
| "committed at SHA X" | `git show --stat <sha>` | unknown object, or diff ≠ described scope |
| "CI green / `/er` PASS / 21 checks passing" | `gh pr checks <N> --repo <owner>/<repo> --json name,state,conclusion` | any `conclusion="failure"` or `state="CANCELLED"` row contradicts the claim |
| "screenshot shows X" — image is present, content doesn't match caption | hash + size + caption + vision probe | hash distinct but image actually shows different page state than caption describes |

Empty-array and empty-list results are the tell. `files= []`, `[]`, and `grep -c` →
`0` are all *positive evidence of absence*, not inconclusive noise — report them as
findings.

**Caption-vs-image-content mismatch is the most pernicious variant.** When an
upstream agent posts a screenshot, the image is *present* (so `files= []` does
not fire), but the actual page rendered in the image does not match the caption's
description of what state it should show. Verified 4 rounds in a row in
`#worldai` PR #8829 (2026-08-16, jleechanorg/worldarchitect.ai): the AI Terminal
lobby posted three images per round with captions that described
"unified composer card with three choice cards, gold hover border, pre-filled
textarea, single Send button" — but the images were the **My Campaigns dashboard**
view (search box, sort filters, campaign list). The captions rotated between
"Mock HTML", "Real Server UI", "Realistic UI Mock", "Clean" — yet the screenshot
payload was the same dashboard view, captioned with descriptions of the in-game
view.

Four-step readback for an image-bearing handoff:

1. **Hash the file.** `sha256sum path/to/screenshot.png` — distinct hashes prove
   non-identical files; size variance alone is just PNG compression.
2. **Size class.** Pragmatic proxy (NOT authoritative): ~95 KB ≈ mock HTML,
   ~155 KB ≈ design-intent mock, ~256-279 KB ≈ real preview capture, ~435-519 KB
   ≈ dashboard view. Verify the proxy against the actual rendered content, not
   the file size alone.
3. **Caption content.** Parse the caption for the specific UI elements claimed
   (e.g. "choice cards", "textarea", "Send button", "Debug Info bar"). Note them.
4. **Vision probe.** Open the image with `vision_analyze` and ask: does the
   image actually show those elements? Report per-claim, not in aggregate:
   "caption says X, image shows Y, claim is false."

Use `scripts/probe_image_caption_match.py <image-path> --caption "<copy-pasted
caption>"` for an automated prompt that asks vision for each element the
caption lists. See `references/visual-content-vs-caption-mismatch-2026-08-16.md`
for the full 4-round incident, the per-image hash table, and the assertion
shape that catches this.

**Corollary — the branch may move under you.** In the same session the target
branch advanced three times (`0719ee5f78` → `4d8171af28` → `6fddfef081`) while the
verification ran, because a concurrent agent was pushing. Re-`git fetch` and
re-read the remote SHA immediately before asserting anything about branch content,
and quote the SHA you actually verified against. A verdict attached to a stale SHA
is wrong even when the method was right.

## Heredocs / giant inline payloads get hard-blocked — write a file instead

Piping a long message body into `python3 -` via heredoc inside the `terminal` tool
trips an unconditional command-parser blocklist:

> BLOCKED (hardline): command parser limit or malformed executable payload.

This is a **payload-shape** block, not a permissions block — retry, `--yolo`, and
approval modes all fail against it. Readback-friendly pattern for any
multi-paragraph post or long payload:

1. `write_file` the body to `/tmp/<name>.txt`.
2. `write_file` a short `.py` that reads that file, reads the token from
   `~/.bashrc`, and calls the API via `urllib.request`.
3. `terminal` runs `python3 /tmp/<name>.py` — short and parseable.

Bonus: the payload stays reviewable on disk, and the token never appears in a
command line (which also keeps it out of any transcript the outbound secret gate
would have to redact).

## patch tool failure mode — fallback to heredoc

The `patch` file-edit tool (`mode='replace'`, `path`, `old_string`, `new_string`) can return `path required` 3 times in a row on the same call even when `path` is correctly passed. **Three identical failures is the signal — stop retrying with the same arguments** and switch to a `python3` heredoc via `terminal`:

```bash
cd /path/to/worktree && python3 << 'PYEOF'
path = 'mvp_site/frontend_v1/index.html'
with open(path, 'r') as f: c = f.read()
old = '<unique-50-char-context-block>'
new = '<replacement>'
assert old in c, 'old_string not found'
with open(path, 'w') as f: f.write(c.replace(old, new, 1))
print('OK')
PYEOF
```

Then `read_file` (or `grep -n`) immediately to confirm the patch landed — the print only confirms the python script ran, not that the file changed.

**Why heredoc, not `execute_code`**: the heredoc needs to be inline in the terminal command (otherwise the shell can't pass the EOF boundary). `execute_code` runs a Python function and can't handle inline multi-line strings with literal backticks `${...}` reliably — the shell layer eats them. Some terminal jobs MUST go through `terminal()` as raw heredoc.

**The assertion in the heredoc is the readback.** `assert old in c, 'old_string not found'` is the canonical "did the write target exist" readback. If it fires, you get a clear `AssertionError` instead of a silently-no-op replacement. Without it, the heredoc happily writes `c2 = c` and the file's content is unchanged.

**The `'PYEOF'` quote matters.** The unquoted heredoc delimiter (`<< PYEOF`) lets the shell expand `$variables` inside the heredoc, which mangles path strings containing `$`. Always quote the delimiter when the script contains literal `$` characters (paths, regex backrefs, JS template literals).

Verified 2026-08-19 (worldarchitect.ai PR #9089, "move hide dice roll toggle to settings"): exact-same `patch` failure pattern → heredoc fallback → 6 files patched cleanly, 24/24 contract tests pass, PR opened.

## When the existing infra already does the thing

Before writing a new handler / wiring / glue, scan the project for a generic framework that already handles the pattern. Common examples:

- **Settings schemas**: a `SETTINGS_SCHEMA` array that loops and POSTs arbitrary entries
- **Toggle models**: a `<Toggle>` fragment that hydrates state, renders, and POSTs change
- **Feature flag tables**: a single dict that maps key → default + handler
- **Provider registries**: a switch-on-key that picks implementation at runtime

These frameworks give you load/POST/save for the cost of a one-line entry. Writing a new handler when one of these exists is a maintainability regression and a process violation against the AGENTS.md file protocol.

Read-back: search for the framework name first (`search_files "SETTINGS_SCHEMA"`), then for the existing entries — they tell you the exact shape to add. Verified 2026-08-19 (PR #9089): the `mechanics_hidden` toggle moved from a custom in-game handler to a one-line `SETTINGS_SCHEMA` entry that gets the same load/POST/save treatment as `debug_mode` and `faction_minigame_enabled`. Result: 6 files / +119/-95 instead of +200/-150 with a handwritten handler.

## Cron and launchd

- After `hermes cronjob create`, verify with `hermes cronjob list` that the job exists, is `enabled: true`, has the right `next_run_at`, and was created with the right `prompt` (not truncated).
- After `launchctl load`, verify with `launchctl print gui/$(id -u)/<label>` that the service reached `state = running`.
- After stopping a babysit, verify with the same `list` query that the job is `state = completed` or `paused` — never assume.

## The reporting rule

When the readback PASSES — say it. Quote the unambiguous token you found.

```
@channel PR #8781 BEFORE/AFTER PNGs attached to thread ts 1785990850.842849 (file_ids F0BND6N6GV8, F0BNB7MMKQE).
Verified via windowed conversations.replies fetch with oldest=1785990845 latest=1785990855.
```

When the readback FAILS — say it explicitly. Don't fall back to "I think it worked" or "should be there." Report the actual finding and the next action.

```
@channel Stage 3 returned ok:true but windowed conversations.replies does NOT contain file_id F0XXXX.
Possible causes: bot lacks files:write scope on channel C0XXXX, or stage 3's thread_ts was wrong,
or there's a Slack propagation delay (retry in 30 s).
```

## Anti-patterns

- ❌ Telling the user "uploaded" without re-fetching. 2026-08-06 PR #8781 is the canonical example: agent skipped Stage 3 verification and reported "uploaded" then user's "I don't see the screenshot" was the pushback.
- ❌ **Claiming "I committed the CSS fix" when the on-disk file silently reverted (added 2026-08-18, PR #9096 avatar-button fix).** The agent saved pre-fix bytes into a `backup_*` variable, `git show origin/main:path > on-disk-file` for the BEFORE swap, then crashed mid-capture, then restarted the server, then wrote the backup back — except the capture script's "restore fix" step ran AFTER the server-restart had already pulled a clean state, and the `restore` overwrote a file whose content was now the "patched" version with the wrong bytes. `git diff --stat origin/main..HEAD` later showed empty because the working tree was the pre-fix baseline. The textbook recovery is a pre-AND-post `rg -c` integrity check: BEFORE the swap, `wc -c <file>` and `sha256sum <file>` and `rg -c <expected-new-token> <file>` into a log line. AFTER the restore, the same three checks. If post-restore `sha256sum` ≠ pre-swap-stored-new-sha, you have a state-replay bug; re-apply the patch from `git diff` against the working-tree baseline and verify. Verified line counts: pre-fix `mvp_site/frontend_v1/css/avatar.css` was 9654 bytes / zero `.game-avatar-add-btn` hits; post-fix expected 11942 bytes / 10 hits; observed after the bug was 9654 bytes / zero hits. The byte-count delta was the readback — restoring from a stale backup silently produces a file that LOOKS right under `ls -la` (size unchanged by similar-magnitude edits), so always compare against a real expected-token grep, not just file size.

- ❌ **Trusting a `file://` HTML harness for CSS readback when the harness is supposed to import the real worktree CSS (added 2026-08-18, PR #9096 avatar-button fix).** A standalone harness at `<worktree>/evidence/_harness.html` with `<link href="../../mvp_site/frontend_v1/css/avatar.css">` loaded from `file://` returns 404 for some Chromium configurations — the relative path resolves fine but Chromium blocks cross-origin CSS imports from `file://` origins in others, and `<style>` overrides in the harness render the new CSS rules WITHOUT the new rule ever loading. Symptom: `getComputedStyle('.game-avatar-add-btn').borderRadius === '0px'` (browser default) when the worktree CSS does in fact define `border-radius: 50%`. Always serve the harness via the SAME Flask server (`run_test_server.sh start`) — `http://localhost:8081/evidence/_harness.html` returns 200 AND serves the real CSS. Two-step probe: (1) `curl -s http://localhost:8081/frontend_v1/css/avatar.css | grep -c <expected-token>` — if 0, your file path is wrong or the server cached the old bytes; (2) `await page.evaluate(...).getComputedStyle('.game-avatar-add-btn').borderRadius` — if `'0px'` after the CSS rule is on disk, the harness did not load the rule, period. Companion note: `devpython`/server restart is the canonical way to bust static-file caches between captures; a server restart between every swap is non-negotiable for the BEFORE/AFTER round-trip recipe.
- ❌ Trusting `ok:true` from any MCP / REST write without a corresponding readback.
- ❌ Open-ended readback scans. Always scope to a tight time window around the write, OR a tight semantic filter (`select(.user.login == "<your-bot>")`), OR a known-unique substring.
- ❌ Assuming the Hermes gateway is healthy because a cron post delivered. Verified 2026-08-10: EA sweep posted normally at 16:01 PT while gateway was wedged for 3h20m (process alive but zero LISTEN sockets). Cron delivery via `bash -lic + direct curl` bypasses the gateway entirely. See `references/cron-direct-curl-chat-postmessage-readback.md` for the readback pattern that handles this case AND the silent-outage detection recipe.
- � Reporting "ffmpeg can't decode this mp4, must be broken" when the file is fine. macOS stamps `com.apple.provenance` on files written to `${HOME}/Downloads/` from certain sources (browser downloads, Slack drag-drops, screenshot tools); ffmpeg/dd/xattr/shasum then return `Interrupted system call` (EINTR) on every read. The exact same bytes at `~/.smartclaw/cache/videos/<id>.mp4` (no provenance xattr) decode cleanly. Symptom: `ls -la` works, `ffprobe` fails; or first read works, subsequent reads fail. Probe with `xattr <file>` — if `com.apple.provenance` is present, switch paths. See `references/macos-provenance-xattr-eintr-2026-08-18.md` for the verified recipe, the curl-fetch fallback, and the assertion shape that survives the path switch.
- ❌ Claiming "image shows X" based on caption alone. The caption-vs-image-content mismatch pattern (4 rounds in PR #8829, 2026-08-16) is the highest-cost inherited-claim failure mode: the image is real, the caption is plausible, but the two are decoupled. Always run `vision_analyze` and probe the actual elements the caption mentions. See `references/visual-content-vs-caption-mismatch-2026-08-16.md`.
- ❌ Shipping PNGs that don't show the feature surface you claim (2026-08-18, PR #9070). When the live-server path is broken (MCP down, Quick Start button doesn't navigate, CORS preflight rejects the test bypass), don't capture whatever the broken page happens to render and ship it — the user will catch it ("Risks don't make sense for char creation though" was the rejection). **Mandatory step before committing a visual-evidence PNG:** run `vision_analyze` and confirm the rows/elements match the feature the change targets. If they don't, fall back to the **standalone HTML harness** recipe (`references/private-repo-image-embed-and-standalone-harness-2026-08-18.md` §2) — inline the real CSS in `<style>`, render the targeted DOM, run the computed-style probe to prove the rule resolves.
- ❌ Embedding `raw.githubusercontent.com/.../evidence/foo.png?raw=true` URLs in a PR body for a private repo (2026-08-18, PR #9070). Those URLs require a short-lived bearer token (`?token=...` from `gh api ... --jq .download_url`) that expires within minutes — the PR view fetches images as a logged-in browser, not as your gh CLI session, so it has no token and the embed 404s. Use `https://github.com/OWNER/REPO/raw/BRANCH/path` instead — it routes through GitHub's authenticated CDN and renders inline. Always verify the embed URL with `curl -fsSL -o /dev/null -w "%{http_code}\n"` BEFORE posting the PR body.
- ❌ Claiming "CI green / `/er` PASS / 21 checks passing" based on the agent's own summary. The PR's own caption can claim "all gates passed" while `gh pr checks` shows a FAILURE. The readback is `gh pr checks <N> --repo <owner>/<repo> --json name,state,conclusion` — filter for any `conclusion="failure"` or `state="CANCELLED"`. Verified PR #8829 rounds 1 and 3: AI Terminal lobby posted "Light/Fantasy Compliance Gate: SUCCESS" while the actual run was `state=FAILURE`. See `references/ci-summary-vs-gh-pr-checks-2026-08-16.md`.

## CI summary vs `gh pr checks` reality gap

The terminal's PR summary is an *assertion*, not a *measurement*. When an
incoming handoff claims the PR is green, the only authoritative readback is the
actual `gh pr checks` output:

```bash
# The canonical readback. REST via --json field is limited; use --template.
gh pr checks <N> --repo <owner>/<repo> \
  --json name,state \
  --template '{{range .}}{{printf "%-50s state=%s\n" .name .state}}{{end}}'

# Or REST directly (GraphQL may be rate-limited):
gh api repos/<owner>/<repo>/commits/<head-sha>/check-runs \
  --jq '.check_runs[] | "\(.name)\t\(.status)\t\(.conclusion)"'
```

Filter for any of these failure signals:

- `state=FAILURE` — gate did not pass
- `state=CANCELLED` — gate run was cancelled (often a different fix, but still
  means ALL checks did not pass; the PR mergeability gate is "all checks successful")
- `state=SKIPPED` — gate did not run (often a self-hosted runner or path-filter
  skip; treat as neutral, NOT as success)
- `state=NEUTRAL` — third-party bot (e.g. Cursor Bugbot) could not run; do not
  count as either pass or fail

The PR's `/green` gate in `worldarchitect.ai` AGENTS.md is **"all CI checks
successful AND no merge conflicts"** — not "all checks SUCCESS, SKIPPED counts as
PASS, NEUTRAL counts as PASS." A `SKIPPED` self-hosted runner is NOT the same
as `SUCCESS`. Restate the claim only when every row matches the appropriate
state (the `worldarchitect.ai` agent's `green` gate requires `SUCCESS` for all
applicable `check-runs`).

**The "21 CI checks passing" trap.** Verified 2026-08-16 (PR #8829 round 1):
the AI Terminal summary claimed "21 CI checks passing" and `/er PASS`, but the
actual `gh pr checks` output showed 19 SUCCESS, 1 FAILURE, 1 CANCELLED. The
agent's summary was a textbook self-report false-green. The summary's only
authority is the `gh pr checks` output itself — not the polished ICYMI banner.

**Stale verdicts.** A "green" verdict on commit `fcb2a3ec` becomes a stale
verdict the moment the worker pushes commit `d3615204` and Light/Fantasy
Compliance Gate queues again. Never restate a "green" verdict unless you have
read `gh pr checks` for the *current* HEAD SHA. Always quote the SHA you
verified against, and re-verify on every new commit.

## Visual/CSS claims need a computed-style probe, not a screenshot

A screenshot is evidence of **pixels**, not of **behavior**. For any claim about how
an element behaves — sticky, fixed, pinned, collapsed, responsive-at-breakpoint —
a screenshot can look identical whether the claim is true or false. That makes it
not weak evidence but *non-evidence*: the readback contract is unsatisfied.

Canonical case (2026-08-14, PR [#8915](https://github.com/jleechanorg/worldarchitect.ai/pull/8915)):
`mobile_04_sticky_actionbar_viewport.png` was shipped as proof of a "sticky action
bar". The CSS had zero `position: sticky` and zero `@media` queries. The shot had
been taken *after scrolling to the bottom*, where a static footer sits flush at the
fold and is pixel-identical to a sticky bar.

|  | scroll-top | mid-scroll | scroll-bottom |
|---|---|---|---|
| static footer | not visible | not visible | flush at fold |
| sticky bar | flush at fold | flush at fold | flush at fold |

Only **scroll-top and mid-scroll** discriminate. Two greps falsify most such claims
before you even launch a browser:

```bash
grep -c 'position: sticky' path/to/file.css   # 0 => claim is false, stop here
grep -c '@media'           path/to/file.css   # 0 => not responsive, stop here
```

Use `scripts/probe_layout_claim.py <url-or-path> --selector .actions-bar
--width 390 --height 844 --expect sticky` — it asserts at scroll-top and mid-scroll
and exits non-zero when the claim fails.

Two companion rules:

- **Capture `full_page=True`** for forms/wizards/long panels. In the same incident,
  viewport-clipped shots cut the live LLM prompt-directive preview — the feature's
  whole point — off the bottom of its own evidence.
- **Assert on text, not only pixels**: `inner_text()` + a substring check turns a
  visual claim into a hard failure on regression. Watch for label drift (that
  session's probe first failed because `[NARRATIVE GOAL]` had been renamed
  `[NARRATIVE DIRECTIVE]`) — read current source before hardcoding a needle.

### Recipe C — inline-style substitution for single-rule CSS diffs (added 2026-09-14)

When the BEFORE/AFTER diff is **exactly one rule in one file**, neither Recipe A
(override-on-base) nor the swap-and-restore dance fits cleanly. The third recipe
inlines the FULL BEFORE or AFTER CSS as a `<style>` block in the harness HTML,
substitutes it for the `<link>` tag, and renders via `page.set_content`. No
server restart, no disk mutation, no risk of silent state replay.

**When to use Recipe C over Recipe A**: Recipe A's override-on-base is wrong when
the AFTER adds a rule that has no symmetric "disable" form in BEFORE — you end
up testing "CSS minus new rule" vs "CSS plus new rule", not the actual diff
shape.

**When to use Recipe C over swap-and-restore**: swap-and-restore takes 60-90s
per pair due to the server-restart dance and risks silent disk-state replay
(see `references/wa-swap-restore-state-replay-2026-08-18.md`). Recipe C captures
both PNGs in <2s with no on-disk changes and no server downtime.

**Drop-in template and the textarea-sizing pitfalls** (box-sizing: border-box
making `height` include padding+border, AND `rows="N"` setting intrinsic height
that beats `min-height` alone) live in
`references/wa-css-inline-style-substitution-2026-09-14.md`.

## References

- `references/slack-upload-window-scan-2026-08-06.md` — original PR #8781 incident; the `oldest`/`latest` time-window fetch pattern.
- `references/cron-direct-curl-chat-postmessage-readback.md` — verified 2026-08-10 readback for cron/gateway-bypass posts, plus the "delivery succeeded but gateway is wedged" silent-outage detection recipe.
- `references/visual-claim-verification-2026-08-14.md` — PR #8915: four-way failure breakdown (narrated-but-never-uploaded attachments, sticky-bar screenshot that could not disprove itself, viewport-cropped evidence hiding the payoff element, PR committing images but embedding none) + the per-claim verdict shape.
- `references/visual-content-vs-caption-mismatch-2026-08-16.md` — PR #8829 rounds 1-4: caption-vs-image-content mismatch over 4 sequential lobby posts, with hash/size/caption triage table, the "dashboard view captioned as in-game view" pattern, vision-probe recipe, and the durable classification (Image present vs files=[] vs caption-vs-content).
- `references/ci-summary-vs-gh-pr-checks-2026-08-16.md` — companion to the visual-content-vs-caption incident: how AI Terminal summaries claim "21 CI checks passing" / `/er` PASS / `/green Gate 1 PASS` while `gh pr checks <N>` shows actual FAILUREs. Includes the failure-signal filter (`state=FAILURE | CANCELLED`) and the stale-verdict gotcha (`HEAD SHA` moved 3× during the same thread, breaking earlier "green" verdicts).
- `references/wa-css-token-contract-and-bootstrap-2026-08-18.md` — PR #9055: CSS-token contract test pattern (pin token value + var() fallbacks + rationale comment as one `node --test` suite), the four `worldarchitect.ai` bootstrap pitfalls for visual evidence (X-Test-Bypass-Auth header, test_user_id ownership, worktree venv symlink, `git stash` round-trip), and the computed-style probe as the canonical proof for CSS-size fixes.
- `references/wa-css-inline-style-substitution-2026-09-14.md` — PR #9900: **Recipe C** — full-file CSS swap via inline `<style>` substitution, no server restart and no disk mutation. The cleanest recipe when the BEFORE/AFTER diff is exactly one rule in one file. Covers the `box-sizing: border-box` + `rows="N"` textarea gotcha (use `height: 57px; min-height: 57px`, not just `min-height`, because `rows` sets intrinsic height that beats `min-height`). Drop-in template for any CSS-only fix.
- `references/private-repo-image-embed-and-standalone-harness-2026-08-18.md` — PR #9070: (1) private-repo image embed pattern (`github.com/<owner>/<repo>/raw/<branch>/<path>` not `raw.githubusercontent.com` — the latter 404s in PR view because it requires a short-lived bearer token), (2) standalone HTML harness fallback when the local dev server is unhealthy (MCP down, CORS preflight rejection) — inline the real CSS in `<style>` and use `set_content` to bypass the broken full-app path, then run the computed-style probe to prove the rule resolves, (3) `TESTING_AUTH_BYPASS` must be exported BEFORE `run_local_server.sh` starts Flask (main.py:353-365 reads the env var once at import time; if it's not in the process env, the CORS preflight returns `Access-Control-Allow-Headers: content-type` only and every `X-Test-Bypass-Auth` POST 401s).
- `references/macos-provenance-xattr-eintr-2026-08-18.md` — macOS `com.apple.provenance` xattr silently breaks ffmpeg/dd/xattr/shasum reads of freshly-written `${HOME}/Downloads/` mp4s with EINTR; the path switch to `~/.smartclaw/cache/videos/<id>.mp4` decodes the same bytes cleanly. Verified recipe (xattr probe, path switch, `ffmpeg -frames:v 1` frame extraction, vision-verify), plus the curl-fetch fallback when the path switch isn't available.
- `references/wa-swap-restore-state-replay-2026-08-18.md` — PR #9096: the silent disk-state-replay failure mode (saved pre-fix bytes into `backup_*` variable, swapped to origin/main for BEFORE capture, then restored from a backup that had become stale after a server-restart-induced state change, leaving the working tree at pre-fix content even though `ls -la` showed the right size). The `rg -c <expected-token>` + `sha256sum` integrity check that catches it. Companion (b) `file://`-vs-Flask harness CSS-import failure mode + the `curl -s http://localhost:8081/...css | grep -c` verification pattern.
- `scripts/probe_layout_claim.py` — runnable computed-style probe for sticky/fixed/responsive claims; exits non-zero when the claim fails.

