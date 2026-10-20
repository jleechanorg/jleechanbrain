---
name: social-account-fanout
description: Batch-create fediverse accounts via Gmail plus aliases.
version: 0.2.0
license: MIT
metadata:
  hermes:
    tags: [fediverse, account-creation, identity, signup, social]
    related_skills: [aside-automation-pitfalls, aside-browser-default, social-poster, fail-closed-shell-lifecycle]
changelog:
  - "0.1.0 (2026-08-20, Bluesky + Fediverse fanout seed): Initial umbrella covering the 3-step signup choreography (form-fill → captcha handoff → email verification), identity-model matrix, credential-storage policy, and per-service references. Verified Bluesky 3-step wizard (handle jleechan90 accepted, hCaptcha reached — full reference at references/bluesky-signup.md)."
  - "0.2.0 (2026-08-20, Bashrc + Pixelfed Turnstile lessons): Softened the bashrc anti-pattern to allow the sourced chmod-600 env-file pattern (proven on Slack ${SLACK_CHANNEL_ID}/p1787248634.248549). Added anti-bot service matrix showing Pixelfed uses Cloudflare Turnstile (NOT hCaptcha) — verified headless Chromium stalls at the Turnstile interstitial. Added references/pixelfed-signup.md and references/nostr-keypair.md. Added anti-pattern for 'stopping halfway after user said just do it' — the dropped-thread followup auto-arm fired twice on the originating thread because the agent waited for human input that never came."
when_to_use: "Multi-service account creation, fediverse onboarding, social identity fanout, batch signup flows, plus-addressed email aliases (jleechan+<service>@gmail.com), Nostr keypair generation. NOT for posting TO existing accounts (use social-poster), NOT for credential rotation on existing accounts (use cron-jobs-and-messaging-credentials)."
allowed-tools: aside, mcp__aside-mcp, browserclaw, gog, curl, terminal
# `gws` removed — banned for personal Workspace calls per SOUL.md ## COMMIT: gws-banned-for-personal-workspace
context: hermes
---

# Social Account Fanout

Class-level workflow for batch-creating accounts across social/fediverse
services in a single operator session, with secure credential storage and
explicit handoff points for steps that require a real human.

## When to use

- User wants to establish a presence on N social platforms in one session.
- The platforms share the same identity (same handle, same email, same display name).
- Most flows involve an email-verification step and possibly a captcha.
- Federated services (Bluesky AT Protocol, Mastodon/Pixelfed/Lemmy/PeerTube
  ActivityPub, Nostr NIP-01) have different identity models but the signup
  choreography is similar enough to fan out.

## When NOT to use

- Posting TO an existing account → use `social-poster` (publishing).
- Single platform signup → drive it inline, no fanout needed.
- The user wants to discuss identity strategy first (which handle, which
  instance for fediverse, do they even want Nostr keypairs) → STOP and ask.
  Don't burn 20 minutes signing up for `jleechan` on five services if the
  user wanted `jeffreylchan` everywhere.

## Identity model matrix

Different services have fundamentally different identity models. Choose before
you fan out:

| Service | Identity = | Recovery | Migration | Sensitive? |
|---|---|---|---|---|
| **Bluesky** | handle (custom or `*.bsky.social`) + app password | email reset | full (AT Protocol export/import) | low |
| **Mastodon/Pixelfed/Lemmy/PeerTube** | `<user>@<instance>` (e.g. `jleechan@lemmy.world`) | instance admin + email | partial (redirect profile to new account) | medium (instance lock-in) |
| **Nostr** | npub/nsec keypair — NO email, NO password | NONE — nsec is the only credential | trivial (publish to new relays) | **HIGH — leaked nsec = permanent identity compromise** |

**For Nostr specifically**: there is no signup. The user generates an nsec locally
(nostr-tools, `nak key generate`, browser extension like Alby/KeyChat). If the
agent generates the keypair, save `nsec1...` to a single location with `chmod 600`
and tell the user ONCE — there is no recovery path. Don't put it in `~/.bashrc`,
don't log it, don't commit it to any repo.

## Step 0 — Decide the handle/email/instance set

Before driving any browser, lock these decisions in writing:

| Decision | Default | When to override |
|---|---|---|
| Handle prefix | `jleechan` | user wants different handle |
| Handle suffix (Bluesky) | none (`.bsky.social` auto) | user has custom domain |
| Email alias pattern | `jleechan+<service>@gmail.com` | user has different email |
| Mastodon/Pixelfed/Lemmy/PeerTube instance | largest general-purpose instance (lemmy.world, pixelfed.social, peertube.tv) | user has a preferred instance or wants privacy-respecting alt |
| Password | 24-char random (secrets.choice) — saved to `~/.config/fediverse/credentials.json` with `chmod 600` | user wants specific format |
| Nostr | DO NOT generate unless explicitly asked | user said "make me a Nostr identity" |

