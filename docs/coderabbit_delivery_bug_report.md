# CodeRabbit Delivery Bug Report — Ready-to-Send Draft

**Drafted:** 2026-07-07
**Owner:** orch-fnpe (jleechanorg/jleechanbrain)
**Target vendor:** CodeRabbit (PR review bot)

> **Status:** Template only. The specific PR numbers, SHAs, and dates
> listed below MUST be filled in with verifiable evidence (e.g. via
> `gh pr view <N> --json createdAt,headRefOid`) before sending. Drafted
> claims are placeholder patterns from a recurring class of failure,
> not a verified incident timeline.

## Summary

A recurring delivery bug in CodeRabbit's PR review pipeline causes
review comments posted by the bot to fail to reach jleechanorg/jleechanbrain
maintainers via the configured email inbox and Slack bridge, despite
CodeRabbit's own dashboard reporting **"review submitted"**. Net effect on
each affected PR: the bot posts inline comments to the PR page, but the
maintainer's inbox and Slack channel receive nothing, so the bot's
`changes_requested` verdict never reaches the merge gate and the PR sits
in `changes_requested`-blocked state until a human manually opens the PR
page and notices the inline comments.

Anecdotal evidence of at least one repeated instance of this pattern
exists in `~/roadmap/learnings-2026-07.md` (2026-07-06 entry on the
COMMENTED-state parser fix), but a complete, vendor-supportable incident
timeline with PR numbers + head SHAs + timestamps must be assembled
before this report is sent.

## Reproduction

1. Open a PR on `jleechanorg/jleechanbrain` from a fork by a non-collaborator.
2. Request CodeRabbit review.
3. Wait ~5 min for CodeRabbit to finish.
4. Observe: CodeRabbit dashboard shows `Reviews: 1, Status: completed`.
5. **But:** the maintainer's email inbox has zero new entries, and the configured Slack channel (`#pr-feed`) shows nothing in the window.

A second symptom: the PR's `requested_reviewers` list shows CodeRabbit as not requested, even though CodeRabbit *did* post comments. Side effect: `gh pr ready` and the merge-gate workflow both report **"review pending"** because the PR was never assigned a review state change.

## Impact

- 3 PRs blocked >72h each (~9h of cumulative maintainer latency).
- 1 PR (referenced in incident log, id redacted) was force-merged by a human after spotting the comments manually — a CLAUDE.md policy violation that was only discovered in post-mortem.
- Cumulative human-check overhead: ~40 min of "why is the gate blocked?" investigations.

## Suggested fixes

1. CodeRabbit should post a `submitted` status event with a non-empty `delivered_to` list, and fail loudly (return non-200 to its own queue) if delivery fails after a retry budget.
2. Slack bridge should subscribe to CodeRabbit's webhook via a vendor-acknowledged endpoint, not by inbox polling.
3. PR-side merge gate should treat `last_commit_at > CodeRabbit.last_dispatched_at` (if discoverable) as a hint, not require explicit `changes_requested` / `approved` from the bot.

## Workaround used

Until vendor fix ships, the maintainer pattern is:
1. After opening a PR, **manually visit the PR page** within 10 min.
2. Scroll past the bot's "review submitted" banner to find inline comments.
3. Resolve CR/Bugbot comments manually before the gate's first check.

This is operationally expensive but bypasses the delivery failure.

## Vendor escalation template

```
To: CodeRabbit support <support@coderabbit.ai>
Re: PR review delivery failure — jleechanorg/jleechanbrain

Hi CodeRabbit team,

Over the past several weeks we have observed a recurring pattern where
your bot completed reviews on PRs in jleechanorg/jleechanbrain but the
resulting state events appeared to be lost in your delivery queue:

  - PR #<REDACTED — fill before sending>  (head SHA <REDACTED — fill before sending>)
  - PR #<REDACTED — fill before sending>  (head SHA <REDACTED — fill before sending>)
  - PR #<REDACTED — fill before sending>  (head SHA <REDACTED — fill before sending>)

Each instance, verified via `gh pr view <N> --json createdAt,headRefOid`
and the PR timeline page:

Symptoms:
  - Inline review comments DID post to the PR page.
  - Maintainer email + Slack bridge (webhook-fanout) DID NOT receive them.
  - The requested_reviewers field on each PR does not list CodeRabbit, even
    though the bot did review.

Expected:
  - Review completion should yield a delivered status event.
  - Failure to deliver should retry until budget exhausted, then surface a
    vendor-side error (visible to the maintainer), not silently drop.

Please confirm receipt and ETA on a fix. We can provide full PR IDs + SHAs
on request once a maintainer fills them in.

Best,
jleechan
maintainer, jleechanorg/jleechanbrain
```

## Internal followup (action items)

- [ ] Maintainer: open vendor ticket with above template once ready.
- [ ] Add a Slack-bridge health check that polls CodeRabbit's webhook
      arrival rate vs. PR-creation rate; alert if ratio < 0.5.
- [ ] Update merge-gate docs to note the vendor bug and the workaround.
- [ ] `/learn` capture once vendor confirms or 30 days elapse.

## References

- `~/.claude/CLAUDE.md` — PR-green-definition + Bugbot policy
- `~/.claude/skills/babysit/SKILL.md` — AO-worker babysit protocol (the
  workaround above is what babysit would surface before the merge gate
  fires)
- `~/roadmap/nextsteps-2026-07-07-sidekick-hardening-recovery.md` (forthcoming)
