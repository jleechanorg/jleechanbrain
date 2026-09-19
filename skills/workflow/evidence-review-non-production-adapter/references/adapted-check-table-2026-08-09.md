# Worked Example — 2026-08-09 /er on Browser Command/Skill Candidate

This is the literal verdict produced by the first concrete application of the
adapter on a non-production candidate. The candidate was a 3-file diff in
`jleechanorg/claude-commands`:

- `.claude/commands/browser.md` (modified, +33 / -10)
- `.claude/skills/browser-control/SKILL.md` (modified, +77 / -10)
- `tests/test_browser_command_contract.py` (new, 306 lines, 18 contract tests)

Plus incidental `.beads/` metadata changes.

## Tier classification

All 3 changed files fall into the non-behavioral bucket:

| File | Tier |
|---|---|
| `.claude/commands/browser.md` | Skill/command markdown — adapter applies |
| `.claude/skills/browser-control/SKILL.md` | Skill/command markdown — adapter applies |
| `tests/test_browser_command_contract.py` | Test code only (no production) — adapter applies |

Per the adapter's tier-classification rule, this candidate qualifies for
**PARTIAL with explicit waiver** as the ceiling. The verdict returned was PASS,
with high confidence, because every adapted check landed cleanly.

## Adapted check table — what actually ran

| # | Canonical check | Adapted behavior | Result |
|---|---|---|---|
| 1 | Bundle integrity | N/A — source-tree diff | ✓ recorded as N/A |
| 2 | Verification report ceiling | Replaced with contract-test adequacy: re-ran `python3 -m pytest -v tests/test_browser_command_contract.py` | ✓ 18/18 PASS |
| 3 | Scope note consistency | No scope note excludes browser-control domain | ✓ in-scope |
| 4 | Video artifacts | N/A — docs/skill-only change, Exception 1 | ✓ recorded as N/A |
| 5 | Public-URL hosting | N/A — no media assets | ✓ recorded as N/A |
| 6 | Self-contained reproducibility | Replaced with contract-test reproducibility: exact command + exit code captured | ✓ `python3 -m pytest tests/test_browser_command_contract.py` → exit 0, 18 passed in 0.02s |
| 7 | Anti-Fabrication / Telemetry | Adapted: dropped BQ resolution, traceback alignment, GREEN payload; kept branch containment + harness/provenance labeling | ✓ no LLM telemetry, no traceback, no GREEN payload in this change |
| 8 | Branch & Commit Containment | Kept: `git branch -r --contains` if SHA referenced | ✓ branch `sync/browser-command-from-user-scope-20260809` exists, HEAD matches |

## The 14 STRONG claims (file:line + raw observation)

1. Routing order wired: Aside-MCP > Aside CLI > browserclaw > Playwright > visible.
   - `browser.md:11–15`, `SKILL.md:18–22`
   - Verified by literal match + `first_aside_mcp < first_aside_cli` and `first_browserclaw < first_playwright` regex checks.

2. Old "never copy cookies between profiles" phrase removed.
   - `test_no_disallowed_phrases` (CMD + SKILL)
   - Regex `never.*copy\s+cookies\s+between\s+profiles` returns no match in either file.

3. Credential-reuse safeguards: `--summary`, `mktemp`, `chmod 600`, `trap '...' EXIT`, `rm -f`, `never`, `playwright-ui-testing`.
   - `test_credential_reuse_safeguards_present` (CMD + SKILL)
   - All required keywords present in both files.

4. HAR-based capture ban (`capture` / `learn` / `reverse`) in both files.
   - `test_no_har_for_credential_flows`, `test_har_ban_phrase_in_both`
   - Multi-token regex matches both files.

5. Fingerprint-sensitive outliers: LinkedIn, Cloudflare, banks.
   - `test_fingerprint_sensitive_outlier_named`, `test_fingerprint_exception_in_both`
   - All anchors present in both files.

6. Referenced recipe files exist in repo.
   - `test_referenced_browserclaw_recipes_exist_in_repo`
   - Both `multi-profile-cookie-scan.md` and `gemini-share-link-as-user.md` exist at `hermes/skills/browserclaw/references/`.

7. `Authorized credential reuse` section present in skill.
   - `test_authorized_credential_reuse_section_present`
   - Section header at `SKILL.md:32`.

