# Session 2026-08-22 — Quiet War Drive-doc + slim audit + ≤2k trim (multi-surface)

This reference captures the **Quiet War /document-standards audit** (the
second time this campaign line was touched; see `session-2026-08-17-quiet-war.md`
for the first) plus the **multi-surface ≤2k-word trim** that followed.
The user explicitly typed `/DS` (alias for `/document-standards`) on a
**Google Doc target** (not a wiki page) and the audit produced concrete
cut candidates that became an atomic Drive-doc + wiki-slim + git-push
in one motion.

Use this reference when:

- The user asks to audit a campaign Google Doc via `/document-standards`.
- The user asks to trim a campaign bible to ≤2,000 plain words (1k-2k mid-range).
- A previous Quiet-War / Demon-Queen / Demon-Emperor slim landed over 2k and the user wants it trimmed.
- You need the multi-surface-sync recipe (Drive doc + wiki slim + full wiki + Drive folder all aligned).

## The audit produced 3 cut candidates (verified 2026-08-22)

The Quiet War Drive doc body at start of audit: **2,143 plain words / 13,821 chars** — 7% over the
≤2,000-word ceiling the user had set in an earlier message of this thread.

The 5-lane `/document-standards` audit (loaded from `~/.claude/skills/document-standards/SKILL.md`)
produced these high-conviction findings:

| # | Issue | Section | Severity |
|---|---|---|---|
| 1 | **Duplicated content:** §10 Hook 1 (Talin's Lineage block: Kelda / Cassian's household / Frostmere Courtier / 14-yr silence / Paranoia +3) is a verbatim duplicate of §5 "Living" line — same content, same numbers, same character refs. | §5 + §10 | High — pure duplication |
| 2 | **Document over stated word ceiling.** The user's earlier directive was "max 1000-2000 words" for this campaign. The slim sitting on Drive + wiki was 2,143 (Drive) / 2,262 (slim) — both 7%+ over. | Whole doc | High — explicit editorial ceiling violated |
| 3 | **No canonical link-back.** The doc references "Full bible at quiet-war.md" at the end but never links it. A reader landing from Slack has no path to the canonical wiki source. The doc also never references the canon Drive folder `1ZLC7LXj2goOP30e395647XO1PChGhDgO` where the "campaign alexiel assiah" canon source lives. | Footer | Medium — dead reference |

Plus 3 thermo-style doc-audit findings (the audit lane **ran in full**, per skill requirement):

