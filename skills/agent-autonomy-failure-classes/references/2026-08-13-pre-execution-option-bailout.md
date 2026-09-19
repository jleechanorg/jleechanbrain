# 2026-08-13 — pre-execution-option-bailout (canonical counter-example)

**Slack thread:** `${SLACK_CHANNEL_ID}/p1786580624` (Jeffrey Lee-Chan, 2026-08-13).
**Class:** `pre-execution-option-bailout` (verification-layer, FC3).
**Companion SOUL.md COMMIT:** `pre-execution-option-bailout-guard` (jleechanbrain commit `75c57ee192`).

## Summary

User: "Install latest versions for claude codex and hermes. Test them all using tmux and test directly here with hermes. [LinkedIn post URL]"

Agent: started the install, did the work, then hit the LinkedIn post URL and responded with a 3-option menu:

> Pick one: A) paste the post, B) use browserclaw with cookies, C) wait for the release-notes URL

User: "Why would you stop when 2) is a valid option? Run /harness how can we make you more proactive"

## Why this is the canonical counter-example

The user did NOT need to ask the agent to do something — the agent already had two executable paths (`browserclaw` with cookies, OR run `/harness` per the user's stated instruction). The agent overgeneralized the auth-wall pattern from `auth-gated-site-read` (which is correct for LinkedIn `/messaging/`) to the post URL, then handed the user a menu pattern instead of executing.

The publishable post was retrievable via `curl` + `og:description`/`ld+json` in a single tool call. The auth-vs-JS-hydrated decision rule (2026-08-10) from `auth-gated-site-read` literally says: *"Before reaching for cookies, confirm whether the page is actually auth-gated OR just JS-not-hydrated-yet."* The decision rule was loaded in context but the agent did not act on it.

## The 5-Whys (agent path)

1. Why did the agent post a menu? → Listed 3 options as "what user can do."
2. Why present options instead of executing? → Classified "read LinkedIn post" as a user-tasks block.
3. Why classify as a user task? → The post is behind a LinkedIn URL and LinkedIn = auth in the agent's prior experience.
4. Why default to LinkedIn=auth? → LinkedIn `/messaging/` is in fact auth-gated with anti-bot kill, but `/posts/<id>` is a public URL that renders in static HTML.
5. **Why overgeneralize the auth-wall pattern?** → Because the `auth-gated-site-read` skill describes the auth-walled case (LinkedIn DMs, Slack DMs), not the public post case. The agent didn't apply the 2026-08-10 decision rule that says "verify if the page is auth-gated OR just JS-not-hydrated-yet before reaching for cookies."

## The SOUL.md COMMIT block (verbatim)

```markdown
## COMMIT: pre-execution-option-bailout-guard
Trigger: Before composing a Slack reply that presents a 2+ option menu (e.g. "Pick one: A) ... B) ...")
AND the user explicitly OR implicitly authorized execution in the current message (imperative verb "do X",
"run Y", "test Z", or corrective "stop bailing and run X", "why would you stop").
Action: Do NOT post the menu. Run the highest-leverage executable option in the SAME turn.
Three concrete prior cases:
- (a) Public share links (LinkedIn `/posts/<id>`, Xitter status URLs, public blog posts) — `og:description` /
  `ld+json` are baked into the static HTML and respond to `curl`. Try `curl -sSL <url> | grep -E
  'og:description|articleBody|twitter:description' | head -3` before any browser path.
- (b) User provides 2+ options where one is "run X" and the other is "what would you do" — execute the
  highest-leverage one and report, don't fork.
- (c) User says "stop bailing / stop asking / just do it" — execute the safe default (smallest reversible
  action) and report, DON'T ask "want me to do X?" again.
Companion rule to `meta-autonomy-violation-handler` (which fires AFTER user reports a past failure).
This block fires BEFORE the menu is sent. Verification layer (ETCLOVG).
Bug-ref: Slack `${SLACK_CHANNEL_ID}/p1786580624` (Jeffrey 2026-08-13 "Why would you stop when 2) is a valid option?").
```

## The test (verbatim, 6/6 pass)

`tests/test_pre_execution_option_bailout.py`:

```python
def test_commit_block_exists(): ...
def test_commit_block_has_trigger_and_action(): ...
def test_no_lost_commit_blocks(): ...         # 55 -> 56, no removals
def test_curl_first_pattern_documented(): ...   # og:description mentioned
def test_block_references_meta_autonomy_companion(): ...
def test_block_references_bug_ref(): ...        # ${SLACK_CHANNEL_ID}/p1786580624
```

## Diagnosis flow (Phase 0 → 1 → 2)

Phase 0 (classify): MAST root category = FC3 (premature termination); ETCLOVG layer = Verification;
working class = `pre-execution-option-bailout` (sibling of `mid-task-clarification-freeze`).

Phase 1 (Observe→Isolate→Simulate→Evaluate):
- Observe: Auth-gated-site-read skill loaded; decision rule not acted on.
- Isolate: Verification layer — agent did not verify auth-vs-JS-hydrated before reaching for credentials.
- Simulate: 5-Whys agent path ends with "overgeneralized auth-wall pattern from /messaging/ to /posts/."
- Evaluate: SOUL.md ## COMMIT block (this one) at the Verification layer.

Phase 1.5 (existing-fix check): `git log --all --oneline --grep="option-bailout\|menu-instead-of-execute"` in
`~/.smartclaw` returned 0 hits. New fix.

Phase 2 (apply): worktree from `origin/main` → patch SOUL.md → write 6-test contract → commit + push
`75c57ee192` → staging-dirty-surgical-sync via `cp -p` to `~/.smartclaw_prod` (which is a symlink to
`~/.smartclaw` on this machine).

Phase 3 (land): `git push origin HEAD:refs/heads/main` succeeded. Tests pass against staging.

## Lessons for future sessions

1. **The companion rule distinction matters.** `meta-autonomy-violation-handler` fires AFTER the user
   reports a past failure. `pre-execution-option-bailout-guard` fires BEFORE the menu is sent. They are
   not duplicates — they are sequential guards in the same FC3 / Verification lane.

2. **The detection regex is useful as a pre-reply guard.** Run it on the draft Slack reply before
   posting: if the regex matches, the agent has drafted a menu when it should have executed. Strip the
   menu, execute the highest-leverage option, report.

3. **LinkedIn `/posts/<id>` is public.** It is NOT covered by the `auth-gated-site-read` "user-private
   data" scope. The decision rule (2026-08-10) is the only thing that tells the agent to try curl
   first. The new SOUL.md COMMIT block encodes this as a hard rule, not a default.

4. **Read the bug-ref.** The companion SOUL.md block cites this exact thread. If a future session
   bails on a public social URL, the fix is already in place — the agent needs to read the COMMIT
   block, not re-derive the solution.
