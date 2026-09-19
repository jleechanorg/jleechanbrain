---
name: wa-dice-integrity-audit
version: 1.3.0
category: worldarchitect
description: Per-user WA dice forensics. chi-squared uniformity, PC vs NPC bias, seed-commitment verification, god-mode directive persistence trace. Use when asked "why do I always win dice rolls", "are the dice fair", "run chi-squared analysis on user X's rolls", "did this user's god-mode rules persist", "did the fabrication guard fire on campaign Y", or any per-user statistical-integrity question.
related_skills:
  - wa-prod-data-query
  - download-campaign
  - repro
  - wa-daily-dice-audit-fix
last_verified: 2026-08-15
---

# WA dice-integrity audit — per-user dice forensics

Class of work: investigate one WA real user's dice outcomes, prove or disprove
bias, and trace persistence of god-mode rule-setting from player prose into
`game_states/current_state`.

This is NOT `wa-prod-data-query` (aggregate) and NOT `download-campaign`
(single-campaign walker). It sits between them: per-user × all campaigns ×
dice outcomes × rules-trace.

## When to use

- "Why do I always win dice rolls" / "are the dice fair" / "check this user's dice"
- "Pull this user's dice rolls and run chi-squared"
- "Did my rules-setting actually persist"
- "Did the fabrication-detection guard fire on campaign X"
- Any "is this user's experience statistically abnormal?" question

## When NOT to use

- Aggregate last-week user report → `wa-prod-data-query`
- Reading one campaign's full story text → `download-campaign`
- Reproducing a specific bug in one session → `repro`
- Auditing server-side RNG code (not user data) → read `mvp_site/dice.py` /
  `mvp_site/dice_provably_fair.py` directly

## Data model (verified 2026-08-13 on UID `oPISN50TvEcH21uVYKzlZX1kKNv2`)

```
users/{uid}/
  campaigns/{cid}/
    [doc]  title, created_at, last_played, use_default_world,
           selected_prompts, initial_prompt, living_world_state
    story/{eid}/
      actor: "user" | "gemini"              ← who wrote this entry
      mode: "character" | "god"             ← character vs god-mode directive
      part: 1..N
      text: string
      timestamp: Firestore Timestamp
      [optional] action_resolution.mechanics.rolls[]    ← structured dice
      [optional] action_resolution.mechanics.audit_events[]
      [optional] dice_rolls[]               ← legacy field
      [optional] debug_info:               ← dice-integrity telemetry
        dice_strategy: "code_execution" | "native_two_phase" | unset
        dice_server_seed, dice_seed_commitment, dice_seed_verified
        rng_verified: True | False | unset   ← canonical fabrication gate
        code_execution_used: True | False | unset
        code_contains_rng: True | False | unset
        executable_code_parts: int          ← >0 means Python actually ran
        rng_detection_ms, parsing_duration_ms, json_parsing_ms
        intent_classifier, dm_notes, state_rationale
        system_instruction_char_count       ← >300K inflates fabrication rate
        system_instruction_files, llm_model, llm_provider
        stdout, stdout_parts, stdout_is_valid_json, executed_code
        agent_name, execution_path
    game_states/current_state/
      player_character_data, npc_data, combat_state, turn_number,
      [NO schema slot for] combat_formula, rng_source, crit_rules

rate_limits/{uid}/
  turn_timestamps: [unix_seconds, ...]        ← one per LLM call
  god_mode_timestamps: [unix_seconds, ...]    ← SEPARATE signal
  campaign_create_timestamps: [unix_seconds, ...]
  last_updated: Firestore Timestamp
```

### Unit gotchas

- `rate_limits.turn_timestamps` are **Unix seconds** (not ms). Earlier skill
  versions assumed ms and reported "1970 epoch junk" — that was a parse
  error, not malformed data.
- `users/{uid}/campaigns/{cid}.last_played` is the **per-campaign** activity
  signal — the right field for "is this user still active on this campaign?"
  Not `lastUpdated` on the user doc.
- A user can have multiple active campaigns. Pull all of them and check
  `last_played` on each before declaring churn.
- **`debug_info` lives on `story/{eid}.debug_info`, NOT inside
  `action_resolution.mechanics`.** The audit-extractor only reads
  `action_resolution.mechanics.rolls` for dice values, but every
  provenance / fabrication / size-of-system-prompt field is on
  `debug_info` itself. See Step 6 for the provenance-split recipe.
