# Mastodon rel="me" HTML snippets

Drop-in snippets for the most common case: a Mastodon profile claiming a homepage as its website field.

Replace `<instance>` with the actual Mastodon host (e.g. `mastodon.social`, `mas.to`, `hachyderm.io`) and `<username>` with the local username. Replace `<your-site>` with the claimed homepage URL.

## Snippet A — `<head>` link (preferred, invisible, verifier-accepted)

Place inside the `<head>` of the claimed homepage's HTML template, ideally immediately after the favicon `<link>` and before the `<title>`:

```html
<link rel="icon" type="image/svg+xml" href="/favicon.svg" />
<!-- Mastodon identity verification: invisible <link rel="me"> lets <instance>/@<username>
     verify ownership of <your-site> without rendering anything visible. Mastodon's
     verifier checks for rel="me" pointing back to the profile URL. -->
<link rel="me" href="https://<instance>/@<username>" />
<title>Your Site Title</title>
```

## Snippet B — Body anchor (redundant, off-screen, accessible without JS)

Place immediately before `</body>`:

```html
<!-- Mastodon rel="me" body link (visible only to the verifier; off-screen via CSS).
     Mastodon accepts either a <link rel="me"> in <head> (preferred, see above) OR an
     <a rel="me"> in the body. This redundant anchor matches the documentation Mastodon
     provides to site owners and survives any future change to the favicon/link order. -->
<a rel="me" href="https://<instance>/@<username>"
   style="position:absolute; left:-9999px; width:1px; height:1px; overflow:hidden;"
   aria-hidden="true" tabindex="-1">Mastodon</a>
</body>
```

## Why both forms?

- `<link rel="me">` in `<head>` is the documented, primary form. It is invisible by definition.
- `<a rel="me">` in `<body>` is the form Mastodon shows site owners in their verification instructions. Some old verifiers only check the body, not the head. Belt and suspenders.
- Both forms are required to be in the **static HTML** (no JS injection).
- `display:none` is unsafe — some Mastodon implementations skip hidden elements. Use `position:absolute; left:-9999px` + `aria-hidden="true"`.

## Worked example (PR [#9203](https://github.com/jleechanorg/worldarchitect.ai/pull/9203), 2026-08-20)

- Instance: `mastodon.social`
- Username: `jleechan`
- Claimed site: `https://worldarchitect.ai`
- Repo: `jleechanorg/worldarchitect.ai`
- Branch: `feat/mastodon-relme-verify` (from `origin/main` `3a6a5c9174`)
- File: `mvp_site/frontend_v1/index.html` (+9/-0)

Both snippets shipped as a single PR; CI green on shard-1 + shard-3; shard-2 had 3 pre-existing backend failures (BQ logger → `/dev/null`, prompt relocated blocks, divine prompt section headings) unrelated to the HTML-only diff. PR was mergeable; CR rate-limit warning posted but not a verdict.

## Verification recipe (post-deploy, after PR is open)

Three probes you might try and the silent failures to expect:

| Probe | Result | Use? |
|---|---|---|
| `curl https://raw.githubusercontent.com/<owner>/<repo>/<sha>/<path>` | HTTP 404 | ❌ raw.githubusercontent.com is unreliable for SHA + path combos |
| `gh api repos/<owner>/<repo>/pulls/<n>/files --jq '.[].filename'` | `null` | ❌ REST `pulls/{n}/files` returns `path`, not `filename` |
| `gh api repos/<owner>/<repo>/commits/<sha>/status` | empty `statuses[]` | ❌ Check `gh pr view --json statusCheckRollup` instead |
| **`gh api repos/<owner>/<repo>/contents/<urlencoded-path>?ref=<sha>`** | **works — base64 `content` field** | ✅ **canonical PR HEAD content probe** |
| `gh api graphql -f query='...pullRequest(number:N){files(first:N){nodes{path...}}}'` | works | ✅ Good when you also need additions/deletions/changedFiles |

After deploying the PR preview, run this to confirm both forms actually landed in the live HTML:

```bash
SHA="<commit-sha>"
gh api "repos/<owner>/<repo>/contents/mvp_site%2Ffrontend_v1%2Findex.html?ref=$SHA" \
  | python3 -c "import json,sys,base64; print(base64.b64decode(json.load(sys.stdin)['content']).decode())" \
  > /tmp/pr_head.html

grep -n 'rel="me"' /tmp/pr_head.html
# Expect two hits — one <link> in <head>, one <a> in body.

python3 -c "
import html.parser
class P(html.parser.HTMLParser):
    def error(self, m): print('PARSE ERROR:', m)
P().feed(open('/tmp/pr_head.html').read())
print('HTML parses clean')
"
```

Then in the Mastodon web UI → Edit profile → claimed website field → click "Verify" — the field should flip to a green checkmark within seconds.

## Verifier quirks to avoid

- ❌ `display:none` — some Mastodon verifier builds skip elements hidden this way.
- ❌ JS-only injection — verifier reads static HTML, no JS execution.
- ❌ `rel="nofollow"` — must be `rel="me"` (bilateral token).
- ❌ Link on a subpage (e.g. `/verification`) — must be on the homepage the bio claims.
- ❌ Hidden inside a comment or template fragment that gets stripped.

## Verifier quirks that work

- ✅ `<link rel="me">` in `<head>`
- ✅ `<a rel="me">` anywhere in body (even off-screen via CSS positioning)
- ✅ Both forms at once (redundant but safer)
- ✅ `aria-hidden="true"` and `tabindex="-1"` (don't break a11y)

## Reference — Mastodon's own docs

The user-facing verification instructions typically say:

> "Copy the HTML code below and paste into the header of your website:
> `<a rel="me" href="https://mastodon.social/@<user>">Mastodon</a>`"

Mastodon's docs also accept:

- `<link rel="me">` in `<head>` — https://docs.joinmastodon.org/user/profile/#verification
- `<a rel="me">` in body — same page

Both forms satisfy the verifier.
