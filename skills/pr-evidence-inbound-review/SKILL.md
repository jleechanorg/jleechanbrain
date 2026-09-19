---
name: pr-evidence-inbound-review
version: 1.0.0
description: "Audit PR head + worktree state when Slack evidence arrives."
author: Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [workflow, github, pr, slack, evidence, divergence, worktree, inbound]
    related_skills: [pr-cleanup-replay, drive-pr-to-green, github-pr-workflow, evidence-attach-to-slack]
---

# PR evidence inbound review (Slack screenshot / link / comment → status read)

## When to use

Load when ANY of these signals fire (any one is sufficient):

| Signal | Action |
|---|---|
| User posts a Slack message with a screenshot, link, or comment that names a specific PR number (e.g. "PR 8829 V2 Planning Block - After") | Inbound PR evidence. Audit before suggesting push/merge/fix. |
| User posts a Slack message with `:camera_with_flash:` + PR-number caption | Inbound PR evidence. Audit. |
| User asks "is PR #N ready?" / "what's the state of PR #N?" / "is the PR green?" in Slack | Inbound PR review. Audit. |
| User pastes a GitHub PR URL into Slack with no other instruction | Inbound PR review. Audit. |
| User asks "should I push X to PR #N?" | Inbound PR review — divergence check is mandatory before answering. |

**Why this exists.** When evidence arrives via Slack (screenshot of UI, link to a deploy, before/after pair), the natural next step in the agent's head is "respond about the evidence → suggest push/merge/fix." But the local worktree may have drifted from the PR head, so any push lands on a divergence. This skill enforces a pre-flight check: **PR head + worktree HEAD + first-parent log + diff-stat** before recommending anything.

The discipline is the inbound mirror of `pr-clean-branch-from-main-no-history-bloat` (production side) and `never-push-onto-someone-elses-pr-head` (push-time gate). Same rule, different surface.

## Pre-flight sequence (always run, in this order)

### Step 1 — Fetch live PR state via REST (GraphQL may be rate-limited)

```bash
# Prefer REST when GraphQL bucket is exhausted
gh api repos/<owner>/<repo>/pulls/<N> \
  --jq '{number,state,title,head:.head.ref,head_sha:.head.sha,head_repo:.head.repo.full_name,base:.base.ref,mergeable,additions,changed_files,author:.user.login,html_url}'

# Skip --json, use --jq for compact output (REST survives GraphQL rate limit)
```

If the user just posted evidence, the message itself often names the PR. Don't re-ask — extract it from the Slack caption and call `gh api`.

### Step 2 — Check the CI gate rollup on the live head SHA

```bash
gh api repos/<owner>/<repo>/commits/<head_sha>/check-runs \
  --jq '.check_runs[] | "\(.name)\t\(.status)\t\(.conclusion)"'
```

Filter for `conclusion == "failure"` to find what's actually red. Don't trust PR-level summary — fetch the per-run state.

If a gate is red and the run is old (logs 410 = retention expired), say so explicitly. Don't claim "the failure was X" when the only evidence is "the gate failed."

### Step 3 — Locate the worktree the user is operating in

`git worktree list` shows every worktree on the machine. Find the one whose `HEAD` matches (or diverges from) the PR's `head_sha`. Common patterns:

- `${HOME}/projects/worktree_<short-topic>` — short-lived PR worktrees
- `${HOME}/projects/<repo>.wt/wt-<topic>` — `.wt` parallel workspace
- `/private/tmp/lane<N>-rev-<id>` — agento / AGY lane worktrees (ephemeral)
- `${HOME}/.ao/data/worktrees/...` — AO-managed worktrees

If `git worktree list` is unavailable (rare), fall back to `git rev-parse HEAD` from the CWD if it matches the PR branch, then note the assumption.

### Step 4 — Compare worktree HEAD to PR head SHA (the divergence check)

```bash
# Inside the matching worktree
git fetch origin <head-branch> 2>&1 | tail -3
echo "PR head on origin: $(git rev-parse origin/<head-branch>)"
echo "Local worktree HEAD: $(git rev-parse HEAD)"

# Diff stat between them
git log --oneline origin/<head-branch>..HEAD
git diff --stat origin/<head-branch>..HEAD
```

**This is the single most important step.** If the worktree is ahead of origin's PR head, **do not** suggest "push your local commits to the PR." Per `pr-clean-branch-from-main-no-history-bloat` and `never-push-onto-someone-elses-pr-head`:

