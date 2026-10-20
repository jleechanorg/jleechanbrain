---
skill: artifact-readback-verify
date: 2026-08-17
thread: C0AH3RY3DK6/1786859752.248729
incident: PR #8829 (worldarchitect.ai) — false "evidence missing" verdict
---

# Raw GitHub URL 404 vs API contents present

## The trap

A downstream agent posts evidence URLs of the form:

```
https://raw.githubusercontent.com/<owner>/<repo>/<branch>/evidence/pr-NNNN/{before,action,after}.png
```

You run a readback:

```bash
curl -o /dev/null -w '%{http_code} size=%{size_download}\n' \
  https://raw.githubusercontent.com/jleechanorg/worldarchitect.ai/feat/planning-block-v2-unified-composer/evidence/pr-8829/before.png
# 404 size=14
```

You write up the verdict: *"Evidence files do not exist on the branch. The prior
handoff's claim is false."* You post it twice in the same thread. The user
re-checks and the files are right there on the branch under the exact path you
named.

## Why the verdict was wrong

The `raw.githubusercontent.com` URL is **token-signed at CDN-fetch time**. The
GitHub web flow mints a fresh `?token=...` query param whenever a user opens
the branch in github.com and copies the link. That URL is what renders
correctly in a browser because the browser session also carries the cookie that
authorizes the token.

A plain `curl` from a non-browser client (no `Authorization: Bearer <gh-token>`
header) does NOT match the CDN's auth model and gets a 404. The actual file in
the Git tree is fine — the URL simply does not format the way the CDN expects
without the matching token.

## The readback ladder (always climb both rungs)

```bash
# Rung 1 — cheap CDN fetch. Matches what a browser sees. Subject to token
#         signature and CDN caching. 404 here is NOT proof of absence.
curl -o /dev/null -w '%{http_code} size=%{size_download}\n' -fsSL \
  https://raw.githubusercontent.com/<owner>/<repo>/<branch>/path/to/asset.png

# Rung 2 — authoritative API check. Proves the blob exists at the ref.
gh api repos/<owner>/<repo>/contents/<path>?ref=<branch-or-sha> \
  --jq '{name, size, sha, download_url}'
```

## Decision matrix

| Rung 1 (curl) | Rung 2 (gh api contents) | Verdict |
|---|---|---|
| 200, size=X | 200, size=X | **Present.** Browser URL works. |
| 404 | 200, size=X | **Present via API, URL unfetchable from CLI.** Blob exists at ref; the URL is just CDN-token-blocked. This is the false-404 case. |
| 404 | 404 | **Missing.** Both rungs agree. |
| 200 | 404 | **Stale-CDN cache.** curl is hitting cached 404; re-run rung 2 with `ref=<sha>` (commit SHA, not branch name) and trust rung 2. |
| 200, size=14 | 200, size=Y | **Mismatch.** rung 1 returned an error page (GitHub 404 page is 14 bytes); report the actual file size from rung 2. |

## Anti-pattern: the false-404 cascade

The PR #8829 thread shows the cascade: round 1 the agent (correctly) flagged
the AI Terminal's `/er` claim as suspect because of pending checks. Rung 1
on raw.githubusercontent.com returned 404. The agent amplified the
"evidence missing" finding into a multi-paragraph "the AI Terminal's report
is materially inaccurate" verdict, then posted it twice, then got dropped-thread
pings asking for status. Rung 2 (`gh api contents/...?ref=<head-sha>`) revealed
all 3 PNGs were present with valid blob SHAs and reasonable sizes for real
preview captures (~518KB each).

The agent corrected itself in the next reply, but the same false-404 reached
the user twice. The cost was the user had to re-discover the file presence
themselves.

## How to make the raw URL fetchable from a browser

The browser-rendered URL gets a `?token=ABCD...` query param that is
opaque and regenerated per-view. There is no API to mint this token from
the CLI. To make the URL fetchable from a *non-browser* client, you need
to send the requesting client's own GitHub token:

```bash
curl -fsSL -H "Authorization: Bearer $(gh auth token)" \
  https://raw.githubusercontent.com/<owner>/<repo>/<branch>/path/to/asset.png \
  -o /tmp/asset.png
```

This works because the GitHub CDN accepts both browser-cookie auth and
GH-token auth. But for the purpose of *existence verification*, rung 2
is the simpler path — it does not require a token-aware download.

## Bigger-picture lesson

The PR #8829 incident demonstrates the same false-green/false-red pattern
operating in both directions:

- **False green (upstream):** the AI Terminal's `/er` claim cites screenshots
  that "verify" against the live server, but the screenshots do not match the
  PR's actual state (round 4 had the AI Terminal posting dashboard images
  captioned as in-game view).
- **False red (downstream):** the agent's "evidence missing" verdict amplifies
  a CDN 404 into a multi-paragraph "the report is materially inaccurate" claim
  when the files genuinely exist on the branch.

Both directions are readback failures. The lesson is the same: climb both
rungs, name the SHA you verified against, and never restate a finding
single-source.

## Audit recipe (re-runnable)

```bash
# 1. Get the current head SHA
HEAD_SHA=$(gh pr view <N> --repo <owner>/<repo> --json headRefOid -q .headRefOid)

# 2. Check each claimed asset at the head SHA
for path in evidence/pr-8829/before.png evidence/pr-8829/action.png evidence/pr-8829/after.png; do
  echo "=== $path ==="
  curl -o /dev/null -w 'curl: %{http_code} size=%{size_download}\n' -fsSL \
    "https://raw.githubusercontent.com/<owner>/<repo>/$HEAD_SHA/$path"
  gh api "repos/<owner>/<repo>/contents/$path?ref=$HEAD_SHA" \
    --jq '"gh api: size=\(.size) sha=\(.sha[:10])"'
done

# 3. Cross-reference: if any curl=404 but gh api=sha present, the file is on
#    the branch and the curl URL is just CDN-token-blocked.
```

## Related

- `references/ci-summary-vs-gh-pr-checks-2026-08-16.md` — same incident,
  different false direction (terminal claims green, `gh pr checks` shows red).
- `references/visual-content-vs-caption-mismatch-2026-08-16.md` — same PR #8829,
  caption-vs-image-content mismatch (image present, content doesn't match).
- `SKILL.md` § "Raw `raw.githubusercontent.com` URLs can 404 even when the blob
  exists" — the 7-line pitfall entry that points here.