- **`rng_verified` is the canonical fabrication gate.** A doc with
  `rng_verified=True` had Python actually execute the dice code
  (`code_execution_used=True`, `executable_code_parts > 0`,
  `code_contains_rng=True`). A doc with `rng_verified=False` had
  `code_contains_rng=True` but Python produced a non-RNG result — the
  server detected fabrication. **A doc with `rng_verified=unset` had
  no dice-tool invocation at all** (often because the roll happened in
  prose without structured attribution, or because user-input turns
  never reach the dice tool). See Step 6 — the unset bucket is the one
  that holds the player's actual experience.

## Standard query workflow

### Step 1 — Resolve UID from email

```python
import firebase_admin
from firebase_admin import auth, credentials, firestore
import os
os.environ.setdefault("WORLDAI_DEV_MODE", "true")
if not firebase_admin._apps:
    cred = credentials.Certificate(os.path.expanduser("~/serviceAccountKey.json"))
    firebase_admin.initialize_app(cred)
db = firestore.client()
uid = auth.get_user_by_email("hanjistevens@gmail.com").uid
```

### Step 2 — Pull all campaigns for this user

```python
campaigns = list(db.collection("users").document(uid)
                  .collection("campaigns").stream())
for c in campaigns:
    d = c.to_dict()
    story_n = len(list(c.reference.collection('story').stream()))
    print(f"{d.get('title')!r}  cid={c.id}  "
          f"created={d.get('created_at')}  "
          f"last_played={d.get('last_played')}  story={story_n}")
```

### Step 3 — Extract dice rolls

Two paths can produce dice data:

1. **Structured** — `story/{eid}.action_resolution.mechanics.rolls[]` with
   `{notation, rolls:[face], total, modifier, dc, success, purpose}`.
   `rolls[0]` may be a list of raw faces or a string `"15"` (legacy).
2. **Legacy** — `story/{eid}.dice_rolls[]` (older; same shape).

See `scripts/extract_user_dice.py` for the canonical extractor.

### Step 4 — Run the chi-squared suite

See `scripts/chi_squared_audit.py`. Seven tests:

1. **d20 uniformity** — χ² vs uniform 1/20 expected. Critical α=0.05
   at df=19 = 30.14.
2. **PC vs NPC d20 bucket** — 2×4 contingency table on buckets
   [1-5, 6-10, 11-15, 16-20]. Critical α=0.05 at df=3 = 7.815.
3. **Per-die-size uniformity** — split by `die_size`, skip if n < 5.
4. **Success rate vs DC** — group 1d20 by `dc`, compare to fair-die
   expected.
5. **Actor × campaign** — count rolls per actor per campaign.
6. **Nat 20 / Nat 1 rate** — observed vs 5% expected, χ²(1 df).
   Critical α=0.05 = 3.841.
7. **CDF** — quartiles + 5/95th percentiles of d20 faces.

### Step 5 — Trace god-mode directive persistence

Filter `story/{eid}.mode == "god"` for rule-setting turns. Then check
`game_states/current_state` for whether the rule persisted. Known schema
gaps (user asked for these; no slot exists):

- `combat_formula`, `damage_formula`, `rpg_formula`
- `rng_source`, `server_rng`, `secure_rng`
- `crit_rules`, `fumble_rules`

Phrase the finding: *"User asked for X. Model said it stored X. Runtime
may already do X. But the request isn't recorded anywhere that survives
the session, so the next turn the user has to ask again."*

### Step 6 — Split by provenance (`rng_verified`) and re-run χ² on each subset

**Why this step exists**: chi-squared over the full roll pool (Steps 1-7)
answers "is the distribution uniform?" but not "is the *server's RNG* uniform
vs is the *model* uniform?". A campaign can have 87% of rolls fabricated in
prose and 13% through server RNG, and the combined χ² will be FAIL-uniform
without telling you which population caused it. **Always split before
reporting "dice are broken" or "dice are fine".**

```python
# After Step 4, group every d20 single-die roll by debug_info.rng_verified
import re
from collections import Counter
rng_true, rng_false, rng_unset = [], [], []

for doc in camp_ref.collection("story").stream():
    sd = doc.to_dict() or {}
    debug = sd.get("debug_info") or {}
    rv = debug.get("rng_verified")
    ar = sd.get("action_resolution") or {}
    mech = ar.get("mechanics") if isinstance(ar, dict) else {}
    if not isinstance(mech, dict):
        continue
    for r in mech.get("rolls", []) or []:
        if not isinstance(r, dict):
            continue
        m = re.match(r"(\d*)d(\d+)", r.get("notation", ""))
        if not m or int(m.group(2)) != 20:
            continue
        raw = r.get("rolls") or r.get("faces") or r.get("raw_faces") or r.get("result") or r.get("roll")
        if isinstance(raw, list): face = raw[0] if raw else None
        elif isinstance(raw, (int, float)): face = int(raw)
        elif isinstance(raw, str):
            try: face = int(raw.split(",")[0])
            except ValueError: face = None
        else: face = None
        if face is None or not (1 <= face <= 20):
            continue
        if rv is True: rng_true.append(face)
        elif rv is False: rng_false.append(face)
        else: rng_unset.append(face)
```

