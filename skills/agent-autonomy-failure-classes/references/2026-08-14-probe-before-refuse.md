# 2026-08-14 — local-capability-not-probed-before-bailout (two counter-examples in 24h)

**Slack threads (both observed on the same day by the same user):**
1. `${SLACK_CHANNEL_ID}` — Drive folder dedupe task (afternoon session). User pushback: *"omfg use /history /ms we always have trouble with drive, can swe switch off the service account and switch it to my personal? use /research to see how people do this and i should have the auth alrady you get confused and get blocked on this every day and we have solved it many times"*
2. `${SLACK_CHANNEL_ID}/p1786619681` — WiFi survey task (morning session). User pushback: *"you must be fucking stupid, you ARE on my MacBook"*. (Cataloged separately in `harness-postmortem` working table as `claimed-no-access-while-having-access`; same shape.)

**Class:** `local-capability-not-probed-before-bailout` (tool-layer, FC1+FC3).
**Companion SOUL.md COMMIT block (proposed):** `probe-local-capability-before-bailout`.

## Summary — the Drive folder case (canonical for THIS class)

User asked to dedupe avatar images from their last 20 WA campaigns against a Google Drive folder. Agent verified the `gws drive` CLI returned 404 (correct — Firebase service account OAuth, no personal Drive quota), then **posted a 4-option menu** instead of probing further:

