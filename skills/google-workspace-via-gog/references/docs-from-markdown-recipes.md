# /gog — verified Drive/Docs recipes (2026-08-22)

This reference condenses the working recipes the in-play skill's pitfalls
refer to. Every recipe here was exercised end-to-end on macOS 15.5 with
gog v0.10.0 (Homebrew `openclaw/tap/gogcli`) and the OAuth bucket
`jleechan@gmail.com`. Use these as the pattern; substitute the values
for your context.

## Account decision (read FIRST)

`gog auth list` returns the buckets you have. Today there are two on
this machine and they serve **different products**:

| email                          | client  | auth        | use for                            |
| ------------------------------ | ------- | ----------- | ---------------------------------- |
| `jleechan@gmail.com`           | default | oauth       | Drive / Docs / Slides / Sheets     |
| `jleechan@worldarchitect.ai`   | (empty) | service-account (firebase-adminsdk `sa-*.json`) — masks Drive/Docs | GCP / Firestore only |

If a `sa-*.json` got dropped into `~/Library/Application Support/gogcli/`
your OAuth path is **silently masked**: `gog auth status` reports
`auth_preferred: service_account` and every Drive/Docs call returns
`401 unauthorized_client` even though `credentials.json` holds a
perfectly valid OAuth `refresh_token`. The fix isn't re-login — it's
removing the SA JSON from gog's path if you don't actually need
impersonation.

**Default to `--account jleechan@gmail.com`** for every Drive/Docs
recipe below.

## Recipe 1 — Create a Google Doc from a markdown file (clean body, single doc ID)

Output: a single Drive doc with the markdown body formatted as Google
Docs (bold, headings, lists) and YAML frontmatter stripped. **One** doc
ID for the lifetime of the canonical.

```bash
unset GOG_KEYRING_BACKEND                   # CRITICAL on Mac. Linux ~/.bashrc leaks this env.
ACCT=jleechan@gmail.com

# 0. Strip YAML frontmatter from the canonical markdown source.
#    `gog docs create` imports the file as-is and the YAML shows as a paragraph.
sed '1,/^---$/d; /^---$/d' ~/llm_wiki/wiki/sources/quiet-war-slim.md > /tmp/qw-doc-import.md

# 1. Create the doc with the parent folder set.
NEW_ID=$(gog --account "$ACCT" --client default docs create "Quiet War — Campaign Bible" \
    --parent 1ZLC7LXj2goOP30e395647XO1PChGhDgO \
    --file /tmp/qw-doc-import.md \
    --no-input --json 2>&1 \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['file']['id'])")

# 2. Rewrite the body IN PLACE with markdown→Google-Docs formatting.
gog --account "$ACCT" --client default docs write "$NEW_ID" \
    --file /tmp/qw-doc-import.md --replace --markdown --no-input 2>&1
# Output:  documentId=<NEW_ID>  written=<bytes>  mode=replaced (markdown converted)

# 3. Verify content / canon rules.
gog --account "$ACCT" --client default docs cat "$NEW_ID" 2>&1 \
    | grep -ciE "Darius|Valerius|Sariel|CANON-CORRECTION"

# 4. Verify the doc lives where you think it does.
#    (drive ls is ROOT-only by default — never use it to verify subfolder docs.)
gog --account "$ACCT" --client default drive search "name = 'Quiet War'" --max 5 --json 2>&1 \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
for f in d.get('files',[]):
    if f.get('id') == '$NEW_ID':
        print('id:    ', f['id'])
        print('name:  ', f['name'])
        print('parents:', f.get('parents'))
        print('size:  ', f.get('size'))
        print('link:  ', f.get('webViewLink'))
"
```

**Why this is two steps (not `docs create --markdown`):** v0.10.0 has
`--markdown` on `docs write` and `docs insert` but **not** on
`docs create`. The first `--file` pass imports the file as-is; the
second `--replace --markdown` pass rewrites in place. A single-step
attempt `gog docs create --file foo.md --markdown` returns
`unknown flag --markdown` and the body keeps the YAML literal.

**Why this is two steps (not `drive delete + docs create`):** in v0.10.0
`docs write --replace --markdown` IS an in-place overwrite — it
preserves the doc ID. Delete-then-recreate produces a **new** doc ID
every time, which means URL links, Drive share links, and the doc's
own canonical reference all break.

## Recipe 2 — Verify a doc lives in a specific Drive folder

```bash
ACCT=jleechan@gmail.com
DOC_ID="11oBduyCd6HsydnWi6YwxDHrwDm4L1VQFCGe0hD8mp04"   # the Quiet War doc

gog --account "$ACCT" --client default drive search "name = 'Quiet War'" --max 5 --json 2>&1 \
  | python3 -c "
import json,sys
d = json.load(sys.stdin)
for f in d.get('files', []):
    if f.get('id') == '$DOC_ID':
        print('PARENTS:', f.get('parents'))
"
```

`gog drive ls` is **ROOT-only by default** and silently misses any
doc created with `--parent <folderId>`. Always verify with
`drive search` (full-text path on name + grep on file ID), or pass
`--parent <folderId>` to `drive ls` if you want the recursive path.

