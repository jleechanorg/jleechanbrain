---
name: external-agent-slack-handoff-reply
version: 1.0.0
description: "Fill empty URL placeholders in agent handoff Slack posts."
author: hermes-agent
license: MIT
metadata:
  hermes:
    tags:
      - slack
      - multi-agent
      - handoff
      - evidence
      - producer-consumer
    related_skills:
      - inline-attach-evidence
      - evidence-attach-to-slack
      - finish-the-job
      - always-pr-never-local-edit
triggers:
  - "AI Terminal posted a summary with empty fields"
  - "another agent finished work in a worktree and pinged"
  - "fill in the Spec / Branch@commit / Prototype placeholders"
  - "reply to a producer's handoff message"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
context: inline
---

## When to Use

Use this skill when:
- A Slack message arrives (DM, channel, or thread) containing an `[AI Terminal: <wt-name>]` or `[<other-agent>: ...]` prefix AND
- The message has empty placeholder fields (e.g., `*Spec & User Stories:* `, `*Branch:* (@ commit )`, `*Visual Wireframes Spec:* `) that need to be filled in with real GitHub URLs AND
- A worktree with the matching name pattern (often at `/private/tmp/<wt-name>` or `~/.worktrees/<wt-name>`) exists on disk with work to be reconciled AND pushed.

Do NOT use this skill for:
- Reply drafting where you're the originator (you wrote the work, you post the summary) — different workflow.
- Pure reading of an existing thread with no handoff expectation.
- Direct user-to-user conversation that doesn't involve a producer agent.

# External Agent Slack Handoff Reply

When a different agent/AI Terminal just finished a chunk of work and posted a Slack summary with empty placeholders like:

- `*Spec & User Stories:* `  *(empty)*
- `*Visual Wireframes Spec:* `  *(empty)*
- `*Interactive HTML Prototype:* `  *(empty)*
- `*Branch:* (@ commit )`  *(empty)*

Your job is **not** to redo the work. Your job is to read the worktree, find the artifacts the producer left behind, push any unpushed commits, and reply in-thread with durable GitHub URLs + proof.

## Workflow (mandatory order)

### 1. Re-read the full thread first

`mcp__slack__conversations_replies(channel_id, thread_ts, limit=20)` — or curl fallback `GET https://slack.com/api/conversations.replies?channel=<chan>&ts=<thread_ts>&limit=20` with `Authorization: Bearer $SLACK_BOT_TOKEN`. Do not react only to the latest message; gateway resume/handoff can drop context, and the producer's prior turns contain the worktree path, branch name, and intent.

### 2. Find the worktree

Try in this order:
- `git worktree list` from the canonical repo path (`~/projects/<repo>` for project repos).
- Look up the worktree name pattern in `[AI Terminal: <wt-name>]` — often at `/private/tmp/<wt-name>`.
- `ls /private/tmp/wt-*` and `ls ~/.worktrees/`.
- `git -C <path> status --short --branch` once you find it.

### 3. Reconcile — DO NOT duplicate

**Critical step.** Run before committing anything:

```
git status --short
git log --oneline origin/<branch> -10
git diff origin/<branch> --stat
```

If prior sessions already committed:
- Full-page screenshots (e.g., `desktop_01_breaking_bad.png` 433KB) AND a `capture_mocks.py` script
- A `## 5. Visual Mocks (PNG Evidence)` section in a spec doc
- Modified local files (`M docs/mocks/...`) that update an unpushed commit

…then the producer did real work. Your job is to:
- Inspect what's already committed vs. uncommitted vs. unpushed.
- Only commit what's *new* (e.g., a mobile sticky CSS patch, a §5 → §6 section, your 3-stage uploaded screenshots).
- If Slack-uploaded files have different filenames AND smaller file sizes than the existing committed evidence, **the committed files are usually higher fidelity** — replace, don't append.
- Do NOT `git stash` or `git checkout --` to "start clean" — the producer may have in-flight changes you don't understand.

### 4. Verify the producer's claims with vision

If the producer uploaded PNGs to Slack, download them via `url_private` + bearer token, then `vision_analyze` them to confirm what's actually visible (vs. what the producer claims is visible). Common drift: producer claims "live LLM prompt directive preview shown" but the screenshot is cropped above the fold.

### 5. Commit + push as ONE coherent handoff commit

Single commit per handoff. Use the producer's branch as base; if upstream isn't set, run `git branch --set-upstream-to=origin/<branch> <branch>` first (per `pr-ci-fix-autopush.mdc` "Branch upstream tracking — always set"). Push via `git push origin HEAD:refs/heads/<branch>`. Watch for the `git secret guard` scan line — if it scans the range and reports clean, the push is safe to broadcast as proof.

### 6. Reply in-thread with filled-in fields + proof

Fill every empty placeholder from the producer's message:
- `*Spec & User Stories:*` → `<https://github.com/OWNER/REPO/blob/<branch>/path/to/spec.md|`path/to/spec.md`>`
- `*Visual Wireframes Spec:*` → same shape, blob URL.
- `*Interactive HTML Prototype:*` → same shape, blob URL.
- `*Branch:* (@ commit )` → `<branch> @ <short-sha> (<full-sha>)`.

