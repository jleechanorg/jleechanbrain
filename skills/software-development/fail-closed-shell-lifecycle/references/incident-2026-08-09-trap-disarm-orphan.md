# Incident: round-7 trap-disarm orphan on PR jleechanorg/claude-commands#356

**Date**: 2026-08-09
**Branch**: feat/browser-command-and-skill-from-user-scope-20260809
**Commits**: ef5d5168f (round-6, committed with two real defects) → 391e20a65 (round-7, fix)

## What shipped in round 6

The canonical recipe in both `.claude/commands/browser.md` and `.claude/skills/browser-control/SKILL.md` ended with:

```bash
cleanup_creds
trap - EXIT INT TERM HUP
```

The `/er` reviewer (round 6, delivered concurrently with round 8) flagged it: a signal arriving between the last cookie write and the disarm line leaves the trap empty, and the credential file orphans on disk.

The disarm was dead code anyway. The EXIT trap fires `cleanup_creds` on normal exit, the function uses `rm -f` which is idempotent, and the explicit `cleanup_creds; trap -` line at the end is the same as the trap firing — except the explicit call + disarm leaves a window where a late signal can orphan.

## How it survived the round-6 review-iteration

Three sources of /er feedback said PASS across rounds 4, 6, 8, and 10 of the iteration. The defect only came back via a separate `/advice` round that arrived after the round-8 PASS verdict. The lesson:

> A PASS verdict from /er or /advice does not mean "no defects remain". It means "no defects the reviewer noticed". The contract test file MUST grow with every reviewer-flagged defect so the next iteration's PASS verdicts cover the same ground.

## The actual fix (round-7 commit 391e20a65)

Three changes:

1. Removed `cleanup_creds` explicit call from the end of the recipe (the EXIT trap IS the cleanup).
2. Removed the `trap - EXIT INT TERM HUP` disarm line.
3. Updated the inline comment to explain why (rm -f is idempotent; trap firing on normal exit is identical to an explicit cleanup call).

Plus three regression tests that would have caught it:

- `BrowserCommandContractTest::test_credential_reuse_safeguards_present` — asserts `"trap -"` not in browser.md canonical recipe.
- `BrowserSkillContractTest::test_fail_closed_lifecycle_present` — asserts `"trap -"` not in skill canonical recipe.
- (Secret branch already had the equivalent assertion.)

## End-to-end verification

Verified with a late-script SIGINT:

```bash
$ kill -INT $$        # injected at the very end of the recipe
$ echo "rc=$?"
rc=130
$ ls /tmp/td/ | grep browserclaw-
(no matches)
```

The trap is still armed at the very end of the script. SIGINT arrives → trap fires → both files removed → script exits 130.

## Lessons for future credential recipes

1. **The disarm line at the end of a credential recipe is a code smell.** Delete it on sight.
2. **The contract test should include a "find any `trap -` line" check** as a baseline, not just a positive-list of the words that should appear.
3. **Multi-round /er + /advice iteration does not guarantee coverage.** Every reviewer-flagged defect needs an explicit test that reproduces the failure.
4. **The skill-level lesson**: `mktemp`/chmod/trap is universal — every shell wrapper that touches credentials needs the same invariant. That's why `fail-closed-shell-lifecycle` exists as a class-level skill rather than a session-specific postmortem.
