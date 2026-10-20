---
name: post-change-claim-verification
version: 0.1.0
author: claude/MiniMax-M3
license: MIT
description: "Verify runtime loaded the change before claiming live."
when_to_use: "After any config, SOUL.md COMMIT, skill, or deployment change. Triggers on 'is it live', 'did it take effect'."
tags:
  - workflow
  - deploy
  - verification
  - proof-before-claim
  - runtime-vs-disk
metadata:
  hermes:
    related_skills:
      - hermes-deploy-pipeline
      - harness-postmortem
      - agent-autonomy-failure-classes
arguments:
  - change_type
  - target_path
argument-hint: "<change_type: config_yaml|skill|soul_commit|deployment> [target_path]"
context: inline
---

# Post-Change Claim Verification — "Is it actually live?"

## When to Use

Use this skill **before any reply that claims a config / skill / SOUL.md COMMIT / deployment change is live or working.** Trigger phrases include:

- *"is it live"*, *"is it deployed"*, *"did the change take effect"*, *"does it work now"*
- *"config shipped"*, *"COMMIT landed"*, *"the fix is in"*, *"the buttons will disappear"*
- Any completion claim following an edit to `~/.smartclaw/config.yaml`, a SOUL.md `## COMMIT:` block, a skill patch, or a `deploy.sh` invocation.

**Skip only when:** the change is purely textual (a doc edit, a comment, a roadmap log) with no runtime impact — runtime-vs-disk delta is N/A.

**The bug class this skill prevents.** An agent commits a config change, SOUL.md COMMIT, skill patch, or deployment, then replies "the fix is live" / "the buttons will disappear" / "config shipped" — but the **running process** (gateway, daemon, service) is still holding the **old** state because (a) the process reads its config at startup and doesn't hot-reload, (b) the staging tree is updated but the prod runtime tree is a separate path/symlink, (c) the COMMIT block landed in `~/.smartclaw/workspace/SOUL.md` but the running gateway loads from `~/.smartclaw_prod/workspace/SOUL.md`, or (d) the deploy script reported failure but stages silently succeeded.

The agent's claim is **factually wrong** in this case — the change is on disk but not in the running process — and the user finds out in the next thread when the buttons reappear, the model is still the old one, or the new COMMIT never fires. This breaks trust far more than a slow fix would, because the user acted on the "live" claim (restarted their workflow, told a teammate, scheduled a downstream action) and now has to debug a regression that doesn't exist in the commit log.

**This skill's job.** Force the agent to run a **runtime-vs-disk delta check** before claiming "live." Cheap (~3 commands, ~2s), covers the 4 main drift classes, and produces a verifiable end-state declaration the user can audit.

## The 4 Drift Classes

| # | Class | Symptom | Detection |
|---|---|---|---|
| **D1 — Config-not-hot-reloaded** | Gateway reads `config.yaml` at startup but does NOT watch for changes; PID predates config mtime → new keys ignored until restart | Buttons reappear after a `disabled_toolsets: [clarify]` commit; model stays the old one after a `model.default` flip |
| **D2 — Staging tree ≠ prod runtime tree** | `~/.smartclaw/` is git-tracked staging; `~/.smartclaw_prod/` is the runtime source; symlink in `[single-dir]` mode means they match, but in `[split-dir]` mode or before a deploy, prod is stale | New skill shows in `~/.smartclaw/skills/<X>/SKILL.md` but `~/.smartclaw_prod/skills/<X>/SKILL.md` doesn't exist yet |
| **D3 — SOUL.md COMMIT in wrong tree** | `~/.smartclaw/workspace/SOUL.md` is git-tracked; `~/.smartclaw_prod/workspace/SOUL.md` is the runtime-loaded copy; edits to staging don't auto-propagate | COMMIT block present in `grep` of staging, absent in prod; trigger phrase never fires |
| **D4 — Deploy script silent-fail** | `deploy.sh` reports "DEPLOY FAILED" but Stage 4.5/4.6 sync actually succeeded silently under `[single-dir]` mode (verified 2026-07-05 babysit-cron-leak post-mortem); false-negative exit code | `deploy.sh` exit ≠ 0 but file content IS the new version |

## The Runtime-vs-Disk Delta Check (canonical recipe)

Run these 4 commands IN ORDER before claiming a config / skill / SOUL.md / deployment change is live:

```bash
# 1. Identify the running process + its start time
PID=$(pgrep -f "hermes gateway run" | head -1)
ps -p "$PID" -o pid,etime,comm 2>/dev/null

# 2. Compare process start time vs the file's mtime
#    If file mtime > process etime-anchor → process started BEFORE the change → NOT loaded
stat -f "%Sm %N" ${HOME}/.smartclaw_prod/workspace/SOUL.md

# 3. Confirm the change is in BOTH staging AND prod trees (or whichever the runtime reads)
grep -c "<change-anchor>" ${HOME}/.smartclaw/workspace/SOUL.md ${HOME}/.smartclaw_prod/workspace/SOUL.md
# Both counts must be >0. If staging > 0 but prod == 0 → D3 (SOUL.md in wrong tree).

# 4. For skill / config changes: confirm the live process actually loaded the new key
curl -sf http://127.0.0.1:8643/health 2>/dev/null | python3 -m json.tool  # gateway only
```

