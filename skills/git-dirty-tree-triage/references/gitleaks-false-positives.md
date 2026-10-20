# gitleaks pre-push false positives

Recovery recipe when the `git secret guard` pre-push hook (at `~/.config/git/hooks/secret-scan.sh`) blocks your push on a false positive.

## The hook

`~/.config/git/hooks/pre-push` calls `secret-scan.sh pre-push`, which on `pre-push` mode:

1. Computes the outgoing range: `merge-base(origin/main, HEAD)..HEAD`
2. Runs `check_commit_paths` to reject sensitive filenames
3. Runs `gitleaks git --log-opts <range> --redact=100` to reject secret-looking content

If either fails, push is blocked with `git secret guard: push blocked by secret scan for origin <url>`.

## Common false positives in research repos

| RuleID | What it catches | Common false-positive trigger | Verify against |
|---|---|---|---|
| `generic-api-key` | Long random API keys | Firestore 20-21 char base62 campaign IDs in research logs | Tracked file like `2026-04-17-level-up-consolidated-repro-and-evidence-coverage.md` (already in repo) |
| `aws-access-token` | AWS_ACCESS_KEY_ID format | Long alphanumeric sequences in audit reports | Tracked files containing similar IDs |
| `github-pat` | `ghp_` prefixed tokens | Sometimes matches base62 inlined in URLs | Tracked files containing the same URL |
| `private-key` | PEM blocks | Multi-line base64 in research docs | Tracked files with similar encoded payloads |

The **verification test** before treating it as a false positive: `git grep -E '<pattern>' -- '*.md' 2>/dev/null | head -3` — if tracked files in main contain the same pattern, the rule is firing on legitimate content.

## Diagnostic commands

```bash
# Run gitleaks on the same range the hook scans, with verbose output
gitleaks git --log-opts "<merge_base>..<local_sha>" --redact=100 --no-banner --log-level debug --verbose .

# Example output:
#   Finding:     ...Key campaigns: REDACTED, 6aXYric3k1IXtJIg6...
#   Secret:      REDACTED
#   RuleID:      generic-api-key
#   Entropy:     4.121928
#   File:        bq-prefix-forensics-2026-08-10.md
#   Line:        129
#   Commit:      dcae853...
```

## Recovery — remove the file from the commit

The safe move when confirmed false positive:

```bash
# Unstage just that file (leaves it on disk as untracked)
git rm --cached <path>
# Note: file shows as D in staged, ?? in working tree (untracked)

# Amend the commit to drop the file
git commit --amend --no-edit

# Verify the file is gone from HEAD
git show HEAD --stat | grep <basename> || echo "removed cleanly"

# Push again
git push origin main
```

**Do NOT** in this same commit:
- Add a `.gitleaks.toml` allowlist — that's a policy change that needs its own PR.
- Disable the pre-push hook.
- Force-push to bypass.

## When the false-positive source IS legitimate

If the file actually contains secrets (not just base62 IDs), the file should not be in the repo. Steps:

1. `git rm --cached <path>`
2. Edit the file to redact the secret
3. `git add <path>` + new commit + push
4. Rotate the leaked secret immediately (do this BEFORE the push if it's already in any tracked history)