- 0 commits ahead → safe to push (after CI green)
- 1-N small commits ahead, same scope → push with caution, run the clean-branch gates
- 1-N commits ahead, **different scope** (touches world_logic.py, llm_parser.py, rewards_engine.py, design-doc-gate.yml when the PR is about a UI composer) → DO NOT push. The branch is polluted; the user needs a clean replay per `pr-cleanup-replay`.

**Authorship check** — even on your own branch, divergence is forbidden if:
```bash
# If the worktree's authorship is NOT yours, do not push regardless
git log -1 --format='%an <%ae>' HEAD
gh api repos/<owner>/<repo>/pulls/<N> --jq '.user.login'
```
Mismatched author = shared head = contamination = `pr-cleanup-replay` is the fix.

### Step 5 — Diagnose the CI failure (if any)

If the gate is red AND the worktree has unpushed V2-style commits that should fix the issue:

- The failure may have been on an EARLIER head (e.g. the gemini rebase, before the V2 commits landed). Check which SHA the failing run was against via the run URL from the check-run output.
- If the failing head != the current PR head, the failure is moot — a fresh push will re-run the gate.
- If the failing head == current PR head, fetch logs (or accept the 410) and explain what the gate *would* check based on the workflow file.

**Workflow file lookup** — when logs are gone (410 retention), you can still reason about what failed by reading the gate workflow itself:
```bash
grep -n "name:" .github/workflows/<gate>.yml | head -5
sed -n '50,200p' .github/workflows/<gate>.yml  # the steps the gate runs
```

### Step 6 — Build the status read

Now you have everything for a faithful reply. Format:

```
🟢/🟡/🔴 <PR #N title> [<URL>]
- CI state on <head_sha>: 7 of 8 green, <gate> failing (or all green)
- <gate> failed on which head: <old-head> or <current-head>
- Worktree state: <ahead / on / behind> origin/<head-branch>
  - Diff: <N> files / +<add> -<del> (<scope drift? yes/no)
- Branch authorship: <user> vs <PR author>
- Memory used: <relevant entries>
- Next actions: <2-3 concrete options, NOT a confirmation gate>
```

**Avoid the confirmation gate.** Don't end with "Want me to push?" If the user said "ship it" / "push it" / "go," do the prep work and present the divergence + a clean-replay path with concrete next-step options (A/B/C). The agent drives; the user chooses the path.

### Step 7 — Check whether the evidence is already on the PR body (the "don't bloat the diff" gate)

Before deciding the next action, scan the PR body for the same evidence the user just posted. If the body already references:

- **Slack native file URLs** (e.g. `https://<workspace>.slack.com/files/<user>/<id>/<filename>`) — the user's Slack attachments are persisted in Slack's CDN and the URL works for any reviewer with workspace access.
- **Gist raw URLs** (e.g. `https://gist.githubusercontent.com/<user>/<hash>/raw/<commit>/<file>`) — these are git-pinned to a specific gist commit, render inline in the PR page via markdown image syntax, and survive forever.

…then the user's drop is a **confirmation, not new artifacts**. Action: acknowledge SHA match + CI status; **do not commit binaries to the branch**.

**Concrete rule for worldarchitect.ai specifically:** the project's evidence convention is `evidence/<topic>/{before,after}.png + README.md` (text + PNG only — see `evidence/composer-alignment/` for the canonical layout). MP4s are NOT checked in; they live in the Slack thread + the linked gist. Adding ~1.5 MB of MP4 binaries to git would bloat the PR diff, slow clones, and break the convention.

**How to verify the PR body already has the evidence:**

```bash
gh pr view <N> --json body --jq '.body' | grep -iE 'slack.com/files|gist.github|raw/<sha>'
```

If both Slack file URLs AND gist raw URLs are present in the body, the next action is status read only. If only one is present (e.g. body has Slack file URLs but not gist raw URLs), you may want to add the missing one — but check with the user first; don't auto-push a body edit.

**One-shot helper:** `scripts/check_pr_body_has_evidence.sh <owner/repo> <pr_number>` returns exit 0 (BODY_ALREADY_HAS_EVIDENCE → confirmation, do NOT commit binaries) or exit 1 (BODY_MISSING_EVIDENCE → net-new, `evidence/pr-NNNN/` commit needed). `chmod +x` on first use. Use this whenever the inbound drop is ≥3 attachments to avoid manual grepping.