The Drive folder-quote search `'1ZLC...xyz' in parents` returns 0
hits even when the doc is in that folder — Drive API quirk on shared
folders without per-owner permissions. Use the title-search path
shown above; this is reliable.

## Recipe 3 — Sanity-check that a doc is what you think it is (before delete)

**Rule:** before `gog drive delete --force <id>`, you must verify
*that specific doc ID* still exists in the account, by name or by
content. The chain `drive ls → 0 hits → drive delete --force` has
killed at least one live doc this way. The right chain is:

```bash
ACCT=jleechan@gmail.com
DOC_ID="<id-you-think-is-stale-or-replaced>"

# Step 1: Confirm the doc ID shows up under the right name.
COUNT=$(gog --account "$ACCT" --client default drive search "name = '<exact title>'" --max 5 --json 2>&1 \
  | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(sum(1 for f in d.get('files',[]) if f.get('id') == '$DOC_ID'))
")
echo "matches: $COUNT (want >=1)"

# Step 2: Confirm body content matches what you expect.
gog --account "$ACCT" --client default docs cat "$DOC_ID" 2>&1 \
  | head -3

# Step 3: Now AND ONLY NOW, delete.
gog --account "$ACCT" --client default drive delete --force "$DOC_ID" --no-input 2>&1
```

If step 1 says 0 matches, **the doc ID is wrong or the doc is in
the wrong account** — do NOT guess another ID and `drive delete`
that one. Find the real ID from step 3 metadata instead.

## Recipe 4 — Read back a doc's first N lines for spot-check

```bash
ACCT=jleechan@gmail.com
DOC_ID="11oBduyCd6HsydnWi6YwxDHrwDm4L1VQFCGe0hD8mp04"

gog --account "$ACCT" --client default docs cat "$DOC_ID" 2>&1 | head -25
```

Body comes out as plain text (no markdown, no formatting). Looks like
the source markdown minus the bold/italics. YAML frontmatter is gone
if Recipe 1 was run.

## Recipe 5 — Diagnose 401 on every gog Drive/Docs call

```bash
# 1. Are you on the OAuth bucket or the service-account bucket?
gog auth list

# Expected healthy state:
#   jleechan@gmail.com          default          oauth
#   jleechan@worldarchitect.ai  (empty)          service-account

# 2. If auth_preferred is service_account, gog is using SA for ALL calls.
gog auth status | grep auth_preferred

# 3. Keychain has a working access_token?
security find-generic-password -s gogcli -a "token:default:jleechan@gmail.com" 2>&1
# Look for "mdat" (modification date) within the past hour → fresh, use it.

# 4. credentials.json has a refresh_token?
test -s ~/Library/Application\ Support/gogcli/credentials.json && python3 -c "
import json
d=json.load(open('${HOME}/Library/Application Support/gogcli/credentials.json'))
print('refresh_token present:', bool(d.get('refresh_token')))
print('scopes:', d.get('scopes'))
" || echo "credentials.json empty or missing"
```

Decision tree:

- `auth_preferred: service_account` → SA is masking the OAuth path.
  If you need Drive/Docs, either delete the SA JSON or use the OAuth
  re-consent flow.
- `auth_preferred: oauth` + `refresh_token present` + keychain entry
  recent + still 401 → the refresh_token itself is revoked
  (`invalid_grant`). Run the OAuth re-consent flow.
- Keychain empty but credentials.json valid → first-time gog launch
  on this Mac session; the next `gog docs cat` will trigger a
  keychain-prompt popup.

## The 5 hard-fail pitfalls (one-line recap)

1. Don't run `gog auth credentials set` without backing up
   `credentials.json` — it strips the `refresh_token`.
2. Don't trust `gog drive ls` to find a doc in a subfolder — use
   `drive search` with the exact title.
3. Don't `drive delete --force` based on a `drive ls` zero-hit chain —
   the doc probably exists, just in a subfolder.
4. Don't use `--account jleechan@worldarchitect.ai` for Drive/Docs —
   it's a firebase-adminsdk SA bucket that 401s on every Drive call.
5. Don't assume `gog docs create --markdown` exists — v0.10.0 only
   has `--markdown` on `docs write` / `docs insert`. Two-step
   create-then-write is the path.

## Token canonical location (macOS)

The OAuth access_token lives at the macOS Keychain entry
`gogcli / token:default:<email>`. Verified with:

```bash
security find-generic-password -s gogcli -a "token:default:jleechan@gmail.com" 2>&1
```

If `credentials.json`'s `refresh_token` is wiped but this keychain
entry is fresh (mdat within the last hour), `gog` keeps working on
the cached access_token. The refresh_token regenerates silently the
next time gog needs it — or fails silently, which is why some 401s
only show up after a long idle period.

## Auth recovery — full flow

When you've actually lost both `credentials.json` and keychain,
fall back to the OAuth re-consent flow at the bottom of
`SKILL.md`. The same recipe works as a *first-time per-machine*
OAuth bootstrap.

## Revision marker

`GOG_DOCS_RECIPES_R1` — written 2026-08-22 after the Quiet War
doc-swap incident. Update when:
- gog major version changes (verify flags via `gog <cmd> --help`)
- a brand-new recipe pattern lands (e.g. slides / sheets / forms)
- a gog OAuth scope / SA conflict scenario emerges that's not
  covered above
