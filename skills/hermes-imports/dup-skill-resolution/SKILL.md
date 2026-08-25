---
name: dup-skill-resolution
description: Detect and fix duplicate-skill-resolution ambiguity between `~/.smartclaw/skills/` and `~/.smartclaw/skills/hermes-imports/`. Use when a CronJob fails to load a skill with "ambiguous name" error, when `skill_view name=<X>` returns more than one match, when the user reports "skill resolver ambiguous" or "executive-digest couldn't load", or when the daily `doctor.sh` run reports duplicate-skill-resolution pairs. Outcome: leaves one canonical copy under `hermes-imports/` (the resolver's source-of-truth per AGENTS.md) and removes the byte-identical top-level mirror.
tags: ["meta", "skills", "resolver", "maintenance", "hub-install"]
category: workflow
version: "1.0.0"
provenance:
  originating-incident: "Slack C0AJQ5M0A0Y / 1787109359.876879 (2026-08-18) — clawchief:ea-sweep-hourly 2f942031797e could not load executive-digest; cron silently adapt-inlined. Memory `Duplicate-skill-resolution pattern` documented the manual fix recipe. This skill turns the manual recipe into a repeatable workflow + a doctor check."
---

# dup-skill-resolution — Fix duplicate SKILL.md across resolver roots

## When to use this skill

Use when ANY of these are true:

1. A CronJob fails to load a skill with "ambiguous name" / "ambiguous category/name" error.
2. `skill_view name=<X>` returns 2 matches with byte-identical content.
3. The user reports "skill resolver ambiguous" / "the cron is adapt-inlining" / "Why did all our PRs not fix this?" after a duplicate-detection dry-run.
4. `bash ~/.smartclaw/scripts/doctor.sh` reports `duplicate-skill-resolution ambiguity detected (N byte-identical pair(s))`.
5. A hub install (e.g. `~/.agents/skills/`, `mgonto/executive-assistant-skills`, `claude-commands`) was synced to `~/.smartclaw/` and produced a top-level mirror under `skills/<category>/<name>/` that byte-matches `skills/hermes-imports/<category>/<name>/`.

## Why this happens (root cause)

Two resolver roots coexist under `~/.smartclaw/skills/`:
- `~/.smartclaw/skills/<category>/<name>/SKILL.md` — the **top-level mirror**, populated by hub installers (e.g. `claude-commands hub install`).
- `~/.smartclaw/skills/hermes-imports/<category>/<name>/SKILL.md` — the **canonical import resolver**, tracked in this repo (per AGENTS.md and the `Duplicate-skill-resolution pattern` memory).

The skill resolver tries names by walking both roots. When two copies match `category/name`, the resolver refuses to pick between them and emits `ambiguous`. The CronJob fails to load the skill, and well-written crons silently adapt inline (the work happens, but the skill never loaded — so the format/path assumptions baked into the skill's body are missing).

The canonical line of repair is **delete the top-level mirror**, because:
- `hermes-imports/` is the source-of-truth (Git-tracked, has `_meta.json` and `.clawhub/origin.json` provenance, follows the curator pattern).
- The top-level mirror is a hub-install artifact that may have outdated path strings (the executive-digest case had `~/executive-assistant-skills/skills-executive-assistant-config/config/...` against the real `config/...`).
- The curator will re-reconcile via `hermes curator adopt` if the top-level copy is needed as a managed umbrella skill.

## Recipe (5 steps, no improvisation)

### Step 1 — Confirm the ambiguity

Run the doctor (post-fix; before-fix, the symptom is a cron error in job-output):

```bash
bash ~/.smartclaw/scripts/doctor.sh 2>&1 | grep -A1 "duplicate-skill-resolution"
```

If the doctor does NOT have this check yet (older harness), extract the function and call it directly:

```bash
awk '/^check_duplicate_skill_resolution\(\) \{/,/^\}$/' \
   ~/.smartclaw/scripts/doctor.sh > /tmp/check_func.sh
cat >> /tmp/check_func.sh <<'EOF'
pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; }
check_duplicate_skill_resolution ~/.smartclaw
EOF
bash /tmp/check_func.sh
```

The output lists `<canonical_path>  <==>  <mirror_path>` for every byte-identical pair.

### Step 2 — Pre-flight: is the canonical copy REALLY canonical?

The hub-install pattern may have made the top-level mirror canonical (e.g. if the user edited something at the top-level and forgot to mirror it). For each pair:

```bash
sha256sum "$HOME/.smartclaw/skills/<category>/<name>/SKILL.md" \
          "$HOME/.smartclaw/skills/hermes-imports/<category>/<name>/SKILL.md"
```

If the SHAs match → safe to delete the top-level mirror.
If the SHAs differ → STOP. The upstream and the local copy have drifted. Sync from the hub source first (per the per-skill upstream rule in `~/.smartclaw/skills/<category>/<name>/`, usually a `homepage` or `repository` field in the SKILL.md frontmatter), then re-run the SHA check.

### Step 3 — Sync upstream over hermes-imports (the canonical refresh)

For each pair, the canonical copy under `hermes-imports/` should be the latest. If a hub provides a newer copy (e.g. upstream `mgonto/executive-assistant-skills` HEAD `28f5065` is newer than the local mirror), sync the upstream SKILL.md over the `hermes-imports/` copy:

```bash
# Example: refresh executive-digest from upstream
git clone --depth 1 <hub-repo-url> /tmp/hub-skill
cp /tmp/hub-skill/<category>/<name>/SKILL.md \
   ~/.smartclaw/skills/hermes-imports/<category>/<name>/SKILL.md
```

Verify the SHA256 of the upstream copy matches what the hub publishes (or `git diff` against the upstream if you have it).

### Step 4 — Delete the top-level mirror

```bash
rm -rf ~/.smartclaw/skills/<category>/<name>/
```

This is the canonical repair. The `hermes-imports/` copy is the resolver's source-of-truth; the top-level is the artifact that produced the ambiguity.

### Step 5 — Verify

```bash
# Re-run the doctor check
bash ~/.smartclaw/scripts/doctor.sh 2>&1 | grep "duplicate-skill-resolution"

# Verify skill_view resolves cleanly
skill_view name=<skill-name>  # should resolve to single match
```

If the doctor still reports a pair, you missed one — re-run step 1.

## Worked example — executive-digest (2026-08-18)

**Trigger:** `clawchief:ea-sweep-hourly (job_id: 2f942031797e)` failed to load `executive-digest` with "ambiguous category/name" error.

**Diagnosis:**
```bash
find ~/.smartclaw/skills -type f -name 'SKILL.md' | \
  xargs -I{} sh -c 'sha256sum "{}"' | sort | \
  awk '{print $1}' | sort | uniq -c | sort -rn | head
```

Found 2 byte-identical `SKILL.md` files at:
- `~/.smartclaw/skills/executive-assistant/executive-digest/SKILL.md`
- `~/.smartclaw/skills/hermes-imports/executive-assistant/executive-digest/SKILL.md`

**Fix (4 steps, ~3 min):**
1. `git clone --depth 1 mgonto/executive-assistant-skills ~/executive-assistant-skills` (fresh install at the hardcoded path the skill expects)
2. `cp ~/executive-assistant-skills/executive-assistant/executive-digest/SKILL.md ~/.smartclaw/skills/hermes-imports/executive-assistant/executive-digest/SKILL.md` (sync upstream over canonical)
3. `rm -rf ~/.smartclaw/skills/executive-assistant/executive-digest/` (delete the top-level mirror)
4. `skill_view name=executive-digest` → resolves to single match (`readiness_status: available`)

**Verification:** cron resolved cleanly on next sweep tick (next: 2026-08-19 08:00 PDT).

## Anti-patterns

- **Don't delete the `hermes-imports/` copy.** It's the canonical source. The top-level mirror is what gets removed.
- **Don't sync from the top-level mirror into `hermes-imports/`.** That preserves the broken path strings (the executive-digest case had `~/executive-assistant-skills/skills-executive-assistant-config/config/...` from the upstream install that the local copy had pasted into the path). Always sync from the upstream hub source if the skill is forked from an external repo.
- **Don't "fix" this by adding a `.noindex` to the top-level mirror.** The resolver doesn't consult `.noindex`; the ambiguity check is byte-level SHA.
- **Don't `git mv` the top-level mirror into `hermes-imports/`.** It already exists there. You're looking at a duplicate, not a missing file. The fix is `rm`, not `mv`.
- **Don't add a new SOUL.md COMMIT for this.** The doctor check is the durable guard. The Skill is the recipe. SOUL.md COMMITs are for behavioral promises the agent must auto-apply on every session; this is a maintenance recipe, not a behavioral rule.

## Companion artifacts

- `scripts/doctor.sh` — `check_duplicate_skill_resolution` function (added 2026-08-19, this skill).
- `tests/test_duplicate_skill_resolution.sh` — 5-case contract test (no mirror / empty mirror / byte-identical pair / diverged bytes / shellcheck clean).
- Memory `Duplicate-skill-resolution pattern` — the prior manual fix that this skill standardizes.
- Bead — none required; the doctor check is the durable guard.

## Pitfalls

- **The same class of bug recurs whenever a hub installer syncs over `~/.smartclaw/skills/` without going through `hermes-imports/`.** The doctor check catches it on the next doctor run, but if you disable the doctor (e.g. in CI), the cron will silently adapt-inline. Keep the doctor alive in the daily `ai.smartclaw.health-guardian` cron.
- **The check does NOT recurse into nested skills directories.** Only top-level `SKILL.md` at `<category>/<name>/SKILL.md` is checked. Nested skill files (e.g. `shared/references/SKILL.md` if any) are out of scope — hermes v1 doesn't load nested SKILL.md files.
- **The check assumes `hermes-imports/` is the canonical resolver.** If your local config has `~/.smartclaw/agents/skills/` or any other resolver root, you must add it to the doctor check too. Look at `~/.smartclaw/skills/RESOLVER.md` for the resolver walk order.
