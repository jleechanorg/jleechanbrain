# PR #8808 dismissal-verification evidence — 2026-08-10

This is the raw transcript from the session that produced the worked example in SKILL.md. It is preserved here so the next session can pattern-match against the real evidence trail, not a polished summary.

## User's PR-ready claim (paraphrased)

"preview now has ALL fixes deployed and verified live ... PR is MERGEABLE, 21 checks green. 4 checks still red, none are this change:

• Directory tests ×3 shards — all three fail on ONE test, test_canonicalize_invariants.py, at a 99.5% success rate. Quarantined as pre-existing by commit 5f22925a3b. This branch never touches rewards_engine / level_up_session / llm_parser / game_state. Reproduced locally: 2 failed, 56 passed.

• Light/Fantasy Compliance Gate — fantasy dashboard 0.0 because workflow runs with GOOGLE_APPLICATION_CREDENTIALS=/dev/null ... feat/quick-start-rebuilt scored 91.18."

## PR identification triage

User referenced the PR by description only ("share fix + both routing fixes"). Three candidates:

- #8808 `feat/campaign-share-url-phase1-takeover` (${GITHUB_USER}, MERGEABLE, head 6d10aa098f)
- #8805 `fix/campaign-share-url-phase1-clean` (${GITHUB_USER}, **CONFLICTING**)  
- #8790 `feat/new-campaign-url-params` (also share-adjacent; superseded by #8808)

Resolved by asking the user before disposition. Verified with `gh pr diff 8808 --name-only` showing the share-token module + the auth.js redirect_after_login rewrite — both named by the user's preview description.

## Verification: per-shard actual failing test

| Shard | Job | User claimed | Actual failure from log + artifact | Verdict |
|---|---|---|---|---|
| core-mvp-1 | 93436723647 | test_canonicalize_invariants | **test_streaming_orchestrator.py**, stack at `llm_service.py:10118` → `_gemini_stream_with_cache_fallback`, 161/162 (99.4%) | NOT pre-existing per user message; related to PR #8839 (cache fix). Not verified against origin/main HEAD. |
| core-mvp-2 | 93436723721 | test_canonicalize_invariants | **test_canonicalize_invariants.py**: line 1613 `test_higher_canonical_xp_still_syncs_after_guard_added` + line 1534 `test_xp_progress_without_level_up_syncs_experience_current`, both with `AssertionError: 300 != 900`, 56/58 (96.5%, NOT 99.5%) | REPRODUCED on origin/main HEAD 164aadd6. SAME assertion, SAME line numbers, SAME byte file content. Valid pre-existing dismissal. |
| core-mvp-3 | 93436723620 | test_canonicalize_invariants | **test_session_header_enrichment.py**, 190/191 (99.5%) | NOT in user message; never independently verified. Test name suggests session-header code path which the PR DOES touch via `auth.js` `redirect_after_login` rewrite. **Suspicious of new regression.** |

## Artifact recipe that worked

```bash
# 1. Find artifact IDs
gh api repos/jleechanorg/worldarchitect.ai/actions/runs/31382610239/artifacts \
  | jq -r '.artifacts[].id'
# -> 9060710595 (shard1), 9060763658 (shard2), 9060698433 (shard3)

# 2. Download shard2 (where canonicalize assertions live)
cd /tmp/shard2_full && mkdir -p shard2_full && cd shard2_full
curl -fsSL -H "Authorization: token $(gh auth token)" \
  'https://api.github.com/repos/jleechanorg/worldarchitect.ai/actions/artifacts/9060763658/zip' \
  -o shard2.zip
unzip -o -q shard2.zip
find . -name 'test_canonicalize_invariants.py.*.log'
# -> ./test_canonicalize_invariants.py.24671590.log
```

The pytest trace inside the artifact log gave both failure line numbers + assertion values cleanly:

```
>       self.assertEqual(
            game_state_dict["player_character_data"]["experience"]["current"], 900
        )
E       AssertionError: 300 != 900

mvp_site/tests/test_canonicalize_invariants.py:1613: AssertionError
```

## Origin/main reproduction

```bash
git clone --depth 1 https://github.com/jleechanorg/worldarchitect.ai.git /tmp/origin_main_check
cd /tmp/origin_main_check
PYTHONPATH=. python3 -m pytest \
  mvp_site/tests/test_canonicalize_invariants.py::TestCanonicalXpSyncedToPlayerCharacterData::test_higher_canonical_xp_still_syncs_after_guard_added \
  mvp_site/tests/test_canonicalize_invariants.py::TestCanonicalXpSyncedToPlayerCharacterData::test_xp_progress_without_level_up_syncs_experience_current \
  -v 2>&1 | tail -20
# -> 2 failed in 1.01s; identical AssertionError: 300 != 900
```

## Quarantine SHA was dangling

The user cited `5f22925a3b` as the quarantine commit. That SHA exists as a dangling object on the local mirror but is no longer reachable from `origin/main`. `git log --all --pretty='%H' | grep 5f22925` matched once; `git rev-list origin/main | grep 5f22925` matched zero. The de-quarantine commit is `29e28523` ("fix(schema): restore cross-field level-up signal validation + drop unnecessary expectedFailure") on `origin/main` HEAD `164aadd6`. Lesson: a cited quarantine SHA proves NOTHING unless it still anchors on origin/main HEAD. Reproducing the failure on origin/main HEAD (which we did) is the only valid proof.

## Light/Fantasy Compliance Gate — verified

`.github/workflows/coverage.yml:58` contains:
```
GOOGLE_APPLICATION_CREDENTIALS: '/dev/null'
WORLDAI_GOOGLE_APPLICATION_CREDENTIALS: '/dev/null'
```
Plus `.github/workflows/wizard-mobile-scroll-regression.yml:79`. So the workflow DELIBERATELY runs without Firebase auth, and the fantasy dashboard score 0.0 is a CI-environment artifact. The user's CI-env dismissal is valid.

## What the user's framing got right vs wrong

| Item | User said | Reality |
|---|---|---|
| 21 checks green | ✓ | ✓ confirmed |
| 4 reds are pre-existing / CI-env | partial | 1 of 4 (canonicalize) verified pre-existing. 1 (Light/Fantasy) verified CI-env. 2 (streaming_orchestrator, session_header_enrichment) NOT verified, possibly new regressions |
| All three shards fail on ONE test | ✗ | Three different tests, one per shard |
| 99.5% success rate | partial | shard2=96.5%, shard3=99.5%. User's number was shard3's, mis-applied |
| This branch never touches rewards_engine/level_up_session/llm_parser/game_state | ✓ partially | Diff does NOT touch rewards_engine.py or game_state.py, but DOES touch firestore_service.py and the auth.js redirect flow |
| Quarantine SHA 5f22925a3b | dangling | The SHA exists; it's not on origin/main HEAD 164aadd6 |

## Cross-references

- SOUL.md `## COMMIT: same-test-name-rule` — the gating commitment that requires this skill
- `drive-pr-to-green` (user-owned, not patched) — references this skill in SKILL.md "see `qa-test-failure-dismissal-anti-pattern`"
- Skill `qa-test-failure-dismissal-anti-pattern/SKILL.md` — first worked example sourced here
