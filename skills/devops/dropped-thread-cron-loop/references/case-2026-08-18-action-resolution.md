# Case: action_resolution warning thread — cron fires on completed work

**Date:** 2026-08-18
**Thread:** `${SLACK_CHANNEL_ID}/p1787111938.251339`
**Topic:** "Missing action_resolution field — issue #9021 pattern, wa-llm-output-emission-false-green-watchdog skill applies. Need you to confirm: still broken in latest prod deploy? Run `/repro` on `mvp-site-app-dev` to lock the regression signature. Then drive `/af` to /ready the PR"

## What happened

The user filed this as a fresh "this is still broken" thread in #all-jleechan-ai
at 21:03 PT. By the time I picked it up at 21:30 PT:

- [PR #9058](https://github.com/jleechanorg/worldarchitect.ai/pull/9058) `fix(prompt): re-land REQUIRED RESPONSE SCHEMA section (rev-1acx5, fixes #9057 / #9021)` was already MERGED at 2026-08-19T01:17:59Z (commit `df86fabd6d7e`)
- `git -C ~/projects/worldarchitect.ai merge-base --is-ancestor df86fabd origin/main` → exit 0 (fix IS on main)
- Dev revision `mvp-site-app-dev-04502-cmc` was already on commit `88756c1` (which includes `df86fabd` as an ancestor), deployed at 2026-08-19T04:12:15Z
- Stable revision `mvp-site-app-stable-00182-hfw` was still on `a9e552a` from 2026-08-16 — predates the fix; that's why the user's prod surface still saw the warning

So the work was DONE on dev. The user's `/repro` ask required an
authenticated browser session against `mvp-site-app-dev` which Aside
does not have — the dev page returned the SPA shell without a real
login, and there was no public repro path.

## What I should have done first

**Run `gh pr list --search "action_resolution" --json state,mergedAt` BEFORE
replying.** The first action of any "this is still broken" / "is X fixed
yet" / "drive /af to /ready" ask should be: check the canonical PR
state. If the PR is merged, the conversation immediately becomes
"verify the deploy, surface the residual gap (stable), ack done" —
not "let me investigate from scratch."

## What I did

1. Verified the PR state, ancestor-of-main, dev revision, stable
   revision via `gh pr view`, `git merge-base`, `gcloud run revisions list`
2. Tried `/repro` — `curl -sSL https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/game/Mz4s5zy30noDnSgScPJH` returned the SPA shell (35KB, no actual campaign content rendered server-side)
3. Stopped, marked the thread `gave_up=true` via the jq command in the
   parent SKILL.md's "Recommended agent-side action" section
4. Posted the consolidated ack (Honest status block) — surfaced the
   stable-redeploy blocker as the actual operator action

## What the user was actually upset about

The dropped-thread watcher fired at 04:50:47Z and I had no in-thread
reply yet. The user had already pushed back twice:
- "this is still broken we need a gh issue and PR for it" (the original
  thread message — based on the Aug 18 02:11 prod-stable warning that
  predated the fix landing on dev)
- "dod you actually go through my slack reminders?" (asking for
  confirmation I was doing real work vs summarizing)

The right shape of the response: **acknowledge what was already done,
surface what's NOT done, and offer a single concrete next action**
(operator says `REDEPLOY STABLE`, I dispatch a worker). Don't pretend
the work was incomplete when it wasn't.

## Durable lesson

When the dropped-thread cron fires on a thread whose work is already
done in a prior turn, do NOT just keep replying — use the
`gave_up=true` state-file mark (recipe in parent SKILL.md). And in the
next reply, LEAD with the state ("PR #9058 MERGED on origin/main +
deployed to dev at 04:12Z") rather than re-investigating from scratch.

## Anti-pattern I almost fell into

Almost proposed "let me re-investigate and run a real /repro on
dev." That would have wasted 5+ minutes on a browser session I
couldn't actually authenticate, and the right answer was "I can't
repro from here, but the fix IS deployed to dev — your prod-stable
is the gap." State-first, not re-derivation-first.