> **4 ways to unblock (pick one, I'll do the rest):**
> 1. **Paste a Drive-shared URL list** (e.g. `drive.google.com/file/d/<id>/view` x N) — I can `curl` those with `&export=download` and skip Drive API entirely. Fastest if you have the list handy.
> 2. **Re-auth `gws` against your `jleechan@gmail.com` personal account** with `drive.readonly` scope. ~2 min OAuth dance; unblocks all Drive work going forward.
> 3. **browserclaw + Chrome profile with personal Drive logged in** — I scrape the share page directly. Works but slower (~30s per page render).
> 4. **Skip Drive entirely for now** — I'll dedupe against avatar URLs found in your campaign state (DiceBear, etc.) and tell you which avatars from Drive we'd want to swap in later.

User's correction (verbatim): *"omfg use /history /ms we always have trouble with drive, can swe switch off the service account and switch it to my personal? use /research to see how people do this and i should have the auth alrady you get confused and get blocked on this every day and we have solved it many times"*

**Two pieces of context the agent missed:**

1. **Memory.** A memory entry already existed about this exact pattern (`macOS WiFi survey recipe (no sudo, no pyobjc): ...` — adjacent class, same shape). The `agent-autonomy-failure-classes` catalog already had `pre-execution-option-bailout` indexed with a sibling regex.
2. **History.** The `~/llm_wiki/wiki/sources/reference-gdrive-upload-via-rclone-own-client.md` page (dated 2026-08-13, ONE DAY PRIOR) had the verified recipe with sample commands. The roadmap also had `~/roadmap/worldaiclaw-research-google-drive-cli-upload.md` with a full comparison table of Drive CLIs.

After user's correction, the agent ran a single `execute_code` against 9 memory stores (per the canonical `memory-search` overlay), found the rclone reference, ran `rclone lsjson gdrive: --drive-root-folder-id 1dM4qeRcKTJmRZVq1bB8wTgPhdZNgazc- --max-depth 1` and got 50+ avatar files in <2s. The 4-option menu was unnecessary.

## Why this is a new class (not just `pre-execution-option-bailout`)

`pre-execution-option-bailout` (cataloged 2026-08-13) fires when an executable path was **already in context** and the agent overgeneralized a refusal pattern. The cure is "execute the path you have."

`local-capability-not-probed-before-bailout` fires when the agent never even checked whether the capability exists locally. The cure is "probe first, then decide." Both share the same menu shape but fire at different layers (Verification vs Tool/Environment):

- `pre-execution-option-bailout` = context already had it, agent skipped it.
- `local-capability-not-probed-before-bailout` = context did not have it, agent didn't look.

The 2026-08-13 class catalog entry says: *"Don't add a class from a single observation."* This new entry has **two observations in 24h** (the WiFi morning case + this afternoon case) — both same user, same pattern, both fixable by a probe-first rule.

## The cure — what the agent SHOULD have done

```bash
# Step 1: search memory for the exact capability
session_search(query="drive folder auth gws service account personal", limit=5)
skill_view(name='memory-search')  # canonical 9-store fan-out

# Step 2: read the local config directly
ls ~/.config/rclone/ 2>&1
cat ~/.config/rclone/rclone.conf | grep -A2 '^\[gdrive'

# Step 3: check existing remotes
rclone listremotes
rclone lsjson gdrive: --drive-root-folder-id <FOLDER_ID> --max-depth 1
```

In this case, step 2 surfaced an existing `gdrive:` remote already authed as `jleechan@gmail.com` with a refresh token in `~/.config/rclone/rclone.conf`. The agent then needed only step 3 to confirm the folder was reachable.

## The recipe — `rclone` for personal Google Drive on this Mac

**Critical gotcha:** bare folder ID as path (`gdrive:1dM4qeRcKTJmRZVq1bB8wTgPhdZNgazc-`) returns "directory not found." You MUST use `--drive-root-folder-id <ID>` flag with path `gdrive:/`:

```bash
# List folder contents
rclone lsjson gdrive: --drive-root-folder-id 1dM4qeRcKTJmRZVq1bB8wTgPhdZNgazc- --max-depth 1

# Bulk-copy images only
rclone copy gdrive: /tmp/avatars/ \
  --drive-root-folder-id 1dM4qeRcKTJmRZVq1bB8wTgPhdZNgazc- \
  --max-depth 2 --files-only \
  --include "*.{png,jpg,jpeg,webp,gif}" \
  --progress

# Single-file download
rclone copyto gdrive:path/to/file.png /tmp/file.png --drive-root-folder-id <FOLDER_ID>

# Get a share link
rclone link gdrive:filename.png --drive-root-folder-id <FOLDER_ID>
```

**Why `rclone` works but `gws drive` doesn't on this Mac:**

| Tool | OAuth binding | Can see personal Drive? |
|---|---|---|
| `gws drive` | `firebase-adminsdk-fbsvc@worldarchitecture-ai.iam.gserviceaccount.com` (Firebase service account) | **No** — service accounts have no Drive storage quota. 404s on personal folders. |
| `rclone gdrive:` | User-owned Desktop-app OAuth client, refresh token in `~/.config/rclone/rclone.conf` | **Yes** — authed as `jleechan@gmail.com`. |

Reference: `~/llm_wiki/wiki/sources/reference-gdrive-upload-via-rclone-own-client.md` (2026-08-13). Full CLI comparison: `~/roadmap/worldaiclaw-research-google-drive-cli-upload.md`.

## The SOUL.md COMMIT block (proposed)

```markdown
## COMMIT: probe-local-capability-before-bailout
Trigger: When a task requires a local-machine capability (Drive/Cloud-storage, OAuth API,
shell tool, browser session, scanner) AND the agent is about to post a menu of options OR
claim "can't do X from here."
Action: Run the local probe BEFORE composing the menu. Three concrete steps, in order:
1. `session_search(query="<tool-or-task>", limit=5)` + `skill_view(name='memory-search')`
   — surface prior sessions where this capability was used.
2. Read `~/.config/<tool>/` and `~/.bashrc` for relevant tokens, scopes, or remotes.
3. Test the capability directly (`rclone lsjson`, `terminal(command="...")`, etc.)
   with a single reversible call.
If step 1-3 surface an existing working path, EXECUTE that path — do NOT post a menu.
If steps 1-3 confirm no path exists, post ONE concrete blocker with the missing
requirement, not a 2+ option menu.
On this Mac specifically: use `rclone` for personal Drive (not `gws drive`).
`gws drive` is OAuth-bound to a Firebase service account and 404s on personal folders.
Bug-ref: Slack `${SLACK_CHANNEL_ID}` (Jeffrey 2026-08-14 afternoon, drive folder dedupe).
Companion to `pre-execution-option-bailout-guard` (sibling class — both post menus,
different layer: Verification vs Tool/Environment).
```

## The 5-Whys (agent path)

1. Why did the agent post a 4-option menu? → Verified `gws drive` returned 404, decided Drive was unreachable.
2. Why decide Drive was unreachable? → Only tested ONE Drive access path; didn't enumerate alternatives.
3. Why not enumerate? → Treated "tool X failed" as "no tools work" without checking local config.
4. Why assume no other tools? → Default mental model was "this Mac has gws and that's it."
5. **Why default to gws-and-only-gws?** → Because `gws` is the visible Google CLI in `PATH`; the agent did not probe `~/.config/` for already-configured tools (`rclone` with `gdrive:` remote was sitting right there).

## Lessons for future sessions

1. **The probe is cheap, the menu is expensive.** `ls ~/.config/rclone/` + `cat ~/.config/rclone/rclone.conf | head -10` took ~50ms. Posting a 4-option menu and waiting for a user reply took ~6 minutes of round-trip latency. Even when the probe returns nothing, you've ruled out a class of solutions without user input.

2. **`gws drive` is NOT a general-purpose Drive CLI on this machine.** It's bound to the Firebase service account. Future sessions should treat `gws drive` as a "WA project Drive" tool only. For personal Drive, use `rclone`. The wiki source at `~/llm_wiki/wiki/sources/reference-gdrive-upload-via-rclone-own-client.md` (dated 2026-08-13) is canonical; read it before reaching for `gws drive` again.

3. **The user's "every day / many times" signal is a class-promotion trigger.** When the user says "we always have trouble with X" or "you get confused on this every day," that's a signal the failure is recurring, not session-specific. Search memory for the pattern (the user gave the exact cure: `/history` `/ms`).

4. **The 9-store memory-search fan-out is the canonical probe.** It hits `~/roadmap`, `beads`, `claude memories`, `hermes sqlite`, `hermes briefings`, `hermes index`, `wiki`, `history`, `slack`. In this case it found the rclone reference in `wiki/` AND in `~/roadmap/`. The fan-out takes <2s and surfaces prior decisions that would otherwise take 6+ minutes of round-trip menus to rediscover.

5. **Sibling classes need to be distinguished, not collapsed.** `pre-execution-option-bailout` (2026-08-13) and `local-capability-not-probed-before-bailout` (this entry) look similar — both post menus. They differ in **when** to apply the cure: `pre-execution` means the executable path was already in context; `local-capability-not-probed` means the agent never checked. The catalog gets more valuable when the distinction is explicit, not less.