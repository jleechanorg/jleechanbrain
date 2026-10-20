# CodeRabbit iterate-to-APPROVED recipe — PR #9132 anchor case

## Origin

PR [jleechanorg/worldarchitect.ai#9132](https://github.com/jleechanorg/worldarchitect.ai/pull/9132)
"fix(action_resolution): suppress warning for non-player-action agents +
prune stale recovery (#9114)". Reviewer: CodeRabbit left 5 MAJOR + 2
nitpicks + 2 test-divine-prompt nits. Operator asked: *"Action resolution
PR review using /advice and /web-advice and iterate until they approve"*.

This reference captures the recipe that emerged for the iterate-to-APPROVED
class of task — the multi-cycle shape that the parent skill's single-cycle
flow does not cover.

## The 5 MAJOR + 2 nitpicks + 2 test-divine-prompt nits (initial triage)

| # | Severity | File | Finding | Fix |
|---|---|---|---|---|
| 1 | MAJOR | `mvp_site/agents.py:2874` | `HeavyDialogAgent` / `SpicyModeAgent` inherit `False` from DialogAgent override but load `PROMPT_TYPE_NARRATIVE` (full schema) — lose action-resolution validation by accident | Add `requires_action_resolution = True` overrides on both subclasses |
| 2 | MAJOR | `mvp_site/agents.py:3362` | `FactionManagementAgent.requires_action_resolution = False` is unconditional — FactionManagement handles mass-combat + XP + code-executed dice that requires audit trails | Remove the unconditional exemption; default `True` from `FixedPromptAgent` |
| 3 | MAJOR | `mvp_site/llm_service.py:7929` | `os.environ.get("TESTING") or os.environ.get("TEST_MODE")` is truthy for ANY non-empty string including `"false"` / `"production"` — silently misattributes prod requests to `test_user_anonymous` | Explicit enabled check: `{"1","true","yes","on"}` for TESTING; `{"test","mock"}` for TEST_MODE |
| 4 | MAJOR | `mvp_site/main.py:2869` + `mvp_site/world_logic.py:11453` | Same 9-field `immutable_fields` frozenset duplicated in both files | Centralise in `mvp_site/constants.py` next to `campaign_patch_rejected_fields` |
| 5 | MAJOR | `mvp_site/narrative_response_schema.py:3517` | `truly_missing = not dice_audit and not code_exec_used` is too loose — `code_execution_used=True` alone with empty `dice_audit_events` suppresses the warning | Tighten to `truly_missing = not dice_audit` (require non-empty recoverable evidence) |
| 6 | nitpick | `mvp_site/tests/test_action_resolution_utils.py:1456` | Local import of `add_action_resolution_to_response` inside both test methods | Move to module scope |
| 7 | nitpick | `mvp_site/world_logic.py:8584` | Duplicated `"Confirm Applied Options and Return to Game"` choice dict in `_reconcile_modal_planning_response` (lines ~8593 + ~8632) | Extract small helper |
| 8 | nitpick | `mvp_site/tests/test_divine_prompts_setting_agnostic.py:98` | `fail_msg or ...` treats `""` as absent | Use `if fail_msg is None` |
| 9 | nitpick | `mvp_site/tests/test_divine_prompts_setting_agnostic.py:774` | `test_dpp_ranges_are_reachable_by_the_l50_budget` stops at Intermediate God row; docstring requires through Transcendent | Extend assertions to Greater God + Transcendent rows |

## Worker dispatch brief — the canonical recipe

```bash
# 1. Fresh worktree from origin/main (NOT from the polluted PR head)
cd ~/projects/worldarchitect.ai
git worktree add /tmp/wt-<N>-crfb -b fix/<N>-coderabbit-feedback origin/main

# 2. Worker prompt structure (≤14KB brief, base64-encoded for shell escape)
#    - PR URL + head SHA + base SHA + diff stat + CR review state
#    - The 9-finding table above (file:line + finding + fix recipe)
#    - The cherry-pick decision tree (below)
#    - Iteration protocol (3 cycles max)
#    - /advice + /web-advice honest-probe contract
#    - Stop conditions
#    - "DO NOT MERGE" red line — operator must type MERGE APPROVED

bash -lic 'claudem -p "$(cat /tmp/pr<N>-brief.md)" --max-turns 200 --output-format text' \
  > /tmp/pr<N>-worker.log 2>&1 &
```

## Cherry-pick vs force-push decision (PR head has 19 commits)

**Default: cherry-pick onto the existing PR head.**

```bash
cd /tmp/wt-<N>-crfb
git fetch origin fix/<original-branch>
git checkout -B fix/<original-branch> origin/fix/<original-branch>
git cherry-pick <commit1> <commit2> <commit3>  # the load-bearing fix commits only
git push --force-with-lease origin fix/<original-branch>
gh pr view <N> --json headRefOid -q .headRefOid  # MUST equal local HEAD
```

**Skip merge commits, fixup commits, "chore: trigger CI" no-ops.** The PR
head should grow by ~5-9 commits per cycle, not the entire history.

**Alternative: full force-push from a clean-from-main replay.** Only use
this when the PR head has accumulated so many conflict-resolution merges
that cherry-pick produces more conflicts than the replay itself.

## /advice 3-reviewer fanout (in-session)

Build a brief per `~/.claude/skills/advice/SKILL.md` (canonical Claude) —
the Hermes overlay (`~/.smartclaw/skills/advice/SKILL.md`) adapts the
fallback chain to `subagent → agy → codex` since `cursor` is not
installed locally.

```python
# In-session fanout — Reviewer A only is usually enough; B + C are fallback
reviewer_a = delegate_task(
    goal="Senior engineer second opinion: are the 9 CR findings addressed?",
    context="PR <N>, branch <branch>, CR review state. The 9 findings table above.",
    toolsets=["terminal", "web"],
)
# Synthesise verdict table inline — DO NOT await all 3 if A returns clear PASS
```

The 3 reviewers' outputs are SELF-REPORTS, not facts. Verify each by
re-fetching the file state the reviewer cited.

## /web-advice vendor panel — transport-ladder reality (do not overpromise)

Per `~/.smartclaw/skills/review/web-advice/SKILL.md` §1 + §2a + §5:

| Date | Outcome | Notes |
|---|---|---|
| 2026-08-17 | 0-of-4 (EDD audit) | First surface of the 0-of-4 streak |
| 2026-08-18 | 0-of-4 (review same task, next day) | Confirmed not fluke |
| 2026-08-19 | 0-of-4 (PR review, 1st iteration) | Same fingerprint |
| 2026-08-19 (later same day) | 2-of-4 (Gemini + Grok authed) | Confirmed ladder is moving target |
| 2026-08-21 | 2-of-4 (Gemini + Grok; ChatGPT + Perplexity Cloudflare-walled) | Quiet War campaign review |

**Realistic ceiling today: 2-of-4.** Report honestly. Do NOT fabricate
4-of-4 to satisfy the operator's "iterate until approved" phrasing —
the operator's red line on fabricated vendor panels is harder than CR
staying `COMMENTED`.

### Operator-share-URL red line (added 2026-08-19)

Operator's verbatim correction (Slack C0AH3RY3DK6/p1787187606):
*"modify /web-advice and say the LLM must share the convo and give url back,
NOT THE FUCKING HUMAN"*. Therefore: AFTER every captured vendor response,
the LLM MUST drive the Share-button click in headless chrome with authed
cookies. Operator-clicked Share is FORBIDDEN. Per-vendor recipes in the
canonical skill §1b.3 (ChatGPT, Grok, Gemini, Perplexity). After click,
verify via `curl -s -L -I <url>` returns HTTP 200 without session cookies.

## CR re-trigger timing

| Situation | Action |
|---|---|
| Push → CI green → no CR comment within 30 min | `gh pr comment <N> -b "@coderabbitai review"` |
| Push → CI red → fix → push again | Don't ping CR until CI green — CR auto-reviews on every push |
| Push → CR re-reviews → still `COMMENTED` with same 7+ findings across cycles | **STOP** — surface to operator with menu (do not auto-merge) |

## Final reply shape (after CR APPROVED + CI green)

```
[PR #9132] ✅ APPROVED + N-green

CR verdict: APPROVED
CI: <N/N passing, list any SKIPPED>
Commits added this cycle: <SHA1> <SHA2> <SHA3>
Reviewer A (/advice subagent): PASS — <one line>
Reviewer B (Gemini): PASS — <share URL>
Reviewer C (Grok if landed): PASS — <share URL> | DOWN — <probe output>

Pending — needs your MERGE APPROVED to merge.
```

If CR stays `COMMENTED` after 3 cycles, surface:

```
[PR #9132] :warning: CR COMMENTED after 3 cycles — operator decision needed

Cycle 1: applied 9 fixes, /advice PASS, /web-advice 2-of-4 (Gemini + Grok)
Cycle 2: addressed 4 new CR sub-issues, /advice PASS, /web-advice 1-of-4
Cycle 3: addressed 2 new CR sub-issues, /advice PASS, /web-advice 2-of-4

CR remaining threads: <list of N unresolved>
CI: green, MERGEABLE: true

Options:
1. Merge as-is (CR is advisory, not a gate in worldarchitect.ai)
2. Reply to each remaining thread manually before merge
3. Close + reopen from clean branch (deep re-review)
```

## Key file paths (canonical for follow-up sessions)

| Path | Purpose |
|---|---|
| `mvp_site/narrative_response_schema.py:3515-3545` | Validator pre-check predicate (the root-cause fix) |
| `mvp_site/action_resolution_utils.py:962-994` | Belt-and-suspenders prune after `add_action_resolution_to_response` |
| `mvp_site/llm_parser.py:640-680` | Streaming-persistence prune for `_merge_server_system_warnings_for_streaming_persistence` |
| `mvp_site/agents.py:2870-2890, 3360-3380` | `requires_action_resolution` overrides on DialogAgent + FactionManagementAgent |
| `mvp_site/llm_service.py:7920-7935` | Anonymous user_id fallback (the env-var gating fix) |
| `mvp_site/constants.py` | Where `immutable_fields` frozenset gets centralised |
| `mvp_site/main.py:2869-2891` | First call-site of `immutable_fields` (move to import from constants) |
| `mvp_site/world_logic.py:11453-11483` | Second call-site of `immutable_fields` (move to import from constants) |
| `roadmap/2026-01-11-action-resolution-consolidation.md` | The design contract this PR preserves |
| `mvp_site/tests/test_narrative_response_schema.py:2110-2155` | New RED→GREEN test (`code_execution_used=True` with empty dice_audit retains warning) |

## Provenance

- Originating PR: [#9132](https://github.com/jleechanorg/worldarchitect.ai/pull/9132)
- Originating issue: #9114
- Sibling beads: `rev-844sc` (this), `rev-1acx5` (sibling #9057), `rev-x6g77` (sibling FsiyESY987DF2lfgolCI)
- Originating Slack: thread `C0BDEAJH8PK / 1787454497.643299` (2026-08-22 PT)
- Transport-ladder failure log: `~/.smartclaw/skills/review/web-advice/references/transport-ladder-failure-log-2026-08-*.md`
- Worked example thread (operator-share-URL red line): `C0AH3RY3DK6/p1787187571, p1787187606, p1787187781`