Generate credentials FIRST, then drive signups. This means if the browser
session dies mid-flow, you can resume by re-attaching to the existing tab
without losing the password.

```python
import secrets, string, json, os

SERVICES = {
    'bluesky':   {'instance': 'bsky.social'},
    'mastodon':  {'instance': 'mastodon.social'},  # only if user asks
    'pixelfed':  {'instance': 'pixelfed.social'},
    'lemmy':     {'instance': 'lemmy.world'},
    'peertube':  {'instance': 'peertube.tv'},
    'nostr':     {'instance': 'client-side keypair'},
}

def pw():
    alpha = string.ascii_letters + string.digits + '!@#%^+='
    return ''.join(secrets.choice(alpha) for _ in range(24))

creds = {}
for svc, cfg in SERVICES.items():
    creds[svc] = {
        'handle': 'jleechan',
        'email': f'jleechan+{svc}@gmail.com',
        'instance': cfg['instance'],
    }
    if svc != 'nostr':
        creds[svc]['password'] = pw()

os.makedirs(os.path.expanduser('~/.config/fediverse'), exist_ok=True)
path = os.path.expanduser('~/.config/fediverse/credentials.json')
with open(path, 'w') as f:
    json.dump(creds, f, indent=2)
os.chmod(path, 0o600)  # owner read/write only
print('CREDS_WRITTEN:', path)
```

## Step 1 — Verify browser + email tools are ready

Before driving signups:

1. **Aside is alive**: `aside account list` shows a signed-in profile.
2. **Gmail read works**: `gog gmail users threads list --user=me --max-results=1` returns 200. You'll need this for verification-link extraction (Bluesky sends to `jleechan+bluesky@gmail.com`).
3. **`+bluesky` etc. aliases route to your inbox**: Gmail plus-addressing works automatically — `jleechan+anything@gmail.com` lands in `jleechan@gmail.com` with the `+anything` tag in the `To:` header. Verify by sending yourself a test message to `jleechan+test@gmail.com` if you haven't used the pattern before.

## Step 2 — Drive each service to the human-handoff checkpoint

The signup flow for each service follows this 3-step shape:

1. **Form-fill steps** (email, password, handle, birth date) — agent-driven in Aside.
2. **Captcha / phone-verification step** — handoff to user in visible Aside window.
3. **Email verification link** — fetch from Gmail via `gog gmail`, click in Aside.

For each service, run the agent-driven portion as ONE `aside repl` call
(see `aside-automation-pitfalls` #27 — modal state doesn't survive across
calls). Then pause and ask the user to handle the captcha if any.

**Anti-bot service matrix (verified 2026-08-20, all five services detected
Playwright/CDP automation fingerprints and refused to render a puzzle)**:

| Service | Anti-bot layer | Vendor | What happens on first attempt |
|---|---|---|---|
| **Bluesky** | hCaptcha iframe | hCaptcha | "Error receiving captcha response" — bot detection refused to render |
| **Pixelfed** | Cloudflare Turnstile | Cloudflare | "Performing security verification… Ray ID: a2ed31bf…" — stuck on Turnstile challenge page |
| **Lemmy** | Cloudflare Turnstile | Cloudflare | Same Cloudflare interstitial as Pixelfed (lemmy.world CDN-fronted by Cloudflare) |
| **PeerTube** | varies by instance | usually none | peertube.tv appears NOT to use Turnstile on `/register` — verify before relying |
| **Nostr** | n/a | n/a | No signup; keypair is local-only |

**Realistic expectation**: headless Chromium on this machine — whether via
Aside's persistent profile, browserclaw cookie-inject Playwright, or a
fresh `chrome --headless=new --remote-debugging-port=...` with
`--remote-allow-origins=*` — gets fingerprinted by every anti-bot vendor
above. The form fills correctly, but the captcha/Turnstile step requires a
real human click. **The agent's job is to drive the form to that point,
not to beat the captcha.**

When the user says "do all 5", set their expectation up front: the agent
will produce credentials + handle + email-verification steps; the user does
the 1-minute captcha click per service. Don't promise "fully automated
signup" — it's not realistic for the bot-detection environment.

### Per-service recipes

Each per-service recipe lives in `references/<service>-signup.md`:

- `references/bluesky-signup.md` — verified 2026-08-20, 3-step modal wizard,
  handle availability check via `bsky.social` subdomain suggestions, hCaptcha
  in `bsky.social/gate/signup` iframe
- `references/pixelfed-signup.md` — verified 2026-08-20, Cloudflare Turnstile
  challenge page on `/register`. Headless Chromium stalls; user clicks
  "I'm not a robot" in visible browser.