**Output shape:** a 3-line verdict that the agent pastes in the reply BEFORE claiming "live":

```
PID 12044 etime 02-19:23:12 (started Sun10PM)
SOUL.md mtime Aug 19 18:04:38 (file)
→ file mtime > process etime → running gateway has NOT loaded the change
→ action: `hermes gateway restart` from a separate terminal required
```

## Per-Class Action Recipes

### D1 — Config-not-hot-reloaded (most common)

**Trigger:** `config.yaml` edit (disabled_toolsets, model.*, agent.max_turns, channels.*, etc.).

**Detection:**
```bash
PID=$(pgrep -f "hermes gateway run" | head -1)
CFG_MTIME=$(stat -f "%m" ${HOME}/.smartclaw/config.yaml)
PID_START=$(ps -p "$PID" -o lstart= | date -j -f "%a %b %d %T %Y" "+%s" 2>/dev/null)
[ "$CFG_MTIME" -gt "$PID_START" ] && echo "D1: gateway PID $PID predates config mtime → restart required"
```

**Action:** DO NOT claim "live." Reply with the verbatim reminder:
> *"Config change committed at <sha> but the running gateway PID <pid> started <etime> ago, before the change — config.yaml doesn't hot-reload. Run `hermes gateway restart` in a separate terminal to apply."*

**Why:** The harness refuses to restart the gateway from inside the gateway process (SIGTERM would propagate and kill the command itself). The restart MUST come from outside the gateway — the agent's job is to detect the drift and report it, not to attempt the restart.

**Bug-ref:** Slack `C0AH3RY3DK6/p1787185077` (Jeffrey *"stop asking me these questions i thought we fixed this in teh config"*) — agent committed `disabled_toolsets: [clarify]` at `e1438edce0` but the running gateway PID 12044 (started Sun10PM) had not loaded the change; restart reminder was buried in a later message and the user came back frustrated. SOUL.md `## COMMIT: config-disable-requires-gateway-restart-reminder` (added 2026-08-19, commit 3a7b7154fa on `jleechanorg/jleechanbrain`) encodes this as a trigger-based rule.

### D2 — Staging tree ≠ prod runtime tree

**Trigger:** Skill patch, script edit, SOUL.md edit, config.yaml edit.

**Detection:**
```bash
# For skill files:
diff -q ~/.smartclaw/skills/<X>/SKILL.md ~/.smartclaw_prod/skills/<X>/SKILL.md
# For config:
diff -q ~/.smartclaw/config.yaml ~/.smartclaw_prod/config.yaml
# For SOUL.md:
diff -q ~/.smartclaw/workspace/SOUL.md ~/.smartclaw_prod/workspace/SOUL.md
```

**Action:** If diff returns non-empty AND the file is in `[single-dir]` symlink mode (i.e. `~/.smartclaw_prod` is a symlink to `~/.smartclaw`), the diff should be empty — investigate the symlink (`ls -la ~/.smartclaw_prod`). If `[split-dir]` mode (separate trees), the canonical fix is `cp -p <file> ~/.smartclaw_prod/<file>` to deploy, then verify with the same diff command.

**Bug-ref:** Slack `${SLACK_CHANNEL_ID}/p1783124135813349` (2026-07-03 dropped-thread watcher silent-fail) — staging had the fix, prod didn't, deploy.sh reported success but Stage 4.5 file-sync silently no-op'd because `[single-dir]` mode skips the rsync. The agent assumed "deployed" without running the diff. Companion: `hermes-deploy-pipeline` → "Config File Editing" section + `references/staging-dirty-surgical-sync.md`.

### D3 — SOUL.md COMMIT in wrong tree

**Trigger:** New SOUL.md `## COMMIT:` block added.

**Detection:**
```bash
grep -c "^## COMMIT: <name>$" ~/.smartclaw/workspace/SOUL.md ~/.smartclaw_prod/workspace/SOUL.md
# Both counts must be ≥1.
```

**Action:** If staging ≥ 1 but prod == 0 → commit landed in the git-tracked tree but NOT in the runtime-loaded tree. The fix is `cp -p ~/.smartclaw/workspace/SOUL.md ~/.smartclaw_prod/workspace/SOUL.md` (the staging tree is the git-tracked source of truth; prod is the runtime-loaded mirror).

**Why the runtime tree matters:** The running gateway loads `~/.smartclaw_prod/workspace/SOUL.md` (per `hermes-deploy-pipeline` → "SOUL.md COMMIT workflow"). Edits to `~/.smartclaw/workspace/SOUL.md` (staging) do NOT auto-propagate without an explicit `cp` or a deploy.sh Stage 4.5 sync that successfully completes.