Report each subset's χ², mean, and verdict separately. **The actionable
finding comes from comparing the means** — e.g. server-RNG mean=7.64 vs
unset mean=15.39 on Jeffrey's `noctune Warcraft 3` campaign proves the
gap is fabrication rate, not RNG bias.

If you don't see `rng_verified` populated on most gemini turns, also
report the per-campaign telemetry coverage:

```python
from collections import Counter
coverage = Counter()
for doc in camp_ref.collection("story").stream():
    sd = doc.to_dict() or {}
    debug = sd.get("debug_info") or {}
    actor = sd.get("actor")
    if actor != "gemini": continue
    rv = debug.get("rng_verified")
    coverage["True" if rv is True else "False" if rv is False else "unset"] += 1
```

If `unset` > 50% of gemini turns, the campaign is **under-instrumented** —
the dice tool isn't being called and there's no evidence trail to audit.
That itself is a finding worth surfacing (see Pitfall #14).

See `references/2026-08-15-noctune-warcraft-3-findings.md` for the
worked example: 34 d20 rolls split 11/0/23 (True/False/unset), the
two populations are not from the same distribution, server RNG is
fair, model rolls are heavily skewed high (mean=15.39, every roll ≥13).

## Pitfalls

1. **Actor split surprise** — In some campaigns, `action_resolution.
   mechanics.rolls` contains ONLY NPC rolls (all `actor=gemini`). PC rolls
   happen in prose without structured attribution. Always check actor
   distribution before drawing PC-vs-NPC conclusions. If 0 PC rolls exist
   in structured data, the χ² result describes NPC bias only. **Hanji's
   campaign: 87 NPC d20 rolls, 0 PC rolls.**

2. **`rng_verified` is the canonical fabrication gate, NOT
   `dice_strategy`** — `dice_strategy` was sparsely populated on older
   campaigns (1/310 on hanji's, still 1/102 on Jeffrey's current
   `noctune Warcraft 3`). `rng_verified` is populated on the same set
   of docs and is what you should filter on. See Step 6.

3. **Multi-campaign users** — Don't conflate campaigns. Per-campaign
   `last_played` is the right field; `rate_limits.last_updated` is
   aggregate.

4. **Don't trust `campaigns` (root) collection** — Still zero real users
   there as of 2026-08-13. Always go via `users/{uid}/campaigns/{cid}`.

5. **Story entries use `actor`, not `speaker` or `role`** — earlier code
   used `role` field; that's wrong. Use `actor` (`"user"` or `"gemini"`).

6. **God-mode entries have `mode="god"`** — filter on this field, not on
   text patterns ("I want", "Make sure", etc.). Text pattern matching has
   too many false negatives.

7. **story entry timestamps** — Firestore Timestamp; sortable via
   `.timestamp()`. Don't use `created_at` (may not exist); use `timestamp`.

8. **Seed commitment alone doesn't prove fairness** — A doc with
   `dice_server_seed` + `dice_seed_commitment` + matching SHA-256 is
   necessary but NOT sufficient. The Python must actually have run.
   Always cross-check `rng_verified=True` + `code_execution_used=True`
   + `executable_code_parts > 0`. Hanji had 4 docs where commitment
   matched but `rng_verified=False` — fabricated rolls with valid
   fingerprints. **This pitfall is a precursor to Step 6, not a
   replacement:** the audit's headline χ² must be re-run on each
   `rng_verified` subset, or you'll conflate fair server dice with
   fabricated model dice and reach the wrong verdict.

9. **System prompt size inflates fabrication rate** — When
   `debug_info.system_instruction_char_count > 300K` (often 500K+),
   the model drops instructions including "use code_execution for
   dice". This is the upstream root cause of issues 2, 4, 6 above.
   Check `system_instruction_char_count` before assuming model
   non-compliance is bad prompting.

10. **`dice_rolls` legacy field has no actor marker** — Even when the
    roll is for the PC (e.g. "Hilga athletics check to grapple Sechi"),
    the legacy `dice_rolls[]` field doesn't say who. Use `purpose`
    text + doc-level `actor=gemini` as best-effort attribution.
    **Don't conclude "NPC rolled it"** without verifying.

11. **`face=15` over-representation is the signature** — Across 87 d20
    rolls on Hanji's campaign, face 14 alone had 26 (29.9%) of rolls.
    If a single face has >2× expected count on a d20 distribution,
    suspect fabrication before suspecting RNG. The 2026-08-15
    `noctune Warcraft 3` campaign adds a sharper signature: when
    EVERY observed face is ≥13 (with mean=15.39 and 0% coverage below
    the median), the model is not just lucky — it's narrating the
    distribution. Face-floor at 13 is the fingerprint of `gemini-3.7-flash`
    rolling dice in prose on `MODELS_WITH_CODE_EXECUTION`-excluded models.

12. **Zero Nat 1s in n>=50 d20 rolls is a strong signal** — Fair dice
    should produce ~5% nat 1s. Zero nat 1s across 87 rolls has a
    cumulative binomial probability <1.2% under the null of fair dice.
    Combine with the chi-squared result before reporting.

13. **`rng_verified=unset` on >50% of gemini turns means the campaign
    is under-instrumented, not "the dice are fine"** — When the model
    doesn't call the dice tool, no `debug_info` gets attached at all.
    A blank `rng_verified` is the absence of evidence, NOT evidence of
    absence of fabrication. Surface this as a finding: "X% of dice
    outcomes in this campaign have no provenance trail — the dice tool
    isn't being invoked, so we can't even tell whether they're fair."

14. **`normalize_roll()` must include `campaign` key** — The
    `chi_squared_audit.py` script's `test_actor_by_campaign()` indexes
    `parsed["campaign"]`. If your extractor omits it (single-campaign
    scope), the audit crashes with `KeyError: 'campaign'`. Either tag
    every roll with the campaign title in your extractor, or pre-load
    the title into a closure before calling `normalize_roll(r, name)`.

15. **Dice bias is often model-driven, not RNG-driven** — When a
    campaign's chi-squared is FAIL-uniform, the FIRST hypothesis should
    be "which model produced each turn, and is that model in
    `MODELS_WITH_CODE_EXECUTION`?". `debug_info.llm_model` is the
    field; `MODELS_WITH_CODE_EXECUTION` lives in
    `mvp_site/constants.py:151`. Step 6's per-provenance χ² should
    ALSO be split by model — the actionable verdict is usually
    "rolls on `gemini-3-flash-preview` are fair, rolls on
    `gemini-3.7-flash` are fabricated" — the dice tool is per-model,
    not per-campaign. Concrete: Jeffrey's `noctune Warcraft 3` had 45/67
    gemini turns on `gemini-3.7-flash` with `rng_verified=unset` for all
    45 (zero server dice invocations) and 21/67 on `gemini-3-flash-preview`
    with `rng_verified=True` on 9 of 21 (43%).

16. **PR titles about dice/code-execution can lie** — PR #8870
    (merged 2026-08-15) titled "feat(settings): add gemini-3.7-flash,
    make gemini-3.6-... code execution models" but its actual diff did
    NOT add `gemini-3.6-flash` or `gemini-3.7-flash` to
    `MODELS_WITH_CODE_EXECUTION` — it only rewrote the comment to say
    "Do not add... until real-callstack verified". The exclusion comment
    itself was based on a 2026-07-21 observation about
    `gemini-3.5-flash-lite` and was never re-verified for 3.6/3.7.
    Whenever you see a merged PR whose stated intent contradicts
    the live code, **read the actual diff** (`gh pr view <N> --json files`
    + commit-level diff via REST) before trusting the title.

17. **`output_tokens` is a dice-tool canary** — On `gameplay_streaming`
    turns where the model actually called code_execution, output_tokens
    includes the tool-call block PLUS the tool-result text PLUS the
    final JSON answer — usually 2,000+ tokens minimum. If you see
    `output_tokens` <1,000 on a turn that has a structured
    `action_resolution.mechanics.rolls[]` entry, the dice tool was NOT
    called. Cross-check via BQ
    (`worldarchitecture-ai.llm_forensics.llm_payloads`) with
    `model=<candidate> AND finish_reason='STOP'`: if STOP rate is high
    but `output_tokens` floor is low, the model is narrating, not
    computing.

## Setup gotchas (read before running)

Three environment-specific traps bit the 2026-08-15 `noctune Warcraft 3`
audit run. They apply every time you run this skill against
`worldarchitecture-ai` from the `worldarchitect.ai/.venv`:

1. **venv `firestore.client()` raises `AttributeError: module
   'google.cloud.firestore' has no attribute 'client'`** — the venv
   version exposes `Client` only. Use:

   ```python
   from google.cloud.firestore import Client
   db = Client(project="worldarchitecture-ai")
   ```

2. **`firebase_admin.initialize_app(cred)` resolves to the wrong
   project** — without a project option, `google.auth.default()` reads
   `GOOGLE_CLOUD_PROJECT` from the user's bashrc and falls through to
   `ai-universe-2025` (the user's primary GCP project, NOT the
   worldarchitecture-ai Firestore). Queries return 403 PermissionDenied
   on user data. Fix:

   ```python
   firebase_admin.initialize_app(
       credentials.Certificate(os.environ["GOOGLE_APPLICATION_CREDENTIALS"]),
       {"projectId": "worldarchitecture-ai"},
   )
   ```

3. **`chi_squared_audit.py` crashes with `KeyError: 'campaign'`** if
   your extractor omits the `campaign` field on normalized rolls (Test
   5 indexes `parsed["campaign"]`). Either tag every roll with the
   campaign title, or thread the title into `normalize_roll(r, name)`.

The skill's bundled `scripts/extract_user_dice.py` has #1 hardcoded as
`firestore.client()` and will fail out of the box on the
`worldarchitect.ai/.venv` Python. Workaround: copy it to `/tmp/` and
patch the import + init, then run from there. (Or fix the script — but
that's a repo PR, out of scope for this skill.)

## Sample findings format

1. **Active campaigns table** — title, cid, created, last_played, story_count
2. **Pulled data summary** — N rolls, N d20 single-die, N campaigns
3. **Critical caveat** — actor split, strategy tagging, sample size
4. **Test results** — 7 tests with χ², criticals, pass/fail
5. **Verdict** — bias confirmed/refuted with sample-size context
6. **Persistence findings** — which god-mode directives persisted, which
   hit schema gaps
7. **Recommended fix** — schema fields to add, UI surface for dice
   integrity, telemetry to capture

## Tests

```bash
cd ~/.smartclaw/skills/wa-dice-integrity-audit
python3 -m unittest discover -s tests -v
```

Covers: dice notation parsing, actor attribution, χ² calculation against
scipy fallback, schema field detection.

## References

- `references/2026-08-13-hanji-stevens-findings.md` — first audit run,
  87 d20 rolls, χ²=159.67 (df=19) confirms NPC-side bias, Nat 1 = 0 / 87.
- `references/2026-08-15-noctune-warcraft-3-findings.md` — first audit
  using Step 6 (provenance split). 34 d20 rolls split 11/0/23
  (rng_verified True/False/unset). Server-RNG mean=7.64 (PASS),
  unverified mean=15.39 (FAIL). Worked example of how provenance
  split changes the actionable verdict.
- `references/2026-08-15-noctune-warcraft-3-gemini-3-7-fabrication.md` —
  canonical case study for the model-driven-dice-bias finding. 45/67
  gemini turns on `gemini-3.7-flash`, 0 verified RNG calls; vendor
  docs confirm 3.7-flash supports code_execution; the architectural
  gate (`mvp_site/constants.py:155`) excludes it from
  `MODELS_WITH_CODE_EXECUTION` based on a stale 2026-07-21
  observation about `gemini-3.5-flash-lite`. PR #8870's commit
  body claimed it added 3.6/3.7 to the code-execution set but the
  actual diff did not. **The recommended fix is: add `gemini-3.6-flash`
  and `gemini-3.7-flash` to `MODELS_WITH_CODE_EXECUTION` after running
  `testing_mcp/test_gemini_37_flash_code_execution.py` to prove
  the contract works against the live server, plus a CI guard that
  fails the build if `rng_verified=False` rate exceeds 5% per model.**
- `scripts/chi_squared_audit.py` — the seven-test suite.
- `scripts/extract_user_dice.py` — per-user × all-campaigns
  extractor (uses `firestore.client()` which fails on the
  `worldarchitect.ai/.venv` Python 3.12 — see Setup gotchas #1).
- `scripts/extract_one_campaign.py` — single-campaign scope
  extractor with the venv + project + Auth fixes. Use this when
  the user gives a `/game/<cid>` URL. Pairs with `audit_subsets.py`
  for the provenance-split audit.
- `scripts/audit_subsets.py` — runs χ² on three `rng_verified`
  subsets (True/False/unset) for a single campaign. This is the
  minimum diagnostic for a dice bias complaint — without it you
  cannot tell server-RNG bias from model-fabrication bias.
- `mvp_site/dice.py` lines 230–448 — server-side dice tool definitions.
- `mvp_site/dice_provably_fair.py` — cryptographic seed + commitment.
- `mvp_site/dice_integrity.py` — fabrication detection (rng_verified gate).
