# Grok-4.3 iterative scene rewriting — detailed patterns

Session-derived playbook from the 5-scene avatar-scene-gen pipeline run (2026-08-14, sibling Grok worker). Use this reference when rewriting scenes with Grok-4.3 specifically; the umbrella `wa-scene-rewrite` covers the general multi-LLM pattern.

## Why Grok-4.3 needs iterative rounds

Grok-4.3 self-caps completion length even when `max_tokens=3000` ceiling is far from hit. With an explicit "600-900 word" floor and good instructions, the model regularly outputs 300-600 words — short by 50-300. This is not a token-budget issue; it's a learned style preference toward tighter prose.

Three calibrations are needed in the system message to coax longer output:

1. **Explicit length reinforcement** — repeat the floor verbatim in the system prompt AND the user prompt.
2. **Rejection-framing** — "under-length output is rejected" language actually works. Grok treats it as a constraint.
3. **High `max_tokens`** — leave 3000 even for a 700-900 word target. Letting the model see headroom prevents premature stop.

## The 4-round regen table

| Round | Mode | When | Prompt shape | Risk |
|---|---|---|---|---|
| 1 | Initial | Always start here | System = `cinematic rewriter + length instruction + output-only prose`; User = `Tone hint + extras + entry blob` | None (only run) |
| 2 | Continuation-extension | Word count < 600 | System = `Cinematic continuation: do NOT paraphrase, just continue`; User = `Extend by N words. Same voice. EXISTING SCENE → END. EXISTING SCENE` | Grok might paraphrase instead of extending (drop word count to 200-400) — fix is to add "do NOT rewrite any existing sentence" to the user prompt |
| 3 | Trim | Word count > 940 | System = `Cinematic editor`; User = `MODE: TRIM. Current wc=X target=Y. Cut redundant atmosphere. Output FULL scene.` | None — trim mode is reliable |
| 4 | Pinpoint precision | Word count is OFF by 5-50 words | Same as Round 2/3 but with explicit "add/remove ONLY N words in the parenthetical aside" guidance | Cost — adds latency without value if the prose already passes quality |

For the canonical pipeline, Rounds 1 + 2 (or 1 + 3) reliably land 4 of 5 scenes in [600, 900]. Round 4 is needed only when the model hands back a 596-word piece that's 4 words under and quality-wise perfect.

## Tone templates per IP

### Overlord isekai

```
Rewrite this scene for a 600-900 word cinematic, Overlord isekai tone —
third-person, dark-comedic, preserving named NPCs (Ains, Sebas, Enri
Emmot, Captain Nigun, the Vanguard, Gazef Stronoff) verbatim.
Cognitive dissonance between a god-queen lich calling the attack
'very mean' and her elite knights radiating lethal intent is the hook.
Reference avatar file '<sha>_<slug>' as the visible character for
Ains (named with that exact filename).
```

### Fantasy Spellblade isekai (Valeria)

```
Rewrite this scene for a 600-900 word dramatic isekai combat beat —
preserve dawn light, 'geometric kill-box,' and obsidian walls 'in
ghostly shifting hues.' Third-person, tense, named NPCs verbatim.
Reference avatar file '<sha>_<slug>' as the visible character for
Valeria.
```

### Star Wars MMO isekai (Tenebria)

```
Rewrite this scene for a 600-900 word tense-espionage beat —
claustrophobic, third-person. Preserve the rust-scented condensation,
unshielded power cables, stagnant coolant slurry, and the named
Horuset jamming arrays. Named NPCs verbatim. No matching Drive
avatar — write the visible-character slot as 'campaign-avatar-default'
rather than fabricating one.
```

### ASOIAF (Visenya)

```
Rewrite this scene for a 600-900 word dark-comedy political-drama
beat — third-person, preserving the geometric table staging (Maekar,
Baelor, Hand, terrified brothers) and the cute-voice-on-ruthless-shift
contrast. Candles burn 'like cooling blood.' Named NPCs verbatim.
Reference avatar file '<filename>' as the visible character for
Visenya.
```

### DC superheroes (Supergirl)

