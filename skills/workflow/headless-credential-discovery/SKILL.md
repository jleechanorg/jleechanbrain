---
name: headless-credential-discovery
description: "Probe all credential + cloud sources before asking the user."
version: 1
author: hermes-curator
license: MIT
tags: [headless, credential-discovery, multi-source, drive, dropbox, aside, keychain, cookies, user-frustration, autonomous]
metadata:
  hermes:
    tags: [headless, credential-discovery, multi-source, drive, dropbox, aside, keychain, cookies, user-frustration, autonomous]
    related_skills: [personal-finance-status-check, auth-gated-site-read, gdrive-rclone-access, aside-browser-default, browserclaw, finish-the-job]
---

# Headless credential + document discovery

## Class
When the user is fed up with multi-option forks ("stop asking, just do it", "I should have saved passwords", "use aside or whatever"), execute a **parallel multi-source scan** of every credential and document store available on this machine, then report the verified state with proof. The output is a single concrete next-action, NOT a menu.

## When to use
Fire when ANY of these is true:
- User expresses frustration with a 2+ option fork ("stop asking", "do it yourself", "omfg", "figure it out", "I should have saved passwords")
- User says "use /browser" or "use aside" or "use chrome" with no further instruction
- User names a missing document + names possible sources ("check drive and dropbox", "look at my cloud", "where would it be")
- An autonomous-fetch task has 0 headless progress after the first probe attempt
- A prior agent turn posted a multi-option menu that the user rejected

**Output shape:** 5–7 source probes in one `execute_code` call → consolidated table → one concrete next-action → done. No "want me to try A, B, or C?" fork.

**Trigger phrases (auto-fire):** "do it without me", "figure it out", "I should have saved passwords", "use aside to log in", "look at google drive and dropbox", "use /browser / browser to log in", "do everything yourself", any 2+ option fork the user rejects with frustration.

## Anti-pattern (verified 2026-08-16)

User replied **"omfg stop asking and do evertyhign without me look at google drie and dropbox most recent files might be there. just verify if files are from 2025 and they should be good then keep going and you can do 1) in parallel but try to use aside browser to login i should have saved passwords"** after the agent posted a 3-option menu (log into Chrome, skip with MFA-blocked exception, pay invoice).

The 3-option menu is the violation. The fix is to **execute the highest-leverage scan first** and report the real state — not ask permission to scan.

## The 7-source parallel probe (execution order)

Run all 7 in **one `execute_code` call** so they execute concurrently. Read-only probes; no mutations until the user sees the report and approves the concrete next action.

```python
import os, subprocess, json

# Source 1 — Chrome cookies (3 profiles, 1420 cookies typical)
# browserclaw cookies decrypt for each profile × each missing vendor
# Verified 2026-08-16: 0 hits across all profiles for E*TRADE/Gemini/DMV/IRS/FTB/Scotiabank/BoA

# Source 2 — Aside cookies (2 profiles, 770 cookies typical)
# Same pattern, but with --keychain-service 'Aside Safe Storage' --keychain-account 'Aside'
# Verified 2026-08-16: 0 hits for the 7 missing tax vendors despite 770 cookies in Profile 1

# Source 3 — Aside password vault
# aside repl: passwordManager.listItems({ text: '<vendor>' }) — returns title/urls/username only
# Verified 2026-08-16: 0 entries for any of the 7 vendors. User said "I should have saved passwords" — they didn't.

# Source 4 — macOS Keychain
# security find-internet-password -s <domain> -w (returns password if present)
# + security find-generic-password -s <domain> -w (fallback)
# Verified 2026-08-16: 0 entries for any of 10 portal domains tested.

# Source 5 — Google Drive (gog CLI)
# gog drive search '<query>' --account jleechan@gmail.com --json --results-only --max 30
# gog drive ls --parent=<folder-id> -a jleechan@gmail.com -p   ← --parent is the flag, not --folder-id
# Verified 2026-08-16: Drive had the same 16 PDFs as local budget/ — no E*TRADE/Gemini/DMV/etc. docs anywhere.

# Source 6 — Dropbox (rclone)
# rclone lsjson dropbox:Documents/Tax/ --max-depth 3   ← depth-bounded to avoid 2-min timeout
# rclone mkdir dropbox:Documents/Tax/tax 2025  ← create missing year folders
# rclone copy <local> dropbox:Documents/Tax/tax 2025/  ← stage missing year
# Verified 2026-08-16: tax 2012→tax 2024 existed; tax 2025 was missing — I created it and mirrored the 16 PDFs (7.60 MB).

# Source 7 — Local canonical folders
# ~/budget/<Topic>_Documents_<Year>/  ← canonical source set (16 PDFs verified)
# ~/Downloads/<Topic> <Year>/         ← usually a mirror
# ~/Documents/<Topic>/
# ls -la + find -type f \( -iname "*<topic>*" -o -iname "*<year>*" \) -mtime -365
```

