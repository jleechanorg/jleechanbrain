# Auth Degradation Pattern — 2026 Incidents

Incident log for the recurring "Google OAuth token dies mid-life of a daily digest cron" failure mode. Two verified occurrences in the 5 weeks leading up to the 2026-08-06 incident that motivated this skill.

## 2026-07-02 09:02 → 13:32 PDT

**Cron:** `life:daily-important-email-calendar-8am` (job_id `85a468088e16`)

**Observed:**
- 09:02 run: AUTH WORKING. Real digest posted with top 3 emails (Chase / BullionVault / Ubuntu runner still down) + AIEWF Day 4 + UA 1506 flight.
- 13:32 run (extra cron tick, possibly a manual trigger or rate-limit retry): AUTH FAILED. Agent posted a fallback line ("no important items") that hid the actual OAuth gap.
- Jeffrey noticed the suspicious empty post and asked "Investigate <thread URL>".
- Investigation: `~/.config/gog/credentials.json` missing, `gog auth status` returned `auth_preferred: none, credentials_exists: false`. **Shape 2 — token AND client secret both gone.**

**Lesson 1 (the one this skill exists to capture):** A cron that posts a fallback line without naming the auth gap actively misleads the operator. The fallback looked like "nothing happened today" when the truth was "I couldn't check Gmail/Calendar at all."

**Lesson 2:** The auth gap was not detected at 09:02 because the run that started working 30 min earlier already had the token. The gap appeared between runs. **Always re-probe at Phase 0.**

**Recovery:** Operator re-created the OAuth client at GCP + ran `setup.py --auth-url` → browser approval → `--auth-code` → `--check` returns `AUTHENTICATED`. Recovery took ~15 min.

## 2026-07-02 → 2026-08-04 (32-day green window)

The digest cron worked every day for ~5 weeks. The output log at `~/.smartclaw/cron/output/85a468088e16/` shows daily successful runs from 2026-07-03 through 2026-08-05 inclusive (per `ls -t` output during the 2026-08-06 incident). Each run produced a real digest with top-3 emails + next-24h calendar events + action-needed list.

**Lesson 3:** Auth doesn't fail on a predictable cadence. The 32-day green window between incidents is misleading — the same OAuth client config can live for weeks or die the next day. **Always re-probe at Phase 0; never trust prior run's success.**

## 2026-08-06 09:01 PDT

**Cron:** `life:daily-important-email-calendar-8am` (same job_id `85a468088e16`)

**Observed:**
- `setup.py --check` → `NOT_AUTHENTICATED: No token at ${HOME}/.smartclaw/google_token.json`
- `gog auth status` → `auth_preferred: none, credentials_exists: false` (same Shape 2 as 2026-07-02)
- Yesterday's successful run (2026-08-05 09:02:15) was still on disk at `~/.smartclaw/cron/output/85a468088e16/2026-08-05_09-02-15.md` — proving the cron works when auth works
- No `himalaya` installed, no IMAP fallback path

**Agent decision:** Posted Shape C fallback (the fallback-line + diagnostic-block + action-needed-block structure defined in the SKILL.md). Did NOT fabricate a digest. Did NOT spin into a recovery loop inside the cron.

**Why the recovery loop was avoided:** The cron has a fixed budget and the OAuth recovery requires interactive browser steps (operator must visit the auth URL, approve, paste back the code). The right move was to surface the gap in the action-needed block so the operator can do the recovery on their own clock — NOT to block the cron tick on a 5-min OAuth dance that needs human interaction.

**Hypothesis on why the gap re-appeared:** Unconfirmed. Two plausible causes:
1. **GCP OAuth client was deleted or disabled** between 2026-08-05 09:02 and 2026-08-06 09:01. This could be operator action (cleanup), a GCP-side API enablement toggle, or a project re-organization.
2. **Token refresh failed silently** and the refresh token was revoked. The `~/.config/gog/credentials.json` and `~/Library/Application Support/gogcli/credentials.json` are both missing, which is more consistent with cause (1) than with a normal refresh failure (a refresh failure would leave the token in place but revoke the refresh grant).

To confirm: the operator should check the GCP console for the OAuth client's current status. If the client still exists at https://console.cloud.google.com/apis/credentials, then a refresh-token revocation is the more likely cause (and re-running Shape 1 may recover without re-creating the client). If the client was deleted, redo Shape 2.

## Pattern across both incidents

| Dimension | 2026-07-02 | 2026-08-06 |
|---|---|---|
| Cron | `life:daily-important-email-calendar-8am` | same |
| Failure shape | OAuth token + client_secret.json both gone | same |
| Days of green before | unknown (first observed) | 32 days (07-03 → 08-04) |
| Days of green after | 32 days | (ongoing — recovery pending) |
| Operator notification | Thread reply ("investigate this thread") | Slack post in #life (from this very cron) |
| Recovery time | ~15 min | pending |

**Generalization:** This is not a single bug — it's a recurring degradation mode where the OAuth client config doesn't survive indefinitely across GCP-side changes. The skill exists to ensure that **each recurrence is detected and named in the same cron tick**, not buried as a silent fallback post that takes a separate investigation thread to surface.

## What would prevent recurrence

Three options, in order of cost vs. durability:

1. **Auth watchdog (cheap, recommended).** Add a launchd job that runs `setup.py --check` every 6h and posts a one-line alert when the token is missing. Detects the gap within 6h instead of within 24h. Pattern in `references/google-oauth-fallback-recipe.md` § Observability.

2. **Switch to himalaya IMAP for email-only digest crons.** If the digest only needs Gmail (not Calendar/Drive/Docs), a Gmail App Password is stable across GCP-side OAuth churn and survives refresh-token revocations. ~2 min to set up; eliminates the OAuth-client-config failure mode entirely. Trade-off: only email; Calendar would still need OAuth or a separate ICS feed.

3. **Move OAuth client to a service account (medium effort).** Service-account credentials are tied to a GCP project, not to interactive-user OAuth consent. A service account with domain-wide delegation would survive most GCP-side changes that kill interactive OAuth clients. Requires Workspace admin to enable DWD, which is a one-time setup.

**Default recommendation:** (1) watchdog first, (2) himalaya for email-only crons, (3) service account as a longer-term cleanup.

## References

- `~/.smartclaw/cron/output/85a468088e16/2026-07-02_13-32-47.md` — the 2026-07-02 fallback run (the one that triggered the investigation)
- `~/.smartclaw/cron/output/85a468088e16/2026-08-05_09-02-15.md` — the 2026-08-05 successful run (proves the cron works when auth works)
- Session `20260702_135832_032b8b88` — the investigation thread that identified the OAuth gap
- SKILL.md § Worked example — full Phase 0–4 trace from the 2026-08-06 incident