```
Rewrite this scene for a 600-900 word iconic-NPC-banter
dramatic-reveal beat — third-person. Preserve the marble annexe,
lead-lined air, and the Lex-vs-Supergirl banter. Close on her quiet
apology: '16 and tired of living for others.' Named NPCs verbatim.
No matching Drive avatar — write the visible-character slot as
'campaign-avatar-default' rather than fabricating one.
```

## Continuation-extension templates

When Round 1 lands under 600 words, use one of these depending on what's missing:

**Add missing NPC beats (Tenebria scenario):**
```
Add: deeper traversal of the uncharted drainage conduits, the moment
the Ghost Key meets the terminal's resistance, the blood-magic
feedback that burns Tenebria's palm, Jaxen's whispered plead, and the
instant the Data Silence signal pierces the jamming static — with
whatever Tenebria senses waiting on the other end. Keep
'campaign-avatar-default' as the visible-character placeholder.
```

**Add environmental/character depth (Overlord scenario):**
```
Add: Ains's slow inner monologue while binding Captain Nigun, Sebas
Tian covering the village evacuation, the moment an Imperial Arcane
Eye's recording wrongly tags Ains as 'saintly envoy.' Continue in
the same voice (third-person, Overlord isekai). Don't repeat
existing prose; write 150-200 fresh words.
```

**Add tactical/visual detail (Valeria scenario):**
```
Add: the acoustic behavior of the geometric kill-box, walking the
vertical gravity-well under Greater Invisibility (blood-rush,
vertigo, the Ironspire mages' silhouette above), Valeria's level-up
'7' flash, and one Senior Runic Mage's final plea before being
bound.
```

**Always include at top:**
```
MODE: EXTEND. Current word count is {X}; target {Y}.
{IP-specific hint as above}
--- EXISTING SCENE ---
{prior grok.md}
--- END EXISTING SCENE ---
```

## Trim template

For scenes that ran over 940 words:

```
MODE: TRIM. Current word count is {X}; target {Y}.
Tighten the scene by ~N words. Cut any redundant atmosphere
descriptions and any single sentence you can spare; preserve the
{Maekar dialog / Aerion interception / candles-quote}.
Output the FULL revised scene with the cuts.
--- EXISTING SCENE ---
{prior grok.md}
--- END EXISTING SCENE ---
```

## Backup-rotation pattern (canonical)

```python
# Before writing a new grok.md, promote the current one
cur = scene_dir / 'grok.md'
if cur.exists():
    next_idx = max([0] + [
        int(m.group(1)) for p in scene_dir.glob('grok.v*.md')
        for m in [re.match(r'grok\.v(\d+)\.md', p.name)] if m
    ]) + 1
    shutil.copy(cur, scene_dir / f'grok.v{next_idx}.md')

cur.write_text(new_prose)
```

This produces `grok.v1.md` = round-1, `grok.v2.md` = round-2, `grok.v3.md` = round-3 (or `grok.v4.md` for round 4). The latest `grok.md` is always canonical; backups are immutable history.

## Regression guard

Always print the word count delta after writing the new `grok.md`:

```python
new_words = len(new_text.split())
old_words = len(prior_text.split()) if 'prior_text' in dir() else 0
delta = new_words - old_words
if delta < -200:
    print(f"⚠ REGRESSION: {old_words} → {new_words} (drop {abs(delta)} words)")
    # Roll back: shutil.copy(scene_dir / 'grok.v3.md', scene_dir / 'grok.md')
```

A drop of >200 words in a "continuation" pass means the model summarized instead of continuing. Roll back the prior backup version and record `restored_from` in `meta.json`.

## xAI endpoint reference

```
POST https://api.x.ai/v1/chat/completions
{
  "model": "grok-4.3",
  "max_tokens": 3000,
  "temperature": 0.85,
  "messages": [
    {"role":"system","content":"..."},
    {"role":"user","content":"..."}
  ]
}
```

Returns `{choices: [{message: {content: "<prose>"}}], usage: {prompt_tokens, completion_tokens, total_tokens}, model: "grok-4.3"}`.

`temperature=0.85` is the empirically best setting for cinematic prose — 0.7 yields mechanical output, 1.0 yields hallucinated NPCs.