**Anti-pattern:** seeing fresh Slack attachments and reflexively `git add evidence/pr-NNNN/*.mp4 && git commit`. The PR body already has the references; commit only adds git bloat.

## Anti-patterns

**"Just push the visual evidence commits."** This is the natural reflex after seeing `:camera_with_flash:` evidence. But if the worktree is 21-files diverged from the PR head (verified via `git diff --stat`), pushing inflates the PR diff by 10× and re-introduces drift. Always run Step 4 first.

**"The PR is ready, just merge it."** Don't say merge. Skeptic-cron owns merges; manual merges violate `worldarchitect.ai` AGENTS.md "do not merge without `MERGE APPROVED`". For inbound status reads, the right next step is **NOT merge** — it's "push, then let the merge cron handle it."

**"Re-run the gate, it should pass this time."** Re-running doesn't change a logic failure. If the gate's path filter (`mvp_site/frontend_v1/**` etc.) didn't trigger on the current head because the V2 frontend commits aren't pushed yet, the re-run will fail the same way. The fix is push first, re-run second.

**"Trust the user's caption about what the PR does."** The user named the PR in Slack; that doesn't tell you the *current* head state. Always fetch PR head SHA + worktree HEAD + diff. The caption may be from 3 commits ago when the gemini rebase happened.

**"Use `gh pr view --json`."** When GraphQL is rate-limited (very common on shared accounts), `--json` will fail with "API rate limit already exceeded." REST `gh api repos/.../pulls/<N>` survives. Same for `gh pr checks` — REST check-runs works when `gh pr checks --json` doesn't.

## Worked example — PR #8829 inbound evidence (2026-08-15)

**Slack message:** `[AI Terminal: worktree_ui_planningb] 📸 PR 8829 V2 Planning Block - After (Textarea Populated & Ready for Edit/Send)`

**Caption claimed:** Visual evidence of the V2 composer card after-state.

**Pre-flight sequence executed:**
1. `gh api repos/jleechanorg/worldarchitect.ai/pulls/8829` → state: open, head: `feat/planning-block-v2-unified-composer`, head_sha: `0ff4cefa8f`, +796 / 7 files, author: ${GITHUB_USER}
2. `gh api repos/.../commits/0ff4cefa8f/check-runs` → 26 checks, 1 failure: **Light/Fantasy Compliance Gate**
3. `git worktree list` → found `${HOME}/projects/worldarchitect.ai.wt/wt-planning-block-v2` on branch `feat/planning-block-v2-unified-composer`
4. **Divergence check:** `git fetch` showed `origin/feat/planning-block-v2-unified-composer = 0ff4cefa8f`, local HEAD = `9f06ed348b` → **3 commits ahead**, but `git diff --stat origin/<branch>..HEAD` showed **21 files / +173 / −1729** net. The 3 unpushed commits (V2 composer card + retrigger + visual evidence) sit on top of a much larger unrelated deletion/rebase pattern.
5. **Authorship check:** Worktree `git log -1 --format='%an <%ae>' HEAD` = ${GITHUB_USER}; PR author = ${GITHUB_USER} — **same author, but diff scope is contaminated**.

**Outcome:** Did NOT suggest "push the 3 commits." Surfaced the divergence explicitly:
- 3 PR-scope commits are clean
- But the 21-file −1556-net-lines drift means push would inflate the PR from +796/7 to roughly +796-plus-stale-deletions / 21 files
- Offered concrete next-step options: (A) clean replay — fresh worktree from origin/main + cherry-pick the 3 commits + push; (B) investigate prior Light/Fantasy failure first; (C) hold — user pushes manually.

**Why this matters:** The user's caption ("V2 Planning Block - After") made it look like the PR was ready. Without Step 4, the agent would have said "great evidence, want me to push?" — which would have buried a +1729-line deletion in the PR diff.

## Worked example — PR #9042 inbound confirmation (2026-08-18)

**Slack thread (${SLACK_CHANNEL_ID}/p1787098654574219):** User dropped 2 PNGs + 3 MP4s (desktop AFTER, mobile AFTER, desktop punchlist video, mobile punchlist video, tmux terminal video), all captioned with `SHA 4994e53c50` / `SHA MATCH 4994e53c50`.