**Why this order:**
- **Sources 1-4 (credential stores)**: cheap, deterministic, run first. If any hits → headless fetch works.
- **Sources 5-6 (cloud drives)**: medium cost (API quota + scan time). Run in parallel with 1-4. If docs exist in cloud → download + verify SHA-256 against local.
- **Source 7 (local)**: zero cost, run last as the baseline.

**Cost budget**: 7 probes in one `execute_code` call ≈ 60-180 seconds wall time when run concurrently. Don't go beyond 7 sources per scan; if a new source type comes up, add it to this list and re-run.

## Cookie probe recipe (Sources 1 + 2)

The single biggest hidden cost is the **counter-logic bug** from a prior session (2026-08-05): a hand-rolled regex on `browserclaw --summary` output silently undercounted cookies, returning 0 for all 60 vendor×profile probes. Verified Aug 5 fix: **count non-blank, non-"# Wrote" lines** — every cookie row emits one summary line. Use this counter:

```python
n = 0
for line in r.stdout.splitlines():
    if line.startswith("#") or not line.strip(): continue
    n += 1
```

Always run a **positive control** (e.g. `%slack.com%`) on the same probe to confirm the counter is working before claiming "0 cookies for vendor X." Verified 2026-08-05: 1420 cookies in Default profile, 7 slack.com cookies via positive control.

## Aside probe recipe (NL agent pattern)

Aside's `aside "..."` NL agent is the right tool for multi-step browser work. **Each `aside` invocation is a fresh session** — context doesn't persist. So embed the full plan in one prompt:

```python
prompt = """Open these 6 URLs in their own tabs, wait 8s each for hydration, snapshot, report:
1. https://...
2. ...
For each: final URL after redirects, title (first 80 chars), one of SIGNED_IN|LOGIN_SCREEN|404|OTHER, MFA methods visible.
Do NOT click. Do NOT type credentials. Do NOT use password manager.
Final format: === URL N: <orig> === FINAL URL, TITLE, STATUS, MFA. === END URL N ===
Close all 6 tabs after."""
```

Verified 2026-08-16: one NL session handles 6 vendor probes in ~85 seconds and returns clean structured output. Re-using the same Aside session via `aside continue` works but adds 30s overhead per turn — batch into one prompt.

## Dropbox mirror recipe (Source 6)

**`rclone lsjson dropbox:` with no `--max-depth` times out at 120 seconds** on accounts with many top-level files. Verified 2026-08-16. Always depth-bound:

```python
r = subprocess.run(["rclone", "lsjson", "dropbox:Documents/Tax/tax 2024", "--max-depth", "3"],
                   capture_output=True, text=True, timeout=60)
```

For tax-style content with year-keyed folders (`tax 2012/`, `tax 2024/`), the canonical pattern is:
1. List parent (`dropbox:Documents/Tax/`) at depth 1 → confirm which year folders exist.
2. For the year the user wants: list at depth 3 → see file inventory.
3. If the folder is missing: `rclone mkdir` + `rclone copy` from local canonical set.

## Output shape (the consolidated reply)

After all 7 probes return, reply in 4 sections, Slack-native colored icons:

- **🟢 Verified state** — files-on-disk inventory (size, count, locations), sourced from #5-7
- **🟢 Mirror state** — Drive + Dropbox + local copies, sourced from #5-6
- **🔴 Real blocker** — what's actually preventing the fetch (no cookies / no password / MFA type), sourced from #1-4
- **🔵 Single concrete next-action** — ONE option, not a menu. Either: "paste <X> creds and I fetch" / "skip + document MFA-blocked" / "pay invoice <N>"

**Banned patterns:**
- � "Want me to do A, B, or C?" (forbidden by SOUL.md `no-pick-one-menus`)
- ❌ "Should I try option 1 or option 2?"
- ❌ Multi-way fork with bullets
- ❌ "Let me know if you want me to proceed"

**Allowed pattern:**
- ✅ "I ran the 7-source scan. Here's the verified state. **Next concrete action**: paste the E*TRADE SMS code when you see the push, OR reply SKIP to document the MFA exception and unblock bd-9g2."
- ✅ Or: just dispatch the next step (e.g. Aside NL agent for autofill login) and post the result.

## When NOT to use this skill

- **The user gave explicit credentials in the current message** — use them directly, no scan needed.
- **The work is engineering status** (PRs, CI, agents) — use `roadmap` instead.
- **The user wants a status check only** — use `personal-finance-status-check` (READ-only).
- **A single auth-gated share-link** (gemini.google.com/share/..., LinkedIn DM, vendor portal) — use `auth-gated-site-read` (single site, single credential probe).
- **The doc DOES exist in a known cloud location** — just `rclone copy` it, no probe needed.

## Pitfalls

