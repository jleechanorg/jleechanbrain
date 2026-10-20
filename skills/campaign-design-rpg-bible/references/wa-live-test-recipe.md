# WorldArchitect.AI Live Test Campaign Verification — 6-step Recipe

When the user asks: "test creation using /browser for <email> / yttesting" or "verify the bible works in the live WA wizard", use this recipe. Confirmed working 2026-08-22 on the Quiet War bible.

## Why this exists

The custom-campaign wizard accepts `description` (the bible) and a structured `god_mode_data` dict; the AI DM, after parsing the prompt, does **NOT** execute follow-up fetch calls against external links. Self-contained bibles are required, but the *test campaign* still has to land in the right user's UID, populate the right game-state, and render the right narrative under the right campaign id. This recipe verifies all four.

## The 6 steps

### Step 1 — fresh worktree

```bash
cd ~/repos/jleechanorg/worldarchitect.ai
git fetch origin
git worktree add ~/repos/jleechanorg/worldarchitect.ai/_wt_<branch-key> \
  -b feat/<branch-key> origin/main
```

Use `origin/main`, not a stale branch. The worktree name should match the test scope (`_wt_campaign_test`, `_wt_pr9219_fix`, etc.).

### Step 2 — boot TESTING_AUTH_BYPASS in background

```bash
WT=~/repos/jleechanorg/worldarchitect.ai/_wt_<branch-key>
env TESTING_AUTH_BYPASS=true "$WT/local.sh" > /tmp/wa-test.log 2>&1
```

Always `background=true` with `notify_on_complete=false` for silent boot. WA dev servers run for hours — they're not bounded tasks. Detect port from the boot log (`grep -oE 'http://localhost:[0-9]+'`). After 25-30s the server is ready and responding on `?test_mode=true&test_user_id=...` URL.

### Step 3 — payload shape

The Custom Campaign wizard front-end (`new-campaign-form`) submits a `POST /api/campaigns` with this shape:

```json
{
  "title": "<TEST title>",
  "character": "<string summary>",
  "setting": "<string setting>",
  "description": "<the full self-contained bible>",
  "selected_prompts": ["custom"],
  "custom_options": ["mechanics"],
  "campaign_wizard_mode": "wizard",
  "god_mode_data": {
    "character": {"name": "...", "class": "...", "race": "...", "stats": {"STR":8,...}},
    "setting": "...",
    "description": "<the bible>"
  }
}
```

Pitfalls:
- `character` MUST be a string at the top level, not a dict — the backend converter strips it. Put the dict under `god_mode_data.character`.
- `description` is the FULL bible (multi-KB). The wizard has no per-field length limit on this one.

### Step 4 — POST via TESTING_AUTH_BYPASS

```bash
PORT=$(grep -oE 'http://localhost:[0-9]+' /tmp/wa-test.log | head -1 | grep -oE '[0-9]+')
EMAIL=jleechantest@gmail.com
curl -m 240 -sS -X POST "http://127.0.0.1:$PORT/api/campaigns" \
  -H "X-Test-Bypass-Auth: true" -H "X-Test-User-ID: $EMAIL" -H "X-Test-User-Email: $EMAIL" \
  -H "Content-Type: application/json" --data @/tmp/qw-payload.json
```

Expect a 30-90s response. Returns `{campaign_id, success}`. Save the ID for verification.

### Step 5 — verify game state

```bash
curl -m 30 -sS "http://127.0.0.1:$PORT/api/campaigns/$CID" \
  -H "X-Test-Bypass-Auth: true" -H "X-Test-User-ID: $EMAIL" -H "X-Test-User-Email: $EMAIL"
```

Expected fields (Quiet War verified values):
- `campaign.title` ✅
- `custom_campaign_state.attribute_system: "D&D"` ✅
- `custom_campaign_state.aura: "active"` ✅
- `custom_campaign_state.campaign_wizard_active: true`, `campaign_wizard_mode: "wizard"`, `campaign_wizard_round: 1` ✅
- `custom_campaign_state.god_mode.character.{name, class, race, stats}` ✅ (this is the canonical PC sheet)
- `custom_campaign_state.character_creation_stage: "pending"` (initial state — becomes `"complete"` after first interaction)

### Step 6 — drive first interaction + screenshot

The character's full stat panel (HP/AC/Spell DC/Proficiency) renders in the `Character design phase` view before the narrative starts. To capture it via `/browser`:

1. POST one interaction with `mode: "character"`, `choice_index: 0` (Imperial Path A). 30-60s response.
2. After interaction, `character_creation_stage: "complete"` and the god-mode stats are visible.
3. Drive Aside with explicit absolute path to `.aside/u/0/sessions/<filename>.png` — the default of `/tmp/...` is silently redirected by Aside (it writes to `<session_dir>/tmp/` regardless).

```bash
aside --account u0 "Open http://127.0.0.1:$PORT/campaign/$CID?test_mode=true&test_user_id=$EMAIL in your existing browser session. Wait 5s, click the campaign title row to enter gameplay, wait 6s for the in-campaign page to render, take a screenshot to ${HOME}/.aside/u/0/sessions/qw-gameplay.png. Report: (a) URL ended up on, (b) campaign title, (c) full ability score line, (d) Vitals & Combat line, (e) inventory items, (f) Strategic Choices section, (g) character creation phase notice, (h) first scene narrative text."
```

Aside uploads land at `~/.aside/u/0/sessions/<session_id>/tmp/` AND accept absolute paths to `${HOME}/.aside/u/0/sessions/*.png`.

## Cleanup

```bash
pkill -f "_wt_<branch-key>/local.sh" 2>/dev/null
pkill -f "_wt_<branch-key>/.*main.py" 2>/dev/null
sleep 2
# If port still bound:
PID=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null)
kill -9 $PID
cd ~/repos/jleechanorg/worldarchitect.ai
git worktree remove _wt_<branch-key> --force
git branch -D feat/<branch-key>
```

## Anti-patterns

- ❌ Booting `./local.sh` outside a clean worktree — your changes in `_wt_pr9219` from another session leak into this test.
- ❌ Forgetting `unset GOG_KEYRING_BACKEND` between gog calls. (Less relevant for WA tests, but matters for parallel Drive doc work.)
- ❌ Using `kill -9 21193` with a bare PID — the kill propagates to the parent shell, drops the daemon process, and you lose the worktree shell session that was waiting for `notify_on_complete`. Use `pkill -f "<unique-worktree-path>/local.sh"` instead.
- ❌ Trying to skip the worktree step and boot `./local.sh` from the main checkout — `--virtual-missing-warning` errors out because the main checkout has dirty git state from sibling cron runs.

## Verified traces

- 2026-08-22 (08-22): Quiet War bible under `jleechantest@gmail.com`, two test campaigns created:
  - `hCiaemzNMT6jijoX9OTi` (first run, full inventory + spells shown)
  - `pGfqzk2mjPcn8Zsnag9U` (second run after SIGTERM-cleaned re-boot, narrative + 4 Strategic Choices shown post turn 1)
- `/browser` captured 2 screenshots: stats panel (783 KB) + in-campaign scene (856 KB).