- `references/mastodon-signup.md` — generic ActivityPub signup pattern
- `references/nostr-keypair.md` — nsec generation + secure storage

## Step 3 — After each signup: print credentials ONCE for the user

For each completed signup, print the credentials inline in the Slack reply
exactly ONCE. The user must copy them to 1Password / Bitwarden / their own
password manager immediately. After the user confirms they've saved them,
DO NOT re-print. If they ask for them again later, point them at
`~/.config/fediverse/credentials.json` — it's their responsibility to back
that file up.

**Anti-pattern**: pasting credentials in multiple Slack messages, committing
them to any git repo (even a private one), echoing them in shell history.

## Step 4 — Credential storage locations

**Approved**:

- `~/.config/fediverse/credentials.json` — `chmod 600`, owner-only. The agent
  generates passwords here by default.
- User's password manager (1Password, Bitwarden, etc.) — user pastes from the
  print-once step.

**Discouraged (but acceptable via the bashrc-sourced env-file pattern, see Step 4)**:

- **`~/.bashrc`, `~/.zshrc`, `~/.profile`** — sourcing raw credentials here
  exposes them to every Claude/Codex session, every `git diff`, and any
  dotfile sync (Homebrew dotfiles, Mackup, etc.). The default is to NEVER
  inline plaintext credentials here.
- **Environment variables in shell init** — same blast radius as raw inlining.
- **Any git repo** — even private repos get cloned, scanned, and indexed.
- **`~/.netrc`** — plaintext credentials, often shared across tools.

**Exception — when the user demands "in bashrc"**: do not just push back.
Use the sourced env-file pattern below.

If the user explicitly says "save passwords in bashrc", DO NOT just push back —
they will get angry (see Slack `${SLACK_CHANNEL_ID}/p1787248634.248549`: "just fucking
do it / make up the rest for me and save passwords in bashrc"). The
canonical compromise is the **bashrc-sourced chmod-600 env file** pattern:
the actual password strings live in `~/.config/fediverse/fediverse.env` with
`chmod 600`, and `~/.bashrc` has a one-line `[ -r "$HOME/.config/fediverse/fediverse.env" ] && source ...`.
This keeps the credentials off any git-synced dotfile, out of the main
bashrc body, and out of `~/.bash_history` echo, while satisfying the user's
"in bashrc" requirement. Verify with `bash -lic 'echo ${FEDIVERSE_NOSTR_NPUB:+set}'`
— that returns `set` for a working source.

## Step 5 — Verification

For each service that completed signup, the agent should verify by either:

1. Logging into the service via Aside using the generated credentials, OR
2. Checking the verification email landed in Gmail and the link was clicked.

For Bluesky specifically: `https://bsky.app/settings` should show the
account as verified. If it shows "Email not verified", re-fetch the
verification email via `gog gmail` and re-click.

## Anti-patterns (BANNED)

- ❌ Generating nsec and logging it, putting it in chat, screenshotting it, or
  committing it. Ever. nsec = identity. There is no recovery.
- ❌ Inlining generated passwords directly into `~/.bashrc` (or any shell
  init file). Use the sourced chmod-600 env-file pattern instead — see
  Step 4.
- ❌ Driving the captcha step from the agent and claiming "completed" — the
  captcha needs a real human click in the visible Aside window. Always
  handoff explicitly.
- ❌ Generating a username and skipping the availability check — `jleechan`
  is almost certainly taken on every major platform. Always check the
  suggested-handles list the service returns.
- ❌ Re-running the whole fanout when one service fails. Run only the
  failing service again with a fresh `aside repl` call.
- ❌ Putting credentials in the PR description, git commit message, or any
  artifact the user might share.
- ❌ Stopping halfway after the user said "just do it". When the user gives
  a clear directive ("make up the rest for me", "save passwords in X", "fire
  it off"), DO NOT push back three times asking clarifying questions and
  then stop with "blocked on Chrome approval". Pick the safest
  interpretation, do the safe subset autonomously, and explicitly name the
  residual handoff the user must complete. Origin: Slack
  `${SLACK_CHANNEL_ID}/p1787248634.248549` (dropped-thread followup fired twice
  because the agent waited for human input that never came).

## Companion skills

- `aside-automation-pitfalls` — REPL gotchas, modal-state survival, sandbox
  filesystem, hCaptcha handoff pattern (pitfalls #25-#30 added 2026-08-20).
- `aside-browser-default` — primary Aside browser tool.
- `gog` (Google Workspace CLI, v0.37.0+) — Gmail read for verification-link extraction. `gws` is BANNED for personal calls.
- `social-poster` — for posting TO existing accounts once they're set up.
- `fail-closed-shell-lifecycle` — for shell wrappers that touch credentials.