**Pre-flight sequence executed:**
1. `ffprobe` all 3 MP4s — desktop 1440×900 / 12.56s, tmux 1170×828 / 1.29s, mobile 374×812 / 12.48s. `vision_analyze` extracted frames at midpoint: confirmed content matches captions (AFTER COLLAPSED peek-only desktop+mobile, PR STATUS block on tmux).
2. `gh pr view 9042 --json headRefOid,state,mergeable,reviewDecision` → head = `4994e53c50dfad212f070117c8964de8820db51e`, MERGEABLE, OPEN, no review yet.
3. `gh pr view 9042 --json body` → grep for `slack.com/files` and `gist.github` → body already references ALL 5 media items (Slack native file URLs + gist raw URLs).
4. **Step 7 check fired:** body already has the references → drop is confirmation, not new artifacts. Did NOT commit MP4s.
5. **Step 4 / worktree check:** `git worktree list` showed no worktree on `feat/header-avatar-scroll-gated-choices`; main checkout on `pr-9044` (different branch). No divergence risk for this PR. No push needed.
6. **CI snapshot:** 6 pass (Green Gate, Detect Changed Paths, Merge commit validation, Ruff, Design Doc Grep Gates, limit-pr-runs) / 14 pending (mypy, ESLint, Schema Coverage Guard, Light/Fantasy Compliance Gate, deploy-preview, Evidence Gate, 4× directory tests, etc.) / 0 fail. Fresh push, mid-run.
7. **Tmux SHA discrepancy:** user's caption "SHA MATCH 4994e53c50", but the tmux video's frozen PR STATUS block showed HEAD `b0263709fb…`. Resolved via `git rev-parse b0263709fb` → confirmed it's a parent commit of `4994e53c50`. The script captured the test run before the final commit landed; the user's "SHA MATCH" refers to PRE=POST consistency within the test run, not the PR HEAD.

**Outcome:** Posted status read only — no body push, no binary commit, no worktree edit. Created one-time 20m status cron `a9307aa3a8fa` to re-check CI in 20 min and post the next state in-thread.

**Why this matters:** Without Step 7 (the "don't bloat the diff" gate), the natural reflex would have been to `git add evidence/pr-9042/*.mp4 && git commit` to "preserve" the videos — adding ~1.6 MB to git history and breaking the `evidence/<topic>/{before,after}.png + README.md` convention. The PR body already had the references; the user's drop was a confirmation, not a request for new artifacts.

## Pitfalls

**Pitfall 1 — Slack-thread routing vs Slack-channel-root.** When responding with the status read, reply in the same thread as the evidence post. Per `slack-thread-routing-investigation` SOUL.md commit, the session context header `thread` field is a hint, not authoritative. Re-derive the thread via `mcp__slack__conversations_history(channel_id=<chan>, limit=5)` if the user is in a busy channel.

**Pitfall 2 — Logs 410 = retention expired.** When `gh run view --log-failed` returns HTTP 410, the workflow logs are gone (GitHub keeps them 90 days). Don't fabricate "the failure was X." State honestly: "logs expired; gate was Light/Fantasy Compliance Gate on head `0ff4cefa8f`; the V2 frontend commits that should trigger the path filter are not yet on origin."

**Pitfall 3 — `changed_files` field name.** `gh pr view --json` rejects `changed_files` (use `changedFiles`). REST API accepts both. When passing args through MCP wrappers, double-check the field name or use `gh api` directly.

**Pitfall 4 — `git diff origin/<branch>..HEAD` vs `git diff origin/main..HEAD`.** Use the **branch-to-branch** diff for the divergence check (PR head SHA vs local worktree HEAD). The **main-to-HEAD** diff shows what would land if the PR merges — useful for "how much would this add to main," but doesn't catch "is the worktree drifted from the PR head."

**Pitfall 5 — Branch protection on pushes.** When pushing to a PR head that has branch protection (e.g. requires CI before merge), a divergence-bearing push still goes through but produces a confusing PR diff for reviewers. The clean-replay path is friendlier to the reviewer — that's another reason to use it instead of pushing the divergence.

**Pitfall 6 — User-owned worktrees vs agent-managed ones.** If the divergence lives in `${HOME}/.ao/data/worktrees/...` (AO-managed), the agent's framing should be different — the worktree is owned by AO, the user may not have edited it directly. Pivot to asking what the AO worker is supposed to ship rather than proposing a manual clean-replay.

