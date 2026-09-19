# Recursive probe fix — PR #818 (2026-08-14)

## The bug

Recursive dropped-thread ping-pong loop observed in `${SLACK_CHANNEL_ID}/1786596160.718939` (2026-08-12 daily-thread):

```
probe(1786685007) → ack(1786685207) → probe(1786686966) → ack(1786687002)
              → probe(1786688859) → ack(1786688884) → probe(...)
```

Three-deep chain of MCP Mail bot probes, each one quoting the prior ack body as the new "Original request".

## Root cause

Prior fix `commit 39251146e2` added an ack-of-ack skip rule to `_is_automated_report`:

```python
if re.search(r"^ack(?:-of-ack)?:\s+\S+/\S+\s+—\s+\S+\s+—\s+action needed:", t):
    return True
```

Two bugs:
1. **Multi-paragraph acks fail to match.** Real acks are always multi-line (header + 1-3 paragraphs of context). The regex required everything on one line.
2. **Slash notation required.** The regex required `\S+/\S+` (channel/ts), but real acks use backtick-quoted ts without channel prefix.

## The fix (PR #818, commit `c1e0a5bbe1`)

Apply to **both** copies of `_is_automated_report` in `scripts/dropped-thread-followup.sh` (line 720 inline Python helper + line 1396 standalone Python module):

```python
head = t.split("\n", 1)[0]
if re.search(r"^ack(?:-of-ack)?:.*?—\s+action needed:\s*(yes|no)\b", head):
    return True
if re.search(r"^ack(?:-of-ack)?:\s+no-op\s+—\s+action needed:", head):
    return True
```

Key changes:
- `head = t.split("\n", 1)[0]` — anchor the regex to the first line so multi-paragraph acks still match
- `^ack(?:-of-ack)?:.*?` instead of `^ack(?:-of-ack)?:\s+\S+/\S+` — accept any id format (channel/ts, backtick-ts, free-form)
- `(yes|no)\b` — explicit word boundary prevents matching "action needed: maybe"

## The regression test

`tests/test_dropped_thread_ack_skip.py` — 4 contract tests, 13 total cases:

| Test | Cases | Purpose |
|---|---|---|
| `test_positive` | 6 acks (single-line, multi-paragraph, depth-3 recursion) | Every ack the agent posts must skip the watcher |
| `test_negative` | 7 real human asks ("Status on backulog", "Run /launchd...") | Operator messages must not be suppressed |
| `test_first_line_match` | 1 multi-paragraph ack | Verify the head-of-line anchoring works |
| `test_action_needed_word_boundary` | 1 invalid value ("maybe") | Verify the `yes\|no` alternation is enforced |

```bash
cd ~/.smartclaw && python3 -m pytest tests/test_dropped_thread_ack_skip.py -v
→ 4 passed
```

## The worktree pattern

Per `pr-clean-branch-from-main-no-history-bloat` and `never-push-onto-someone-elses-pr-head`:

```bash
git fetch origin
git worktree add -b fix/<topic> /tmp/<topic> origin/main
# edit + test in the worktree
git add <files>
git commit -m "claudem/minimax-M3: <type>(<scope>): <summary>"
git push origin HEAD:refs/heads/fix/<topic>
gh pr create --base main --head fix/<topic> --title "..." --body "..."
```

`~/.smartclaw` repo `origin` points to `jleechanorg/jleechanbrain.git` (NOT `hermes-agent.git` — that's the other remote).

## Verification

- Branch clean from `origin/main` (sha `75c57ee192`)
- Diff: `git log origin/main..HEAD` shows only the 2 load-bearing files
- Outbound secret scan passed (no PATs in commit)
- 4/4 tests pass
- PR: https://github.com/jleechanorg/jleechanbrain/pull/818

## Status as of 2026-08-14

PR open, awaiting `MERGE APPROVED`. Pending — needs user PR review + merge to apply to live watcher.

After merge + `~/.smartclaw/scripts/deploy.sh` deploy, the recursive ping-pong class is broken at the watcher side. The MCP Mail bot's downstream consumer may still fire probes (it has its own classifier), but the watcher will no longer echo them back.

## Source transcript excerpt

```
[U0A4G7LDJ4R | Slack user <@U0A4G7LDJ4R>] [Dropped-thread followup] This thread appears to have gone cold.
Original request: "Ack: dropped-thread followup probe `1786686966.135009` (recursive on `1786685007.107549`) — no-op — action needed: no ..."
Please provide a status update on the requested action, or confirm if work is complete.
```

Note the probe text quotes the prior ack body verbatim — that's the recursive pattern.