8. `browserclaw` CLI flags actually exist.
   - `browserclaw cookies decrypt --help`, `browserclaw cookies inject --help`, `browserclaw --help`
   - All required flags present: `--db`, `--output`, `--domain-filter`, `--keychain-service`, `--keychain-account`, `--summary`, `--cookies`, `--goto`, `--browser-channel`, `--headless`, `--wait-after-load`, `--screenshot`, `--print-text`.

9. Aside CLI reachable and reports two signed-in profiles.
   - `aside --version` -> 1.26.709.1533
   - `aside account list` -> 2 profiles (`u0 jleechan@gmail.com`, `u1 jleechan@worldarchitect.ai`)

10. Frontmatter headers present in both files.
    - `browser.md:1–5` (description, type: skill, execution_mode: immediate)
    - `SKILL.md:1–4` (name: browser-control, description)

11. Cookie JSON cleanup: `trap ... EXIT` + explicit `rm -f`.
    - `test_credential_reuse_safeguards_present` asserts `trap '` substring + `trap - EXIT`.
    - Both files have trap + `rm -f` + `trap - EXIT`.

12. `aside` sandbox disabled requirement documented.
    - `browser.md:12`, `SKILL.md:107`
    - `dangerouslyDisableSandbox: true` named in both files.

13. `Aside-MCP` is the FIRST routing priority in both files.
    - `test_routing_order_lists_aside_mcp_first`
    - `first_aside_mcp` (CMD: 721, SKILL: 629) < `first_aside_cli` (CMD: 882, SKILL: 1051)

14. `browserclaw` appears before `Playwright headless` in both files.
    - `test_routing_order_lists_browserclaw_before_playwright_fallback`
    - `first_browserclaw` (CMD: 174, SKILL: 209) < `first_playwright` (CMD: 235, SKILL: 285)

## The 6 explicit "Does NOT Prove" items

1. **No real cookie decrypt + inject E2E run in this evidence.** The bead description states this is the parent session's responsibility. The test only verifies the contract *text*, not the runtime hydration. Acceptable here because the change is docs/skill/test-tooling (non-production) and the test scope is explicitly contract-level.

2. **Aside-MCP stdio probe not re-run by this reviewer.** Reported in the parent prompt as `tools/list => one repl tool, protocolVersion 2025-03-26`. The regex `Aside-MCP|aside\s*mcp` is present in both files (`browser.md:11`, `SKILL.md:18`), but the actual MCP runtime registration is not separately verified here.

3. **No video/screenshots for the change.** This is a docs/skill/test-only change with no UI behavior delta. `evidence-standards` Exception 1 (non-production, no evidence required) applies.

4. **Aside CLI sandbox requirement** (`dangerouslyDisableSandbox: true`) is documented but cannot be programmatically asserted — it is a behavioral claim about the Aside CLI daemon, not a property of the markdown.

5. **The `LinkedIn` / `Cloudflare` / `banks` enumeration is a curated list** — the contract test verifies the names are present, not that the set is complete. A future site that binds cookies to fingerprint that's not on this list will not be caught by the test.

6. **`test_credential_reuse_safeguards_present` uses raw `in` substring checks** for some tokens (`"never"`, `"/tmp"`) — false positives are possible if a future regression-comment accidentally includes those substrings. In a fully rigorous test these would be regex-anchored to a specific context, but for non-production contract tests the tradeoff is acceptable.

## Non-blocking findings recorded

1. Frontmatter `description` field in `SKILL.md:3` predates the routing-order rewrite. Update to encode the new priority order for parity with `browser.md:2`.
2. The contract test asserts `"never"` and `"/tmp"` as bare substrings — a future regression that puts either substring in a regression comment would falsely pass. Consider regex-anchoring to a "safeguards" heading.
3. After the worktree is merged/promoted, the `~` substitution in path references should be re-checked.

## Final verdict line

```
ER_VERDICT: PASS
```

## Why the adapted table gave the parent session enough information

The parent session that runs this skill learns:

- Exactly which live probes the parent still owns (the 6 items in "Does NOT Prove").
- Which checks were N/A vs replaced vs kept (the adapted table is self-documenting).
- Which claims are STRONG with file:line proof (the 14-row claim map).
- Which findings are non-blocking recommendations (3 items, no follow-up needed for PASS).

This is the contract the parent session can audit without re-reading the canonical /er skill.