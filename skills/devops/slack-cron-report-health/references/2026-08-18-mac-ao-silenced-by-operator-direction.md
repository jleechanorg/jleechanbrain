# 2026-08-18 — Mac AO daemon silenced by operator direction (NOT by bug)

**Pair with:** `~/.smartclaw/skills/devops/slack-cron-report-health/SKILL.md` (Section 4a `/healthz` probe rule + new Section 4b "operator-policy exceptions: probe-but-don't-surface" + the operator-policy pitfall in the Pitfalls list).

This is the **third-generation** of the cross-machine AO reporter saga:

- **Generation 1 (PR #816, 2026-08-05):** reporter used `db mtime` as the stuck-write signal. Falsely fired "Linux AO db is 384h stale" every 30 min for a week. Reference: `references/2026-08-13-aopr-true-stuck-vs-false-stale.md`.
- **Generation 2 (PR #817, 2026-08-13):** replaced mtime with `/healthz` probe, added `linux_max_activity_h` gate for true-stuck detection. PR sat open unmerged for 5 days on reviewer rate-limit. Reference: `references/2026-08-18-clean-replay-of-merged-stuck-pr-817.md`.
- **Generation 3 (PR #828, 2026-08-18, merged today):** clean-replay of PR #817's fix onto current `origin/main`, plus the operator-policy correction — Mac AO daemon is **not** expected to run, so the would-be "Mac-DOWN" warning line is silently dropped. The probe itself (curl `/healthz` local, header `mac_daemon=up|DOWN`) stays — only the warning body is silenced.

## The operator direction (verbatim)

After the agent posted the clean-replay PR #828 with the original PR #817 design (which would have surfaced a Mac-DOWN warning when the local AO daemon was down — and on this box it IS down because the operator doesn't run it locally), the operator replied in-thread:

> lets /af this PR and then merge approved
> We shouldnt expect mac AO daemon to be up. We use /linux primarily for AO

Two things in two lines:
1. **Approve the PR**: "lets /af this PR and then merge approved." → PR #828 went from PR-OPEN to MERGED in one turn.
2. **Correct the design**: Mac AO daemon is OFF by policy. The would-be warning line is itself noise.

The agent had already started authoring the fix as if Mac-AO-down should be surfaced. The operator direction changed that mid-task — and a less attentive agent would have shipped the PR with the warning intact, citing "Mac AO is down (verified by `/healthz` probe returning connection refused)" as a real signal. But the operator told us: **that signal is not actionable, because we don't run Mac AO**.

## What the fix looked like before vs after

### Before (PR #828 first commit `ff239a4ad5`, replay of PR #817)

`format_cross_machine_block` had a `maybe_mac_down` function that emitted:

```
🚨 *Mac AO daemon is DOWN* — verify with: launchctl print gui/501/... | grep "last exit code"
```

…and the test file asserted `BLOCK != ""` when `mac_daemon_up=false`. The Mac line was the canonical signal for "the local half is broken."

### After (PR #828 second commit `cdcebb0448818a96cee1d487cc89698048946a55`)

`maybe_mac_down` returns **empty**. The header still carries `mac_daemon=up|DOWN` for situational awareness, but no warning body. The tests now assert:

- Test 6 ("MAC DAEMON DOWN -> SILENT"): `BLOCK == ""`, `mac_daemon_up=false`, no mac line, no stale warning.
- Test 7 ("MAC DAEMON DOWN + linux TRUE stuck -> only linux stale line"): `BLOCK` has no mac line; linux line is present.

The contract is: **off-policy hosts are silent; primary hosts surface actionable state**.

## Why this is a skill-update-worthy learning (not just a memory)

Memory captures "operator runs /linux as primary AO host" — but next session's agent could encounter the same Mac-DOWN warning pattern in code review, in a new reporter, in a fresh cron, and re-emit the line. Memory is per-session-recall; a pitfall in `slack-cron-report-health` is a guard at code-authoring time, every session, regardless of which reporter or host the agent touches.

The pattern that's now durable:

1. **Probe-but-don't-surface is a valid operator-policy primitive.** Section 4b in SKILL.md documents it: probe (for the header line), but do not emit a warning body. The signal exists for situational awareness, not for escalation.
2. **Don't leave would-be warnings in code with TODO comments.** If a policy exception means the warning shouldn't fire, silence it in the same commit. The line itself is the noise source; TODO comments don't help.
3. **Contract tests must encode the operator direction, not the implementation.** Test 6 and Test 7 in PR #828 explicitly assert `BLOCK == ""` when `mac_daemon_up=false` AND `linux_daemon_up=true`. If the contract test asserted `BLOCK != ""`, the operator direction would not be enforced — and a future contributor re-introducing the warning line would see green tests.
4. **Operator-direction capture rule**: when the user states a policy preference about which conditions to surface vs silence, embed it as a pitfall in the relevant skill — not just in memory. Memory says "now", pitfall says "every time."

## The exact change captured for the next agent

If a future agent encounters a similar situation — a multi-host reporter where one host is the operator-designated primary and others are explicitly off by policy — the correct default is:

- **Probe** (so the header line shows the state — useful for situational awareness when debugging).
- **Do NOT emit a warning body** for the off-policy host.
- **Update the contract tests** to assert the silence (otherwise the warning will re-appear under "tests still pass" re-introductions).
- **Embed the policy** as a pitfall in the relevant skill (not just a memory line).

This is now encoded in `~/.smartclaw/skills/devops/slack-cron-report-health/SKILL.md` Section 4b + Pitfalls list.

## What the agent did NOT do (and why that's correct)

- **Did NOT silently re-emit the warning line under "operator hasn't seen this yet"** — operator was explicit; respect the explicit direction.
- **Did NOT close the Mac probe entirely** — the header carries the state, and future diagnostic work might need it. Probe-but-don't-surface, not probe-and-remove.
- **Did NOT add a runtime config flag** (e.g. `AOPR_SILENCE_MAC_DAEMON_DOWN=true`) — operator policy is durable, not togglable. Hardcode the silence.
- **Did NOT add a `# TODO: ask operator about Mac daemon policy` comment** — the operator already answered. Comments that say "ask operator" when the answer is in the conversation are noise that the next agent will dutifully try to resolve again.
- **Did NOT close PR #817** — same reason as PR #816: the author of the original PR is a prior agent, not the current operator, and force-closing their PR violates `never-push-onto-someone-elses-pr-head`. The clean-replay pattern leaves the original open and lets the operator decide.

## Verified outcome

```text
$ git -C ${HOME}/.smartclaw show origin/main:scripts/ao-progress-reporter.sh | grep -A4 maybe_mac_down
def maybe_mac_down($root):
  # 2026-08-18: /linux is the primary AO daemon — Mac AO is not expected
  # to be running. We still probe mac_daemon_up for diagnostics in the
  # header, but we DO NOT emit a Mac-down warning. Mac-down is silently
  # downgraded to a non-actionable state. Only signal real Linux failure.
  empty;

$ bash ${HOME}/.smartclaw/tests/test_ao_progress_reporter_cross_machine.sh 2>&1 | tail -3
==== Cross-machine reporter tests: PASS=49 FAIL=0 ====
```

PR #828 is MERGED on `origin/main`, the live script is updated to `origin/main`'s SHA, the next 30-min launchd tick of `ai.smartclaw.schedule.ao-progress-reporter` will run the new logic, and the next `AO Progress Report` Slack post will silence the Mac-down case while continuing to surface the true stuck-write case on Linux.