Plus a one-line proof block: `git log -1` output, `git push` success line, secret-gate scan clean.

## Pitfalls

- **Don't redo work that a prior session already committed.** This is the #1 mistake. `git status --short` + `git log origin/<branch>` first. If `desktop_01_breaking_bad.png` 433KB exists at `docs/mocks/screenshots/`, and the Slack upload is `wt-docs-mock-1786696031.054689.png` 272KB (smaller, partial viewport), the existing file is the better evidence — delete the dup, don't `git add` it.
- **Don't open a PR unless asked.** Producer → consumer → user pattern: producer pushes branch, consumer reviews diff, user opens PR. Match the user's gate. State explicitly in your reply: "PR not opened — ready to draft one against `<base>` whenever you say go."
- **Don't use `curl -d '{...}'` for Slack messages with markdown code/backticks/code-fences.** Bash backtick substitution and `$(...)` expansion will mangle the JSON. Write the payload to `/tmp/slack_reply.json` via `write_file`, then `curl --data-binary @/tmp/slack_reply.json` with `Authorization: Bearer $SLACK_BOT_TOKEN`. (Caught this session: backticks in `max-width: 480px` and `` `refs/heads/...` `` ate the JSON, returned `invalid_json`.)
- **Don't reply to a Slack message whose body starts with `[AI Terminal: ...]` without re-fetching the thread.** Gateway resume can drop context; the "latest message" in your context window may not be the producer's most recent one. Always `conversations_replies` first. (See SOUL.md `slack-reply-inherit-thread-ts`.)
- **Don't blindly `git push` onto a shared branch without checking `git log origin/<branch>..HEAD`.** If multiple agents are co-developing the same branch, your push may carry another agent's WIP. Verify the commits are yours before pushing.
- **Don't include `MEDIA:/abs/path` tokens in the Slack reply when GitHub blob URLs already render the same evidence** in the linked spec doc. The 3-stage `files.completeUploadExternal` upload is only needed when the evidence isn't already committed to a public branch. (See SOUL.md `evidence-attach-not-path-cite` + `evidence-attach-presend-gate`.)

## Anti-patterns

- ❌ Committing 4 Slack-uploaded partial-viewport PNGs over already-committed full-page PNGs because "they're in the thread so I should preserve them."
- ❌ Posting the Slack reply as text-only with raw `/Users/.../path.png` references (invisible to the user on mobile).
- ❌ Filing "ready for review" claims without a `git log -1` proof block + push confirmation.
- ❌ Auto-opening a PR because "the work is done" — violates the user gate (user reviews diff, user opens PR).
- ❌ Hardcoding the producer's commit SHA in your reply without re-verifying via `git log -1` (the producer may have amended).

## Verification before posting the reply

- [ ] `git status --short` shows no uncommitted evidence files you forgot.
- [ ] `git log -1 --format='%H %s'` matches the SHA you cite in the reply.
- [ ] `git push` succeeded (no auth error, secret-gate scan clean).
- [ ] Every empty placeholder from the producer's message has a GitHub blob/tree/commit URL.
- [ ] `conversations_replies` was called BEFORE composing the reply (re-fetched the thread).
- [ ] Reply landed in the correct thread — verify via the returned `ts` + `channel` from `chat.postMessage`.

## Cross-references

- SOUL.md `pr-ci-fix-autopush.mdc` — push without being asked, resolve PR head first.
- SOUL.md `pr-clean-branch-from-main.mdc` — branch from `origin/main`, not from a polluted local branch.
- SOUL.md `evidence-attach-not-path-cite` — for PRs, commit binaries + embed `![caption](https://github.com/OWNER/REPO/blob/<branch>/path?raw=true)`.
- SOUL.md `evidence-attach-presend-gate` — for Slack replies with `MEDIA:` tokens, 3-stage upload is mandatory.
- SOUL.md `slack-reply-inherit-thread-ts` — re-fetch thread via `conversations_history` before posting.
- SOUL.md `no-confirmation-gate` — match the user's auto-PR pattern; don't ask "want me to PR?" — state "PR not opened, ready to draft when you say go."
- Skill `inline-attach-evidence` — visual evidence must be durable (committed, not raw path).
- Skill `finish-the-job` — end-state declaration is the handoff reply; proof block required.

## Reference

- `references/worked-example-campaign-wizard-2026-08-14.md` — full session walkthrough of this pattern: producer (Gemini via AI Terminal macbook) committed `0719ee5f78`, left `capture_mocks.py` + full-page PNGs uncommitted, posted a Slack summary with empty `{Spec, Wireframes, Prototype, Branch}` fields; consumer reconciled by running `git status`, deleted 4 duplicate Slack-uploaded partial-viewport PNGs, kept committed full-page PNGs, added `76eae528b5` with mobile sticky CSS + visual evidence section, pushed, and posted the filled-in reply.