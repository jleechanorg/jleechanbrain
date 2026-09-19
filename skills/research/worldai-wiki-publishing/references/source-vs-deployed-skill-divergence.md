# Source-of-truth vs `~/.smartclaw/skills/<name>/` divergence

## TL;DR

If a skill referenced from this umbrella (`download-campaign`, future skills exported via `/exportcommands`, etc.) has both:

1. A **source-of-truth** copy in a separate git repo (e.g. `jleechanorg/claude-commands:hermes/skills/<name>/`), AND
2. A **deployed** copy at `~/.smartclaw/skills/<name>/` that a launchd job actually executes

…then they CAN diverge. **A PR fix to source does NOT fix the launchd job until the deployed copy is also patched in place.** A merge to `origin/main` does NOT propagate to `~/.smartclaw/skills/`.

## Verified worked example — 2026-08-20

- **Launchd job:** `ai.jleechan.wiki-campaign-daily-ingest` (runs daily at 09:00 local).
- **What it runs:** `~/.smartclaw/skills/download-campaign/scripts/download_campaign.py` (NOT the source-of-truth copy).
- **Symptom (today, 09:00):** processed 157 real WA users, errored all 157 with `'NoneType' object has no attribute 'collection'`.
- **Source-of-truth state:** `jleechanorg/claude-commands:hermes/skills/download-campaign/scripts/download_campaign.py` on `origin/main` commit `7219a94a9` (14120 bytes) — `init_firebase()` returns `firestore.client()` OUTSIDE the `if not firebase_admin._apps:` block (correct).
- **Deployed state:** `~/.smartclaw/skills/download-campaign/scripts/download_campaign.py` (16330 bytes) — `init_firebase()` returns `firestore.client()` INSIDE the `if not firebase_admin._apps:` block (BUGGY — falls through with implicit `None` when `_apps` is already populated).
- **Source main checkout state (separate from origin/main):** `${HOME}/claude-commands/hermes/skills/download-campaign/scripts/download_campaign.py` (9356 bytes) — even older copy missing `--mode all-users` mode entirely.
- **Three different byte sizes, three different copies, in one session.** This is the smoking gun.

## Fix sequence that landed the green run

1. **TDD test on `origin/main` branch** (`${HOME}/wt-wiki-ingest-fix`, branch `fix/wiki-ingest-init-firebase` based on `origin/main`): added `TestInitFirebaseReturnValue` (2 cases). RED proof: revert the docstring's contract assertion + run test → fails (function returns `None`). GREEN proof: re-apply → passes. PR [#357](https://github.com/jleechanorg/claude-commands/pull/357) carries the test + docstring guardrail.
2. **Patch deployed file in place** (`~/.smartclaw/skills/download-campaign/scripts/download_campaign.py`): moved `return firestore.client()` OUTSIDE the `if not firebase_admin._apps:` block. Source-of-truth PR can follow; the deployed patch is what the launchd job actually reads.
3. **Manual rerun:** `bash ~/.smartclaw/scripts/wiki-campaign-daily-ingest.sh`. Result: 162 users scanned, 1 downloaded (`Caroline's day` from `2012percyc2001@gmail.com`), 16 skipped, 1 transient error (`jleechan@gmail.com` hit a different gRPC bug class — separate issue). Commit `1b4f4cc34` pushed to `jleechanorg/llm-wiki:main`.
4. **Tomorrow's 09:00 launchd run will pick up the patched deployed file automatically** — no further action needed until the PR-merge propagation gap bites again (see "Open gap" below).

## 3-byte-size diagnostic (run this whenever a launchd job fails with a bug the source has already fixed)

```bash
echo '=== deployed (launchd runs this) ==='
stat -f %z "$HOME/.smartclaw/skills/<name>/scripts/<file>.py"

echo '=== prod (gateway loads for skill_manage) ==='
stat -f %z "$HOME/.smartclaw_prod/skills/<name>/scripts/<file>.py"

echo '=== source main checkout ==='
stat -f %z ${HOME}/claude-commands/hermes/skills/<name>/scripts/<file>.py

echo '=== source origin/main HEAD ==='
cd ${HOME}/claude-commands && git log -1 --format='%h %ad %s' --date=short -- hermes/skills/<name>/scripts/<file>.py
```

If all four sizes differ, the launchd bug is in the deployed file even though source has the fix. **Patch deployed in place; PR-merge to source can follow.**

If deployed and prod differ, the gateway's running skill_manage cache is stale — `cp -p ~/.smartclaw/skills/<name>/scripts/<file>.py ~/.smartclaw_prod/skills/<name>/scripts/<file>.py` then verify `diff -q` returns 0.

## Open gap (as of 2026-08-20)

The deployed file has features that the source-of-truth `origin/main` does NOT have:

- Chained-cause logging in `_process_candidates` (surfaces real OAuth causes, not just SSL frames — see `gcp-sa-auth-from-script` Trap 3)
- The 3-attempt retry wrapper around `firebase_admin.initialize_app()`
- The env-pin comment block before `init_firebase()`

When the operator next runs `/exportcommands` (or a fresh worktree + `cp` re-export), these features will be **overwritten** by the source's leaner version UNLESS the source catches up first. The PR #357 docstring is the right pattern for the regression guard, but a follow-up commit should port the chained-cause logging + retry wrapper back into the source so the next re-export preserves them.

## Rule of thumb (encoded in `worldai-wiki-publishing` Pitfall #25)

> **After ANY PR fix to a skill that lives in both `jleechanorg/claude-commands` and `~/.smartclaw/skills/`, ALWAYS also patch the deployed `~/.smartclaw/skills/<name>/scripts/<file>` in the same turn if a launchd job runs against it.**

A merge to `origin/main` does NOT propagate to `~/.smartclaw/`. The deploy pipeline (`scripts/deploy.sh` Stage 4.6) syncs `~/.smartclaw/skills/` → `~/.smartclaw_prod/skills/` but does NOT pull from `jleechanorg/claude-commands` — the source → staging direction requires either (a) the operator manually re-exporting via `/exportcommands`, or (b) a fresh worktree + `cp` of the changed file from source to BOTH `~/.smartclaw/skills/<name>/` AND `~/.smartclaw_prod/skills/<name>/`.

## Companion bug class — `init_firebase()` None return

When `firebase_admin._apps` is pre-populated by another module at import time (e.g. `clock_skew_credentials.apply_clock_skew_patch()`), placing `return firestore.client()` INSIDE `if not firebase_admin._apps:` makes the function fall through with implicit `None` on the no-init path. Downstream: `db.collection(...)` → `'NoneType' object has no attribute 'collection'`. Fix: always `return firestore.client()` OUTSIDE the `if` block. RED-test recipe:

```python
import firebase_admin
firebase_admin._apps = {"[DEFAULT]": object()}  # simulate pre-init
import download_campaign as dc
sentinel = object()
dc.firestore.client = lambda: sentinel
result = dc.init_firebase()
assert result is sentinel, "init_firebase returned None — bug class"
```

Buggy code: `result is None`, AssertionError. Patched code: `result is sentinel`, OK. Verified both directions 2026-08-20.