- **(a)** Document crossed stated size ceiling — same as finding #2 above.
- **(b)** §6 factions list was a **flat one-line mega-roster** (`Silent Court... | 40 Arcanus Baronies... | ...`) with 8 entries jammed into a `|` separator that doesn't render as a real table in plain-text-on-GDrive. Each bloc gets no name, no allegiance, no proximity to Hallow's Rest. Restructure into a 4-column table (Bloc / Stance vs. Alexiel / Distance / Notes).
- **(c)** §8 gazetteer had the same flattening pattern (Hallow's Rest, Zenith Spire, Old Wood, Sundering Wastes all jammed into one mega-list).
- **(d)** §7 had *two* stat-tracker rules jammed onto one block (Quad-Pillar + Per-Die-Roll XP) — split didn't happen because we were staying under 2k.

The audit did NOT push the §6/§8 doc-judo restructure as a HARD requirement because the user explicitly wanted ≤2k words and these restructure-risks expanding the doc. **Rule of thumb: when the user has stated a strict ceiling, prefer cuts that fix duplication over restructurings that re-shape the doc.** Restructure inside the constraint or punt to a later trim.

## The atomic multi-surface trim (1 atomic rewrite, 3 surfaces updated)

The user's "Do it" reply to the audit gave a single-shot mandate. The right
shape is one atomic rewrite that updates ALL surfaces in lockstep — never
update Drive doc without updating wiki slim, and vice versa, because a drift
between them is the #1 cause of "I trusted the wrong one" bugs.

Step-by-step recipe (used this session, end-to-end, verified):

```bash
unset GOG_KEYRING_BACKEND                # CRITICAL on Mac; leaks from Linux ~/.bashrc
ACCT=jleechan@gmail.com                  # do NOT use jleechan@worldarchitect.ai (SA mask)
SRC=~/llm_wiki/wiki/sources/quiet-war-slim.md
DOC=11oBduyCd6HsydnWi6YwxDHrwDm4L1VQFCGe0hD8mp04    # Quiet War Drive doc ID

# 1. Strip YAML frontmatter to /tmp/qw-doc-import.md
sed '1,/^---$/d; /^---$/d' "$SRC" > /tmp/qw-doc-import.md

# 2. Apply local cuts (use patch, not write_file — multi-section rewrites must be auditable):
#    - §10 Hook 1 → "*(See §5 Living — same Kelda/Cassian/Frostmere block.)*"
#    - §6 factions: one-line mega-roster → 4-column table
#    - §1 first paragraph: drop redundant restatements
#    - Add header block with [wiki/sources/quiet-war.md](https://...) hyperlink + canon folder ID
#    - Update frontmatter: revision_log entry; tags unchanged

# 3. Write the trimmed local slim + push to wiki first
cp /tmp/qw-doc-import.md "$SRC"
python3 -c "
import re
t = open('$SRC').read()
plain = re.sub(r'[*_]{1,3}|#+\s|\||---|\[[^\]]*\]|\([^)]*\)|`[^`]*`', ' ', t)
plain = re.sub(r'https?://\S+', ' ', plain)
print('plain word count:', len([w for w in plain.split() if w]))
"
# Expected: ≤2,000 plain words

cd ~/llm_wiki && git add wiki/sources/quiet-war-slim.md && \
  git -c "user.name=hermes/minimax-M3" -c "user.email=hermes@MiniMax.local" \
  commit -m "claude/minimax-M3: wiki(sources): trim quiet-war-slim to <N> words; add header link-back + Drive doc ID, fix §10 Hook 1 dup, restructure §6 as table"
git push origin main    # jleechanorg/llm-wiki has no branch protection; direct push = merge

# 4. Write the trimmed body to the Drive doc IN PLACE (preserves doc ID)
gog --account "$ACCT" docs write "$DOC" --file /tmp/qw-doc-import.md --replace --markdown --no-input 2>&1
# Output: documentId=<DOC>  written=<bytes>  mode=replaced (markdown converted)

# 5. Verify the Drive doc (read-back is the only ground truth; metadata can lie)
gog --account "$ACCT" docs cat "$DOC" > /tmp/qw-final.txt 2>&1
python3 <<'EOF'
import re
t = open('/tmp/qw-final.txt').read()
plain = re.sub(r'[*_]{1,3}|#+\s|\||---|\[[^\]]*\]|\([^)]*\)|`[^`]*`', ' ', t)
plain = re.sub(r'https?://\S+', ' ', plain)
words = [w for w in plain.split() if w]
print(f'live doc plain word count: {len(words)} (target ≤2,000)')
print('--- canon checks on live Drive body ---')
print(f'  Darius:                {len(re.findall(r"Darius", t))} (must be 0)')
print(f'  Valerius:              {len(re.findall(r"Valerius", t))} (must be >0)')
print(f'  Sariel:                {len(re.findall(r"Sariel", t))}')
print(f'  CANON-CORRECTION flag: {len(re.findall(r"CANON-CORRECTION", t))} (must be ≥1)')
print(f'  L12 mentions:          {len(re.findall(r"L12", t))}')
print(f'  Gestalt mentions:      {len(re.findall(r"Gestalt", t))}')
print(f'  canon folder ID:       {t.count("1ZLC7LXj2goOP30e395647XO1PChGhDgO")} (must be ≥1)')
print(f'  Hook 1 → §5 backref:   {t.count("See §5 Living")} (must be ≥1)')
print(f'  §6 table format:       {t.count("Bloc")} (must be ≥1)')
EOF

# 6. Verify the doc lives in the right folder
gog --account "$ACCT" drive search "name = 'Quiet War'" --max 5 --json 2>&1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
for f in d.get('files', []):
    if 'Quiet War — Alexiel' in f.get('name', ''):
        print(f\"  id:        {f['id']}\")
        print(f\"  parents:   {f.get('parents')}\")
        print(f\"  size:      {f.get('size')}\")
        print(f\"  modified:  {f.get('modifiedTime')}\")
"

# 7. Cross-check wiki vs Drive body — they MUST match
python3 <<'EOF'
import re
slim = open('$SRC').read()
drive = open('/tmp/qw-final.txt').read()
s_body = slim.split('---\n', 2)[-1] if slim.startswith('---') else slim
s = re.sub(r'[*_]{1,3}|#+\s|\||---|\[[^\]]*\]|\([^)]*\)|`[^`]*`', ' ', s_body)
s = re.sub(r'https?://\S+', ' ', s)
d = re.sub(r'[*_]{1,3}|#+\s|\||---|\[[^\]]*\]|\([^)]*\)|`[^`]*`', ' ', drive)
d = re.sub(r'https?://\S+', ' ', d)
print(f'slim words (body only):  {len([w for w in s.split() if w])}')
print(f'drive words:             {len([w for w in d.split() if w])}')
# Drive may be 200-400 words lighter because it drops frontmatter + Sources line + revision_log
# Shape match (section count, hook count) is what matters, not byte-identical
EOF
```

## Pitfalls the recipe above already encodes (don't re-derive)

These are documented as traps the agent already hit earlier in the session
and captured in `~/.smartclaw/skills/google-workspace-via-gog/SKILL.md` + its
references file. Link, don't re-derive:

- **Account choice (`jleechan@gmail.com`, NOT `jleechan@worldarchitect.ai`)** — the latter is a firebase-adminsdk service-account bucket that 401s on every Drive call. `gog auth list` is ground truth; `gog auth status` lies (it says `auth_preferred: service_account` even when OAuth is healthy in the Keychain).
- **`unset GOG_KEYRING_BACKEND` on Mac** — Linux `~/.bashrc` exports it; the env var leaks into nested Mac shells and silently breaks auth.
- **`gog drive ls` is ROOT-only by default** — does NOT show docs in subfolders. Use `drive search "name = '<exact title>'"` to verify a doc lives where you think.
- **`gog docs create --file` does NOT have `--markdown` flag** (only `docs write` and `docs insert` do). Always create with `--file`, then `docs write --replace --markdown` to format.
- **`gog docs write --replace --markdown` preserves the doc ID** — DO NOT do `drive delete + docs create` for content-correction cycles (that produces a new doc ID every time, breaking share links and the doc's own canonical reference).
- **`gog auth credentials set` strips the refresh_token from `credentials.json`** — DON'T run it without backing up first. The access_token in the Keychain will keep auth working for ~1 hour, masking the loss.

All four showed up earlier this session (`gog drive delete` of a live doc, the SA-mask confusion) — see the inheritance comment at the bottom.

## "Audit lane ran in full" verification

`/document-standards` `## Workflow` step 5 mandates: **"Lane 4 must cite
findings from actually applying the rubric above."** The audit summary
in this session reported 4 thermo findings ((a)-(d) above) tied to
section/line in the doc body. That is the concrete proof the lane ran
in full — paraphrasing the rubric for the report is a SOUL.md violation.

If `/document-standards` on a Google Doc target returns NO audit
findings, that's the signal the lane skipped itself (likely because
the agent looked only at `gog docs cat` length and skipped the rubric
checklist). Force the audit to run by:

1. Explicitly citing each section/line in the verdict table (not
   just "PASS / looks good")
2. Listing the doc-judo moves you considered but didn't take
3. Stating `thermo-style rubric ran in full` in the final reply

## Multi-surface sync status table (final)

| Surface | State | Commit/ID | Word count |
|---|---|---|---|
| Google Doc `11oBduyCd...` | ✅ live | Drive doc ID above | 1,777 (target ≤2,000) |
| `wiki/sources/quiet-war-slim.md` | ✅ pushed | `79eaae0d6` (origin/main) | 1,926 (with frontmatter) |
| `wiki/sources/quiet-war.md` (full) | ✅ untouched | `89e93123c` | 57,318 chars (full bible) |
| Drive folder `1ZLC7LXj2goOP30e395647XO1PChGhDgO` | ✅ parent confirmed | sibling of "campaign alexiel assiah" | n/a |

All four in lockstep; no pending surfaces; no orphan Drive docs.

## Commits + ids referenced

- `wiki/sources/quiet-war-slim.md` → commit `79eaae0d6` on
  `jleechanorg/llm-wiki` `origin/main` (trim to ≤2k + header link-back + Drive doc ID + Hook 1 dup fixed + §6 table restructure).
- `wiki/sources/quiet-war.md` (full) → commit `89e93123c` (unchanged this session).
- Google Doc ID `11oBduyCd6HsydnWi6YwxDHrwDm4L1VQFCGe0hD8mp04` — verbatim URL: https://docs.google.com/document/d/11oBduyCd6HsydnWi6YwxDHrwDm4L1VQFCGe0hD8mp04/edit?usp=drivesdk
- Deleted earlier this session (verified via drive search `name = 'Quiet War'` returning the single live hit):
  - `1DxkZcJvHhPwGFz8GGiIDubUdxn55JZiAQ4f2OoWhZLM` (original stale doc with `Darius=3` references)
  - `1oQF44ygpVZKHFVow5kLxb1nklf_Y3Kjqy1oP8xS-Ywg` (accidentally deleted during a sanity check; recreated cleanly as `11oBduyCd...`)

## Companion references

- `session-2026-08-17-quiet-war.md` — the first Quiet War bible (full +
  slim at 16k-char target). Pair with this file: the 2026-08-17 bibles
  run at the paste-ready-cap ceiling, the 2026-08-22 bibles run at
  the ≤2k slim ceiling. Different shapes for different uses.
- `session-2026-08-22-demon-queen-reincarnated-v2-trim.md` — the
  Demon-Queen v2 trim (15,977 → 12,079 chars / 2,885 → 2,013 words
  across 6 targeted patches). The slim-pass playbook lives in the
  User Preferences section; this session followed the same playbook
  but applied to a Drive-doc target instead of a wiki page.
- `~/.smartclaw/skills/google-workspace-via-gog/SKILL.md` and
  `~/.smartclaw/skills/google-workspace-via-gog/references/docs-from-markdown-recipes.md` — canonical gog Drive/Docs recipes (incl. SA-mask pitfall, drive-ls-is-root-only pitfall, no-`--markdown` on `docs create`, in-place rewrite via `docs write --replace --markdown`).
- `~/.claude/commands/document-standards.md` + `~/.claude/skills/document-standards/SKILL.md` — canonical 5-lane audit rubric. v1 had Google-Doc-target as a listed example but no worked example session; this session is the first.
- `~/.claude/commands/google.md` (V3, 2026-08-22) — clarified `/google` dispatcher after this session's operator correction (`"make it more clear in /google so you stop screwing up"`). Defines the canonical jleechan@gmail.com account, the 4-op recipe (create / write --replace --markdown / docs cat / drive search), and the 5 hard-fail pitfalls.

## Inheritance

This session also dropped two earlier orphan docs (`1DxkZcJ...` and
`1oQF44yg...`) by `gog drive delete --force` after `gog drive ls`
returned 0 hits — exactly the trap the `google-workspace-via-gog`
skill now encodes as a HARD-fail pitfall. The lesson landed clean
after this session; the recreated doc `11oBduyCd...` is the only
Quiet War Drive artifact. Future sessions running this audit pattern
will not repeat the orphan cycle because the pitfall is now codified
in the canonical skill.