**Pitfall 7 — Local `git diff --stat` lies when `origin/main` is polluted with unmerged giant reverts** (verified 2026-08-17, PR #8997 follow-up). The diff between a feature branch and `origin/main` can show 85 files / +1470 / −47,764 lines because `origin/main` carries unmerged revert commits (e.g. evidence-bundle deletions, CI workflow removals) that the feature branch was branched-clean-of. The actual PR diff is far smaller (8 files / +857 / −73). The trap is treating the local stat as proof of shared-history pollution when it's just `main` lagging behind reality. Always cross-check Step 4 with the PR-scoped stat before declaring a branch contaminated: `gh pr view <N> --json additions,deletions,changedFiles` and `gh api repos/<owner>/<repo>/branches/<head-branch> --jq '{sha: .commit.sha, msg: (.commit.commit.message | splitlines | .[0])}'` for the remote HEAD. Push only after both numbers agree on the same scope. Pairs with `pr-clean-branch-from-main-no-history-bloat` and `never-push-onto-someone-elses-pr-head`.

**Pitfall 8 — Evidence is confirmation, not new artifacts (verified 2026-08-18, PR #9042).** User drops desktop+mobile+tmux videos in the Slack thread labeled "SHA MATCH 4994e53c50" — the PR body already references the same SHA via Slack file URLs + gist raw URLs. The natural reflex is to `git add evidence/pr-9042/*.mp4 && git commit` to "preserve the evidence." But the PR body already has the references; committing binaries only bloats the diff (~1.5 MB for 3 MP4s). Decision rule: if `gh pr view <N> --json body | grep -iE 'slack.com/files|gist.github'` already matches the dropped media, treat it as confirmation, not as new work. Acknowledge SHA match + CI status; do not commit binaries. Exception: if the body has a stale evidence section pointing at an OLDER commit's SHA (verified via `git rev-parse` against the body references), the new media IS new artifacts — add a brief evidence/ commit with the binary + SHA-pin it.

**Pitfall 9 — Tmux "PR STATUS" snapshot shows earlier HEAD than PR's current HEAD (verified 2026-08-18, PR #9042).** A tmux/asciinema video captured during a test run freezes a "PR STATUS" JSON block at the moment of capture. If the user's caption says "SHA MATCH <later-SHA>" but the video's frozen STATUS shows `<earlier-SHA>`, do not flag it as a SHA mismatch. The resolution is `git rev-parse <earlier-SHA>` against the PR HEAD's parent chain:

```bash
# Inside the repo
gh pr view <N> --json headRefOid --jq .headRefOid    # current PR HEAD
git log --oneline <earlier-SHA>..<pr_head_sha>        # confirm <earlier-SHA> is a parent
```

If `<earlier-SHA>` is in the parent chain, the video was captured during a test run that ran BEFORE the final commit landed — that's normal, the script snapshot just predates the final SHA. "SHA MATCH" in the user's caption refers to PRE=POST consistency within the test run (the test harness compares the served prompt's SHA to its own captured SHA, both of which were the same at the time of capture). If `<earlier-SHA>` is NOT in the parent chain — i.e. it's a divergent branch's HEAD or unrelated commit — THEN it's a real SHA mismatch and the evidence is for a different PR state. Verify with `git merge-base --is-ancestor <earlier-SHA> <pr_head_sha>`; non-zero exit = real mismatch.

**Pitfall 10 — Inbound-evidence status reads should produce a one-time 20m follow-up cron (per `one-time-status-cron-after-every-task` SOUL commit).** Inbound evidence typically arrives while CI is mid-run. Acknowledging the SHA match is necessary but not sufficient — the user will want to know when CI flips to green/red. Create exactly ONE cron: `hermes cron create "20m" --name '<topic> status (20m)' --deliver 'slack:<chan>:<thread_ts>' --repeat 1` with a self-contained status-check prompt that names the PR number, HEAD SHA expected, and the thread to post in. Do NOT use `--every` (creates recurring spam — root cause of `ao-1094` 10-day incident) and do NOT use `--keep-after-run`. Include the cron job ID in the status read reply so the user can find it.

**Pitfall 11.5 — Inbound video evidence with caption that lists multiple specific claims (verified 2026-09-14, PR #9841).** When the user's Slack message caption is a comma-separated list of feature claims ("Full desktop walkthrough video with cue-first matching banners, full-page contextual hints, real 200% text scaling and sheet reflow control activations"), do NOT trust the caption after a single mid-roll `vision_analyze`. The caption is itself the thing the user wants verified — content matching caption is the *first* check, not the final verdict. Mandatory 3-step empirical verification:

1. **Extract frames, not one.** `ffmpeg -i <video> -vf "fps=1/3" -q:v 2 /tmp/frames/frame_%03d.jpg` (one frame every 3 s is the right density for a 30-90 s walkthrough). 20 frames at 3 s = 60 s coverage. Single mid-frame misses transitions (the 200% scaling, the sheet open, the dismiss).
2. **Map each claim to a specific frame BEFORE inspecting.** Build a claim→frame table first, then inspect each mapped frame separately with `vision_analyze` (one frame per call, asking specifically about the claim it should prove). Do NOT batch-inspect "does this look right?" — that lets hallucinations sneak through. Specifically ask: "Is text noticeably larger than earlier frames?", "Does the banner sit next to the button it explains?", "Is a sheet/modal opened?"
3. **Report the claim→frame mapping in the reply** — the table itself IS the proof. Don't summarize "I extracted a few frames and they look fine" — that's a hand-wave, not a verdict.

Why this discipline: a caption can lie (see the 2026-09-07 firefox audit in `references/`), and a video can mislead (transitions frame-fast, captions baked in). The empirical discipline is the same as Pitfall 12 (browser-fix verification), just on the inverse polarity — here the claims are TRUE, and the verification must demonstrate that empirically rather than by trusting the user.

Companion rule for the reply — when the verification result IS the visual proof and you're replying to a user-originated DM (not posting cross-conversation), use `MEDIA:/absolute/path` inline tokens in your model output. The Slack delivery path the gateway uses for normal DM replies DOES honor `MEDIA:` and uploads them as native photo attachments. The 3-stage `files.completeUploadExternal` recipe in `evidence-attach-to-slack` is for CROSS-conversation posts only (where the gateway isn't routing). DO NOT hand-post with `mcp__slack__conversations_add_message` — the gateway already delivers your reply; hand-posting causes double-post and thread-routing bugs. See SOUL.md `slack-never-hand-post-your-own-reply`.

Reference: `references/2026-09-14-pr-9841-onboarding-walkthrough-video-audit.md` — full transcript of a 60.8 s onboarding-walkthrough verification with frame-by-frame claim mapping.

**Pitfall 11 — Inbound UI screenshot showing a PR's documented fix NOT applied is a deploy-verification signal (verified 2026-08-18, PR #9042).** Steps 1–7 confirm the source-code state, the PR body, the CI gates, and the worktree. They do NOT confirm the deployed bundle matches the source. When a user posts a Slack message saying "why is the image still cutoff?" or "the layout is still broken" alongside a UI screenshot from the deployed preview URL, that screenshot is itself a deploy-verification artifact in disguise — and Step 7's "body already has the references, do not commit binaries" answer can leave the staleness undetected for 30+ minutes until the user files a separate bug report (verified on PR #9042, where the user posted the cut-off avatar 25 min after the inbound evidence drop, and the agent had to retroactively diagnose `Last-Modified: Sat, 04 Jul 2026 18:53:10 GMT` on the served CSS — 45 days before the deploy CI's reported time). Concrete rule: when an inbound UI screenshot shows a defect that the PR's source code claims to fix, **load `pr-preview-deploy-verification` and run Phase 2 + Phase 2.7 in the SAME turn as the inbound review.** The cost is one extra `curl + grep + gh api` triplet; the cost of missing staleness is the user debugging "the fix" for half an hour before realizing the deploy never shipped. PR #9042 evidence chain: served `avatar.css` was 8 876 B vs repo HEAD 9 654 B (`Last-Modified` 45 days old, no `margin-top: -46px` rule); served `style.css` was 34 139 B vs repo HEAD 53 592 B (`Last-Modified` 45 days old, no `overflow-clip-margin: 56px` rule). Cross-ref `pr-preview-deploy-verification` P13 + P14 (added 2026-08-18) and `references/2026-08-18-pr-9042-stale-css-case-study.md`.

## Verification

After posting the status read, the user picks a path (A/B/C). Verify the next action landed:

- (A) Clean replay: confirm new worktree is `origin/main`, cherry-pick SHAs match, `git log origin/main..HEAD --stat` shows only the 3 commits + their actual file scope
- (B) Investigate: confirm workflow file inspection, no fabricated failure-cause claims
- (C) Hold: confirm no push was made; user takes it from here