# Avatar slot contract — filename flow Drive → scene prose → next-stage render

Documented the avatar-file-name-flow that emerged from Step 4 of the avatar-scene-gen pipeline (2026-08-14). Use this reference when the umbrella `wa-scene-rewrite` skill points you at the avatar-slot detail.

## The pipeline

```
   Drive (Google)
       │  syncs to
       ▼
   ~/llm_wiki/raw/assets/avatars/
       │  dedup → drive_avatars_deduped.jsonl (132 unique)
       │  format: <sha256[:8]>_<slug>.<ext>
       ▼
   03_xref_characters.json
       │  per character, optional {"character": ..., "drive_filename": ..., "sha256_prefix": ...}
       ▼
   Scene prompt (wa-scene-rewrite input)
       │  includes literal filenames for matched chars; "campaign-avatar-default" placeholder for unmatched
       ▼
   LLM rewrite produces scene prose with INLINE filenames
       │  e.g. "...the avatar file ca197e7b_ains_shy_lich's robe as she moved..."
       ▼
   /tmp/avatar_scene_gen/scenes/<slug>/<model>.md
       │  Step 5 reads the prose
       ▼
   Render pipeline grep's the prose for the filename, looks up the file
   in ~/llm_wiki/raw/assets/avatars/, replaces the slot with image data
```

## Three rules

### Rule 1: When the cross-ref matches, use the literal filename INLINE in prose

The LLM must include the exact `<sha>_<slug>.<ext>` substring as a recognizable token in the rewritten scene. For `ca197e7b_ains_shy_lich`, this looks like:

> "...the avatar file ca197e7b_ains_shy_lich's robe caught the noon sun..."

NOT in a sidecar. NOT in meta.json. IN the prose body, so the next stage can do a textual `grep` on it.

The format on disk is `<sha256[:8]>_<safe_filename>` (the safe filename is the original Google Drive name slugified to ASCII + underscores + dots). Example real entries:

- `ca197e7b_ains_shy_lich` (no extension in the dedup output because it kept a sentinel with no dot)
- `c1338ce4_valeria_iseki`
- `7b53027c_visenya_v2.jpg`
- `20ce72cb_203a2070-9aaa-4351-a696-1e12c1aaf436.png`

The extension on disk and the extension in the dedup JSON may differ — the file-system name from `ls` is canonical for the slot. Verify with `ls ~/llm_wiki/raw/assets/avatars/<prefix>*` before writing the prose.

### Rule 2: When no Drive match exists, use the literal placeholder `campaign-avatar-default`

Do NOT fabricate a Drive filename. Do NOT omit the slot. The placeholder `campaign-avatar-default` is recognized by the next stage as "use the campaign-level avatar URL." Examples from 2026-08-14 (Tenebria and Supergirl had no Drive match):

> "...campaign-avatar-default moved ahead, charcoal robes dragging..."

The next stage's slot-filler:
```python
import re
matches = re.findall(r'([\w]+_[\w_]+|campaign-avatar-default)', prose)
for m in matches:
    if m == 'campaign-avatar-default':
        # Fill with campaign-level avatar URL from game state
        pass
    elif m.startswith(('ca197e7b_', 'c1338ce4_', '7b53027c_')):
        # Fill with on-disk file path
        pass
```

### Rule 3: Every scene records `avatars_used` in meta.json

The meta.json contract requires:

```json
"avatars_used": ["ca197e7b_ains_shy_lich"]
```

For a scene with multiple matched characters (Ains + Sebas + Enri Emmot, say), the array would be `["ca197e7b_ains_shy_lich", ...]`. The prose should reference EACH one by literal filename when they're in the visible beat.

For scenes that have all-unmatched characters, `avatars_used` is `[]` and the prose uses `campaign-avatar-default`.

## Why inline-in-prose (not sidecar)

Three reasons, learned from pipeline design:

1. **Multi-model sibling workers (Grok + Gemini) don't have to share state.** Each writes a separate `<model>.md` referencing the slots the same way; Step 5's render step works identically on either.
2. **The prose IS the contract.** If the LLM produces text that mentions the character but not the slot, the next stage can't render — and the prose is then ambiguous. Putting the filename INLINE forces the LLM to make the slot visible as part of the description.
3. **Audit-friendly.** A reader of the prose can `grep` for `ca197e7b` and immediately see what avatar was intended. Sidecars would need a parallel read.

## Edge cases

### The LLM rephrases the filename

Grok-4.3 occasionally rewrites filenames in unexpected ways:

- Drops the underscore (e.g. "ca197e7bainsshylich") — invalid slot
- Adds a trailing period that wasn't there
- Pluralizes (e.g. "ca197e7b_ains_shy_lich's") — valid (possessive inflection is fine; the bash unzip sees `ca197e7b_ains_shy_lich` as a prefix)

**Fix:** verify each scene's prose with `grep -oE '[a-f0-9]{8}_[a-zA-Z0-9_]+(\.[a-z]{2,4})?' scenes/<slug>/grok.md` after the rewrite. Any token that doesn't match a real file should be re-prompted in Round 2 as a "fix the avatar filename reference" pass.

### The LLM adds a NEW filename that doesn't exist

Same fix — flag and re-prompt. Do not save a meta.json that references a non-existent file.

### Multiple characters with the same avatar (e.g. Enri Emmot = same drive image as Ains)

`03_xref_characters.json` only carries match info for the PC, not for every NPC. The Drive dedup runs on sha256, so a physically-identical image gets one entry. The LLM can still reference it inline for both characters — the next stage's renderer just uses the same image twice. No additional metadata needed.

## Filename shape reference

Looking at the canonical set in `~/llm_wiki/raw/assets/avatars/`:

```
20ce72cb_203a2070-9aaa-4351-a696-1e12c1aaf436.png
ca197e7b_ains_shy_lich
c1338ce4_valeria_iseki
7b53027c_visenya_v2.jpg
2ad65d18_swtor_alexiel_screencap
```

The 8-char hex prefix is the sha256 first 8. The rest is the original Drive filename with spaces/dots mapped to underscores. The trailing extension may or may not match what's on disk — when in doubt, `ls ~/llm_wiki/raw/assets/avatars/<prefix>*` shows the truth.