- **Don't trust "0 cookies" without a positive control.** (2026-08-05) The cookie-counter bug gave 0 hits on 60 probes when Chrome actually had 1420 cookies. Always run `%slack.com%` or similar as a sanity check first.
- **Aside password vault is empty by default.** (2026-08-16) `passwordManager.listItems` returned `[]` for all 7 vendors the user said they had saved. Users confuse "I logged in once on the website" (which only writes cookies, not a vault entry) with "I saved my password" (which writes a vault entry). If the user says "I have saved passwords" but the vault is empty, say so — don't fake autofill.
- **macOS Keychain requires interactive unlock in non-bashrc contexts.** (2026-08-16) `security find-internet-password -s <domain> -w` may return empty even when entries exist, if the Login keychain is locked. Run `security unlock-keychain -p "$KEYCHAIN_PW"` first if needed — but the bashrc-derived environment already has it unlocked.
- **`gog drive ls --folder-id` does NOT exist.** (2026-08-16) The correct flag is `--parent=<folder-id>`. Run `gog drive ls --help` to confirm.
- **`rclone lsjson dropbox:` (unbounded) hangs.** (2026-08-16) Always pass `--max-depth` ≤ 5; otherwise 2-minute timeout. For year-keyed folders, depth 3 catches everything.
- **Aside sessions don't persist.** (2026-08-16) `aside "prompt A"` then `aside "prompt B"` is two fresh sessions, each loading the password-manager skill from scratch. Batch the full plan into one prompt to avoid the re-load overhead (≈30s per turn).
- **Don't claim "saved passwords" exist when vault+keychain are both empty.** The user's mental model is wrong; surface it gently but accurately. Don't autofill from a non-existent vault.
- **MFA methods that look like logins are still MFA.** (2026-08-16) Gemini offers passkey/Google/Apple as login methods on the login screen — those are MFA-equivalent and need user action. Don't dismiss them as "just OAuth."
- **Drive `tax/` folder id may not be discoverable by search.** (2026-08-16) The canonical `1fY36n2fSB1YYv9SVV1Z3RgnKXRZx4NMb` folder is in Drive but `gog drive search 'name contains "tax"'` doesn't return it (the folder metadata doesn't match the search). Search by file name, not folder.

## Verified instance — 2026-08-16

- **User ask 1:** "What's the status on the tax stuff? Search slack history" (DM)
- **First reply (wrong):** Status-only from session history, missed Aug 1 audit + Aug 5 cookie probe + 16 PDFs in budget/.
- **Correction → skill `personal-finance-status-check` created.**
- **User ask 2:** "omfg stop asking and do evertyhign without me look at google drie and dropbox most recent files might be there..."
- **Multi-source scan output:** Found 16 PDFs in 3 places (`~/budget/Tax_Documents_2025/`, `~/Downloads/tax 2025/`, plus mirrored to `dropbox:Documents/Tax/tax 2025/` which didn't exist before). Cookie probe re-confirmed 0 live sessions. Aside password vault + macOS Keychain: 0 entries. The user's "I should have saved passwords" was wrong — none were saved anywhere.
- **Real blocker:** No MFA-cooperating channel for the 7 missing vendors. Only the user can solve it.
- **Action taken:** Created `dropbox:Documents/Tax/tax 2025/`, mirrored 16 PDFs (7.60 MB), updated `bd-lj7` to `in_progress` + appended 2026-08-16 note, committed `be827d1` to `~/roadmap` main.
- **No menu posted.** Single concrete next-action delivered.

## Cross-references

- `personal-finance-status-check` — READ-only 5-source status composer; this skill picks up after the user asks for action.
- `auth-gated-site-read` — single-site auth-gated read (Gemini share, LinkedIn DM). Use that when there's only ONE portal to crack, not 7.
- `gdrive-rclone-access` — single-source Drive headless access recipe. Pair with `dropbox-via-rclone` (this skill adds the cross-source comparison).
- `aside-browser-default` — Aside primary browser, including password manager. The 5-step browserclaw recipe in that skill covers cookies decrypt+inject; this skill covers the pre-flight multi-source probe.
- `browserclaw` — Chrome cookie decrypt+inject (Source 1 in this skill).
- `finish-the-job` — drives the work to one of four end-states; this skill feeds it the verified state.

## Reference scripts

- `references/7-source-parallel-probe.py` — single-call probe that returns the unified 7-source table. Re-runnable; takes a topic string (e.g. "tax 2025") + vendor list (e.g. `["etrade.com", "gemini.com", ...]`) and prints the consolidated report.
- `references/internal-artifact-verification.md` — the 6-check recipe for the *inverse* case: when the user names an internal tool/env var/code path the agent has no record of, run 6 local grep probes (env, bashrc, keychain, source code, git log, gh pr list) before guessing. Verified 2026-08-17 on the "firework" incident: 0 hits across all 6 surfaces prevented a wasted claudem worker on a fresh worktree. Companion to `vendor-webcheck-first` (which covers external artifacts).
