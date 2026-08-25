# Hermes Deploy Pipeline — Actual State (2026-06-23)

This reference documents the **actual state** of the deploy pipeline
as observed on 2026-06-23, updating the 2026-06-09 baseline. The umbrella
`hermes-deploy-pipeline` SKILL.md documents the **intended state**. They
differ in three ways as of this writing.

## Difference from 2026-06-09 baseline

| Aspect | 2026-06-09 (old) | 2026-06-23 (current) |
|---|---|---|
| `~/.smartclaw/scripts/deploy.sh` | Did not exist | **EXISTS** (verified) |
| `~/.smartclaw_prod/scripts/deploy.sh` | Did not exist | **EXISTS** (verified) |
| SOUL.md runtime path | `~/.openclaw/SOUL.md` | `~/.smartclaw_prod/workspace/SOUL.md` |
| Staging tree (`~/.smartclaw/`) | Incomplete relative to prod | Generally complete for the active skill set |
| `git remote` of `~/.smartclaw/` | n/a (not a git repo in some prior configs) | `hermes-agent` (primary) + `origin` (jleechanorg/jleechanbrain fork) |

**Verified 2026-06-23, jleechanorg/jleechanbrain PR [#682](https://github.com/jleechanorg/jleechanbrain/pull/682):**

```bash
$ ls -la ~/.smartclaw/scripts/deploy.sh ~/.smartclaw_prod/scripts/deploy.sh
-rwxr-xr-x  ... ~/.smartclaw/scripts/deploy.sh
-rwxr-xr-x  ... ~/.smartclaw_prod/scripts/deploy.sh

$ grep -c '## COMMIT: push-pr-donot-stop-halfway' \
        ~/.smartclaw/workspace/SOUL.md \
        ~/.smartclaw_prod/workspace/SOUL.md
~/.smartclaw/workspace/SOUL.md:1
~/.smartclaw_prod/workspace/SOUL.md:1
```

## What `deploy.sh` actually does

The umbrella's "deploy via `scripts/deploy.sh`" rule is correct in
intent, but the script's actual content is a stage-2 / stage-3 sequence
(pull + restart + canary). It does **not** do the staging → prod
file mirroring. The 4-stage `POLICY_FILES=(CLAUDE.md SOUL.md TOOLS.md
HEARTBEAT.md)` list only covers 4 files; skills/scripts/launchd
configurations are NOT mirrored by `deploy.sh` (this is the documented
"POLICY_FILES gap" pitfall in the umbrella skill).

**Concretely today:** `deploy.sh` does NOT:
- `cp` `~/.smartclaw/skills/<name>/` to `~/.smartclaw_prod/skills/<name>/`
- `cp` `~/.smartclaw/scripts/` to `~/.smartclaw_prod/scripts/`
- `cp` `~/.smartclaw/launchd/*.plist.template` to prod (templates are
  source-of-truth; the deployed plist in `~/Library/LaunchAgents/`
  is regenerated from the template separately)
- Sync `~/.smartclaw/config.yaml` to `~/.smartclaw_prod/config.yaml` (this
  one is also documented in the umbrella as "do manually")

## So how does staging → prod sync actually work today (2026-06-23)?

**Mostly manual `cp`**, with `deploy.sh` handling the gateway restart
and canary. The two trees are independent directories; `~/.smartclaw_prod/`
is NOT a git repository (verified `git status` returns "fatal: not a
git repository" inside `~/.smartclaw_prod/`). The actual procedure for
shipping a new skill or script:

1. **Edit/write in `~/.smartclaw/`** (staging, git-tracked)
2. **Manually `cp` to `~/.smartclaw_prod/`** for the files the running
   agent reads (skills, scripts, launchd templates). SOUL.md is in
   `workspace/SOUL.md` (symlinked / copied between both trees).
3. **For launchd plists:** `cp` the template is not enough; the
   deployed plist at `~/Library/LaunchAgents/<label>.plist` is the
   real runtime artifact. After `cp`-ing the template to prod, the
   `~/Library/LaunchAgents/` plist is the authoritative copy. To
   force re-exec: `launchctl kickstart -kp gui/$(id -u)/<label>`.
4. **For gateway-affecting changes (config.yaml, certain skills):**
   `~/.smartclaw/scripts/deploy.sh` for the git pull + restart + canary.
   Otherwise no restart is needed (skills + SOUL.md are re-read at
   session-init).
5. **Commit + push staging** to keep git history:
   `cd ~/.smartclaw && git add -A && git commit -m '...' && git push
   origin <branch>`. PRs go through `jleechanorg/jleechanbrain` (or
   the project's own remote), not direct-to-main.

## Worked example: 2026-06-23 push-pr-donot-stop-halfway deploy

When shipping the new `skills/workflow/push-pr-donot-stop-halfway/`
SKILL.md + tests + the corresponding `## COMMIT:` block in
`workspace/SOUL.md`, the actual sequence was:

1. **Wrote everything to `~/.smartclaw/` (staging)** per the umbrella's
   "staging first" rule
2. **Created worktree `fix/soul-push-pr-donot-stop-halfway`** from
   `origin/main`, copied the 5 files in (skill, tests, policy,
   SOUL.md edit, RESOLVER.md entry)
3. **Pushed to origin:** commit `b118304c82` on
   `fix/soul-push-pr-donot-stop-halfway`
4. **Opened PR [#682](https://github.com/jleechanorg/jleechanbrain/pull/682)**
5. **Mirrored SOUL.md to prod manually** (per the "SOUL.md COMMIT
   workflow" in the umbrella: both trees must be updated in the same
   turn, no `deploy.sh` auto-fire for SOUL.md changes). The new
   `## COMMIT:` block lives in BOTH `~/.smartclaw/workspace/SOUL.md`
   AND `~/.smartclaw_prod/workspace/SOUL.md`.
6. **Green Gate ran, hit CodeRabbit rate limit.** Did NOT merge.
   The skill and the SOUL.md COMMIT are in prod (live) but the PR is
   still open awaiting user merge approval.

## Staging/prod drift observed on 2026-06-23

Specific drift noted during the #682 bring-to-green loop:

- `~/.smartclaw/workspace/SOUL.md` (59100b) has a
  `## COMMIT: never-hallucinate-no-new-content` block (a safety rule
  that prevents the agent from fabricating "your message contains no
  new content" responses when context is empty).
- `~/.smartclaw_prod/workspace/SOUL.md` (55418b) does NOT have that
  block.

**Diagnosis:** The block was added to staging in a prior session,
but the manual `cp` to prod step was not done (or the prior session
aborted before the cp). The running prod gateway is currently active
WITHOUT this safety rule loaded at session-init.

**Why this is dangerous:** this is a SAFETY-CRITICAL block (the
agent might hallucinate "no new content" responses if it is missing).
The deploy-pipeline rule says "Do NOT auto-run `scripts/deploy.sh`
after writing a SOUL.md COMMIT — the user typically wants a chance to
review the rule before the gateway restart." But that rule applies
to NEW writes; for an EXISTING COMMIT that staging has but prod
doesn't, the right move is to surface the drift to the user and ask
explicitly whether to sync. The agent should NOT auto-`cp` safety
COMMITs without user approval, even when the rule is already in
staging.

**Workaround (for any agent reading this later):** when shipping a
SOUL.md `## COMMIT:` block, always run the `cp` step
`cp -p ~/.smartclaw/workspace/SOUL.md ~/.smartclaw_prod/workspace/SOUL.md`
in the same turn as the staging write. Verify with
`grep -n 'C0B...' ~/.smartclaw_prod/SOUL.md ~/.smartclaw/workspace/SOUL.md`
that the channel ID / rule text matches in both trees. The umbrella
already requires this for new writes; the failure mode is when a
prior session skipped it.

## The deploy-pipeline contract — what to actually do today (2026-06-23)

1. **Decide which tree the running agent reads from.** Today: prod
   (`~/.smartclaw_prod/`). SOUL.md is loaded from
   `~/.smartclaw_prod/workspace/SOUL.md`.
2. **Write to staging first** (`~/.smartclaw/`) per the umbrella's
   documented rule.
3. **Manually `cp` to prod** for skills, scripts, SOUL.md. Use
   `cp -p` to preserve mtimes for diff comparison.
4. **For launchd plists:** update the `~/Library/LaunchAgents/`
   plist (or the template, then re-render). `launchctl kickstart -kp
   gui/$(id -u)/<label>` to force re-exec.
5. **For gateway-restart-needed changes:** `~/.smartclaw/scripts/deploy.sh`
   (or `--skip-push` if already pushed to origin).
6. **Commit + push staging** to keep git history.
7. **Note in the PR / commit message** that prod sync was manual, so
   future agents don't expect automation that doesn't exist.

## When in doubt: the 3-question staging/prod sanity check

Before claiming a change is "deployed":

1. `ls -la ~/.smartclaw_prod/<path>/<file>` — does the file exist in prod?
2. `diff -q ~/.smartclaw/<path>/<file> ~/.smartclaw_prod/<path>/<file>` —
   do staging and prod agree?
3. `launchctl list | grep <label>` — is the launchd job loaded?

If any answer is "no," the change is not actually live. Fix before
claiming "deployed."