**Companion:** `hermes-deploy-pipeline` → "⚠️ Slash command AND RESOLVER.md AND SOUL.md `## COMMIT:` are three separate wiring points" — covers the wiring-points pattern but does NOT auto-verify both trees match post-edit.

### D4 — Deploy script silent-fail

**Trigger:** `~/.smartclaw/scripts/deploy.sh` exited non-zero.

**Detection:** Look at Stage 4.5/4.6 output even on non-zero exit:
```bash
~/.smartclaw/scripts/deploy.sh 2>&1 | tee /tmp/deploy.log
echo "exit: $?"
# Even on non-zero exit, grep the log for the success markers
grep -E "Stage 4.5|Stage 4.6" /tmp/deploy.log
```

**Action:** If `Stage 4.5` AND `Stage 4.6` BOTH show "synced" / "ok" markers AND the file is in `[single-dir]` mode (symlink) → the deploy ACTUALLY succeeded, the non-zero exit is from a downstream stage (port canary, drift warning). Do NOT retry the deploy — verify the runtime-vs-disk delta and claim "live" with the stage-by-stage log as proof.

**Bug-ref:** 2026-07-05 babysit-cron-leak post-mortem (`b2ad00770d` on origin/main). `deploy.sh` failed at `port:UNBOUND` health check while Stage 4.5/4.6 sync succeeded silently. The previous Phase 3 step 5 in `harness-postmortem` instructed the failing invocation as canonical — replaced by the `staging-dirty-surgical-sync` recipe (see `hermes-deploy-pipeline/references/staging-dirty-surgical-sync.md`).

## End-State Reply Contract

Per `finish-the-job` + `proof-before-claim` SOUL.md COMMITs, every post-change reply MUST contain:

1. **The delta-check verdict** (3-line paste from the recipe above).
2. **The action the user must take** (if D1: `hermes gateway restart`; if D2/D3: `cp -p <file> ~/.smartclaw_prod/<file>`; if D4: verify Stage 4.5/4.6 logs and re-run delta check).
3. **Honest "live vs not-live" declaration** — never say "the fix is live" unless the runtime-vs-disk delta is zero.

**Forbidden phrases (per `proof-before-claim`):**
- "Should be live now"
- "The change should take effect"
- "Restart and it'll work" (without verifying restart actually happened)
- "Deployed" (without Stage 4.5/4.6 log + delta check)

**Allowed replacement pattern:**
> *"Committed <sha> at <mtime>; running gateway PID <pid> started <etime> ago → gateway has NOT loaded the change. Action: run `hermes gateway restart` in a separate terminal. Once restarted, the buttons disappear and SOUL.md `## COMMIT: <name>` triggers will fire on the next session-init."*

## Anti-Patterns

- ❌ **"I committed it, so it's deployed"** — git commit ≠ runtime load. Commit lands on `origin/main`; deploy moves it to the prod tree; the running process picks it up only on next startup. Three separate steps, three separate verifications.
- � **"deploy.sh exit 0, so it's live"** — exit 0 only proves the script reached the end; it does NOT prove every stage succeeded. The port canary can flake, the drift warnings are non-blocking, and `[single-dir]` mode skips the rsync entirely (correct behavior, not a bug, but the script reports no useful signal).
- ❌ **"Diff says staging and prod are different, but the change is 'in flight'"** — "in flight" is a figment. If `diff` returns non-zero, the change is NOT in prod. Fix is `cp -p`, not "wait."
- ❌ **"The change is small, surely the running gateway picks it up"** — the gateway does NOT watch any config file. It reads once at startup. The change must be committed → deployed → process restarted → AND the restart must happen from outside the gateway process (no SIGTERM from inside).

## Companion Skills

- `hermes-deploy-pipeline` — staging/prod deploy mechanics, `--skip-pull --skip-restart` flag combo, manual `cp` patterns.
- `harness-postmortem` — the `/meta` protocol that surfaced this skill (2026-08-19, 6-failure thread at `C0AH3RY3DK6/p1787187781`); SOUL.md `## COMMIT: config-disable-requires-gateway-restart-reminder` (commit 3a7b7154fa) is the trigger-based rule that this skill operationalizes.
- `agent-autonomy-failure-classes` — catalog of autonomy violations including `fabricated-proof` (claiming success without verification) and `capable-didn't-execute` (skipping the verification step).

## Changelog

- 0.1.0 (2026-08-19): Initial authoring from the 2026-08-19 /meta harness-postmortem on Slack thread `C0AH3RY3DK6/p1787187781` (6-failure analysis of the living-world-tick design convo). Trigger: agent committed `disabled_toolsets: [clarify]` at `e1438edce0`, claimed the disable was live, but the running gateway PID 12044 (started 2d 19h ago) had not loaded the change because `config.yaml` doesn't hot-reload. The user came back the next day with buttons reappearing and the agent had to apologize. The fix lands at SOUL.md `## COMMIT: config-disable-requires-gateway-restart-reminder` (commit 3a7b7154fa on `jleechanorg/jleechanbrain`); this skill operationalizes the runtime-vs-disk delta check that the COMMIT block references.
