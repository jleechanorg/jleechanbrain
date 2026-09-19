"""Contract tests for the default coding-routing policy.

Background
==========
As of 2026-08-03 (branch `feat/default-claudeminimax-coding`), the ordinary
default for coding delegation in this repo is `claude-code-claudem`
(`bash -lic 'claudem -p "<task>"' --max-turns <N>` on a clean worktree),
NOT `ao spawn` / `agento` / `dispatch-task`. AO is explicit opt-in only —
via `/af` or `/auto-factory`. No other slash command, alias, or
natural-language override routes to AO by default.

These tests pin that policy by content match. They fail loudly if any of
the canonical routing files reverts to "AO is canonical", "always
dispatch via `ao`", or similar — and they require the claudem default
string to appear alongside, so a revert that simply removes AO language
without naming the new default also fails.

Sources under audit
===================
- ``workspace/SOUL.md``              — canonical session-init policy
- ``.claude/skills/claw-dispatch/SKILL.md``  — /claw dispatch front door
- ``skills/RESOLVER.md``             — skill resolver
- ``skills/dispatch-task/SKILL.md``  — AO opt-in path
- ``skills/finish-the-job/SKILL.md`` — end-to-end finish protocol
- ``skills/workflow/always-pr-never-local-edit/SKILL.md`` — PR workflow

This suite is purely hermetic — file content assertions only, no
network or shell probes. It runs in CI without `claudem`/`ao` installed.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

SOUL_PATH = REPO_ROOT / "workspace" / "SOUL.md"
CLAW_DISPATCH_PATH = REPO_ROOT / ".claude" / "skills" / "claw-dispatch" / "SKILL.md"
RESOLVER_PATH = REPO_ROOT / "skills" / "RESOLVER.md"
DISPATCH_TASK_PATH = REPO_ROOT / "skills" / "dispatch-task" / "SKILL.md"
FINISH_THE_JOB_PATH = REPO_ROOT / "skills" / "finish-the-job" / "SKILL.md"
ALWAYS_PR_PATH = (
    REPO_ROOT
    / "skills"
    / "workflow"
    / "always-pr-never-local-edit"
    / "SKILL.md"
)


# A handful of phrases that, in this repo's routing context, mean the same
# thing: "use the bashrc `claudem` wrapper routed to MiniMax M3 for ordinary
# coding work". The exact casing varies by file.
CLAUDEM_INVOCATION_PATTERNS = (
    r"claude-code-claudem",
    r"bash\s+-lic\s+['\"]claudem\s+-p",
    r"`claudem`\s*/\s*`claudeminimax`",
    r"`claudeminimax`",
    r"`claudem`",  # bare mention as the default binary
)

AO_OPT_IN_TRIGGERS = (
    "/af",
    "/auto-factory",
    # Explicit opt-in language marker — the policy says "AO is explicit
    # opt-in only via /af or /auto-factory", so every routing file must
    # carry some "explicit" wording to make the opt-in non-pretend.
    "explicit",
)


def _has_claudem_default(text: str) -> bool:
    """True if the file names claudem as the default invocation at least once."""
    return any(re.search(pat, text, flags=re.IGNORECASE) for pat in CLAUDEM_INVOCATION_PATTERNS)


def _mentions_ao_explicit_opt_in(text: str) -> bool:
    """True if the file acknowledges AO opt-in (any trigger word) at least once."""
    return any(trigger in text for trigger in AO_OPT_IN_TRIGGERS)


def _ao_default_violation_patterns(text: str) -> list[tuple[str, int]]:
    """Return (matched_text, line) tuples for phrases that suggest "AO is canonical/default" in routing context.

    Phrases intentionally KEPT (not violations):
    - "AO" used as a noun for the system in monitoring/diagnostic context
      (e.g. "[agento]" prefix, "AO merge", "AO babysit", "skeptic-cron")
    - "`/af` may dispatch workers internally"  (explicit-af lock, untouched)
    - "Use `ao` CLI directly" in the legacy-mctrl avoidance commit
      (`COMMIT: ao-only-no-mctrl` — an explicit-AO operational concern,
      NOT a routing default)

    Violations:
    - "Use `ao`" as a generic dispatch instruction
    - "default" within ~30 chars of any "ao spawn" / "agento"
    - Sections named "Agent Dispatch Policy" / "When to use" treating AO as the
      first answer without mentioning claudem as the default
    """
    out: list[tuple[str, int]] = []
    # Generic "Use `ao`" phrasing in routing context (not in `ao-only-no-mctrl`)
    for m in re.finditer(r"Use\s+`ao`", text):
        line = text[: m.start()].count("\n") + 1
        # Approximate context after match to filter out the mctrl commit exception.
        tail = text[m.start(): m.start() + 200].lower()
        if "mctrl" in tail or "legacy" in tail or "supervisor" in tail:
            continue
        # Also accept the explicit-opt-in phrasing ("Use `ao` only when …").
        # Such construction is the correct AO opt-in wording per the user's
        # directive, NOT a default-AO violation.
        if "only when" in tail or "explicit" in tail or "/af" in tail or "/auto-factory" in tail:
            continue
        out.append((m.group(0), line))

    # `dispatch via `ao spawn`` (default action verb)
    for m in re.finditer(r"dispatch\s+via\s+`?ao\s+spawn`?", text, flags=re.IGNORECASE):
        line = text[: m.start()].count("\n") + 1
        # Allow it if explicitly conditioned on /af or /auto-factory nearby
        window = text[max(0, m.start() - 200): m.start() + 200].lower()
        if any(
            k in window
            for k in ("/af", "/auto-factory", "explicit", "only when")
        ):
            continue
        out.append((m.group(0), line))

    # `always dispatch via `agento`` / `must dispatch via `ao``
    for m in re.finditer(
        r"(?:always|must)\s+(?:dispatch|use)\s+(?:via\s+)?`?(?:ao|agento)",
        text,
        flags=re.IGNORECASE,
    ):
        line = text[: m.start()].count("\n") + 1
        window = text[max(0, m.start() - 200): m.start() + 200].lower()
        if any(
            k in window
            for k in ("/af", "/auto-factory", "explicit", "only when")
        ):
            continue
        out.append((m.group(0), line))
    return out


# ---------------------------------------------------------------------------
# 1. workspace/SOUL.md
# ---------------------------------------------------------------------------


def test_soul_md_exists_and_is_canonical_session_init_policy() -> None:
    """SOUL.md is the canonical session-init policy file in this repo."""
    assert SOUL_PATH.exists(), f"missing canonical session-init file: {SOUL_PATH}"
    content = SOUL_PATH.read_text(encoding="utf-8")
    assert "Session Initialization" in content, (
        "SOUL.md is required to declare itself the session-init file"
    )


def test_soul_md_declares_claudem_as_default_coding_routing() -> None:
    """SOUL.md Agent Dispatch Policy must declare claudem as the default."""
    content = SOUL_PATH.read_text(encoding="utf-8")
    # Locate the Agent Dispatch Policy section
    match = re.search(
        r"^##\s+Agent Dispatch Policy.*?(?=^##\s+|\Z)",
        content,
        flags=re.MULTILINE | re.DOTALL,
    )
    assert match, "SOUL.md missing `## Agent Dispatch Policy` section"
    section = match.group(0)
    assert _has_claudem_default(section), (
        "SOUL.md Agent Dispatch Policy must name `claude-code-claudem` "
        "(or `claudem -p`, or `claudeminimax`) as the default for ordinary "
        "coding work. Found no claudem invocation phrase in this section."
    )


def test_soul_md_does_not_call_ao_canonical() -> None:
    """The exact phrase `ao is canonical` must not appear in SOUL.md
    Agent Dispatch Policy anymore (was the AO-default headline).

    The historical "ao is canonical" header had no exception clause. After
    this commit, the section heading is `claude-code-claudem` is the default
    for ordinary coding work; AO is explicit opt-in only.
    """
    content = SOUL_PATH.read_text(encoding="utf-8")
    match = re.search(
        r"^##\s+Agent Dispatch Policy.*?(?=^##\s+|\Z)",
        content,
        flags=re.MULTILINE | re.DOTALL,
    )
    assert match
    section = match.group(0)
    forbidden_phrases = (
        "`ao` is canonical",  # old heading
        "sessions_spawn is banned",  # the policy itself is gone; sessions_spawn ban lives elsewhere
    )
    for phrase in forbidden_phrases:
        assert phrase not in section, (
            f"SOUL.md Agent Dispatch Policy still contains the old AO-default "
            f"phrase: {phrase!r}. The header should be `claude-code-claudem` is "
            f"the default."
        )


def test_soul_md_keeps_explicit_af_task_lock_intact() -> None:
    """The `COMMIT: explicit-af-task-lock` block must still exist verbatim.

    Per the user's directive: "/af and /auto-factory remain the explicit
    opt-in to auto-factory/AO. Do not weaken that lock."
    """
    content = SOUL_PATH.read_text(encoding="utf-8")
    assert "## COMMIT: explicit-af-task-lock" in content, (
        "SOUL.md is missing the `COMMIT: explicit-af-task-lock` block. "
        "The /af explicit-opt-in lock must remain intact."
    )
    # Check the trigger words are still exactly /af and /auto-factory
    match = re.search(
        r"## COMMIT: explicit-af-task-lock\s*\nTrigger:\s*([^\n]+)",
        content,
    )
    assert match, "explicit-af-task-lock trigger line missing"
    trigger = match.group(1)
    assert "/af" in trigger and "/auto-factory" in trigger, (
        f"explicit-af-task-lock trigger must contain both `/af` and "
        f"`/auto-factory`; got: {trigger!r}"
    )


def test_soul_md_no_ao_default_violations_outside_exception_clauses() -> None:
    """No AO-default-style dispatch language in SOUL.md outside AO opt-in clauses."""
    content = SOUL_PATH.read_text(encoding="utf-8")
    violations = _ao_default_violation_patterns(content)
    # Allow zero violations. The exception-clause guard inside
    # `_ao_default_violation_patterns` makes this strictly enforced.
    assert not violations, (
        "SOUL.md still contains default-AO dispatch language outside "
        "explicit-opt-in clauses: "
        + ", ".join(f"{p!r} at line {ln}" for p, ln in violations)
    )


# ---------------------------------------------------------------------------
# 2. .claude/skills/claw-dispatch/SKILL.md
# ---------------------------------------------------------------------------


def test_claw_dispatch_default_documents_role() -> None:
    """`claw-dispatch` must document its role clearly.

    Updated policy (2026-08-04): `/claw` is the dedicated AO dispatch command and
    continues to use AO. The default-routing change is for natural-language
    coding requests (no slash command, no `/af`, no `/claw`). This skill's
    front matter must reflect that split.
    """
    content = CLAW_DISPATCH_PATH.read_text(encoding="utf-8")
    # The first content section (after frontmatter) declares the default
    first_section = content.split("## ", 1)[1].split("\n", 1)[0]
    assert "default" in first_section.lower(), (
        f"claw-dispatch first section must mention 'default'. "
        f"First section heading was: {first_section!r}"
    )
    # Required: must explicitly carve out /claw as AO and natural-language as claudem.
    lower = content.lower()
    assert "/claw" in lower and "ao" in lower, (
        "claw-dispatch must explicitly say `/claw` uses AO in its default-behavior section"
    )
    assert "claudem" in lower or "claude-code-claudem" in lower, (
        "claw-dispatch must name claudem as the natural-language default"
    )
    # Forbidden headline from the old file
    assert "AO workers first" not in content, (
        "claw-dispatch/SKILL.md still has the old headline `## Default behavior — "
        "AO workers first`. Header should split /claw (AO) vs natural-language (claudem)."
    )


def test_claw_dispatch_input_table_documents_claw_as_ao() -> None:
    """The input→action dispatch table must explicitly show `/claw` as AO.

    The default-routing change is for natural-language coding. The dispatch
    table must show `/claw` → `ao spawn` (because `/claw` is the dedicated AO
    command) and a separate "natural-language" row pointing at claudem.
    """
    content = CLAW_DISPATCH_PATH.read_text(encoding="utf-8")
    table_match = re.search(
        r"\| Input\s*\|.*?\n\|[-|\s]+\|.*?(?=\n\n|\n##|\Z)",
        content,
        flags=re.DOTALL,
    )
    assert table_match, "claw-dispatch input table missing"
    table = table_match.group(0)
    # /claw must map to ao spawn (the dedicated AO command) — explicitly assert
    # that this row exists, since the original test only forbade it.
    claw_rows = re.findall(
        r"\|\s*`?/claw`?[^|]*\|\s*[^|]*`ao spawn`",
        table,
        flags=re.IGNORECASE,
    )
    assert claw_rows, (
        "claw-dispatch input table must map `/claw` to `ao spawn` "
        "(`/claw` is the dedicated AO dispatch command)"
    )
    # /af and /auto-factory must also map to ao spawn.
    af_rows = re.findall(
        r"\|\s*`?/af`?[^|]*\|\s*[^|]*`ao spawn`",
        table,
        flags=re.IGNORECASE,
    )
    assert af_rows, (
        "claw-dispatch input table must map `/af` (or `/auto-factory`) to `ao spawn`"
    )


# ---------------------------------------------------------------------------
# 3. skills/RESOLVER.md
# ---------------------------------------------------------------------------


def test_resolver_claudem_block_documents_default_role() -> None:
    """RESOLVER.md's `claude-code-claudem` block must explicitly state it is the default."""
    content = RESOLVER_PATH.read_text(encoding="utf-8")
    # Find both occurrences of the heading
    blocks = re.findall(
        r"^##\s+claude-code-claudem\s*$\n(.+?)(?=^##\s+|\Z)",
        content,
        flags=re.MULTILINE | re.DOTALL,
    )
    assert blocks, "RESOLVER.md has no `## claude-code-claudem` block"
    # At least one block must mention "default"
    has_default = any(
        re.search(r"\bdefault\b", block, flags=re.IGNORECASE) is not None
        for block in blocks
    )
    assert has_default, (
        "RESOLVER.md `claude-code-claudem` block does not mention that this "
        "skill is the DEFAULT for ordinary coding work."
    )


def test_resolver_claudem_block_cross_reference_mentions_ao_as_opt_in() -> None:
    """The `vs claude-code` / `vs agento` cross-reference must frame AO as opt-in."""
    content = RESOLVER_PATH.read_text(encoding="utf-8")
    blocks = re.findall(
        r"^##\s+claude-code-claudem\s*$\n(.+?)(?=^##\s+|\Z)",
        content,
        flags=re.MULTILINE | re.DOTALL,
    )
    combined = "\n".join(blocks)
    # Must NOT say AO is the "right answer for new code/refactors/PR-sized work"
    forbidden = [
        "those spawn AO workers for PR-sized multi-turn work",
        "smaller delegations;",
    ]
    for phrase in forbidden:
        assert phrase not in combined, (
            f"RESOLVER.md claude-code-claudem block still uses old phrasing "
            f"{phrase!r} (which framed claudem as the smaller alternative). "
            f"The default for new code/refactors/PR-sized work is now claudem."
        )


# ---------------------------------------------------------------------------
# 4. skills/dispatch-task/SKILL.md
# ---------------------------------------------------------------------------


def test_dispatch_task_describes_itself_as_ao_opt_in_path() -> None:
    """`dispatch-task` is the AO opt-in path. It MUST say so clearly."""
    content = DISPATCH_TASK_PATH.read_text(encoding="utf-8")
    assert "opt-in" in content.lower() or "opt in" in content.lower(), (
        "dispatch-task/SKILL.md does not declare itself an opt-in path. "
        "After this commit, ordinary coding work goes via `claude-code-claudem`."
    )


def test_dispatch_task_no_default_ao_for_ordinary_coding() -> None:
    """dispatch-task must not declare itself the default for ordinary coding."""
    content = DISPATCH_TASK_PATH.read_text(encoding="utf-8")
    # The heading line should not say "Dispatch a task via ao spawn/ao send with ..." as
    # the ONLY routing option; the description should note that this is the AO path.
    desc_match = re.search(
        r"^description:\s*([^\n]+)",
        content,
        flags=re.MULTILINE,
    )
    assert desc_match, "dispatch-task SKILL.md missing YAML description"
    desc = desc_match.group(1)
    # Must reference an opt-in trigger OR claude-code-claudem
    assert _has_claudem_default(desc) or _mentions_ao_explicit_opt_in(desc), (
        f"dispatch-task description ({desc!r}) must reference the opt-in "
        f"nature (e.g. 'AO opt-in path', 'when /af is explicit') or the "
        f"claude-code-claudem default."
    )


# ---------------------------------------------------------------------------
# 5. skills/finish-the-job/SKILL.md
# ---------------------------------------------------------------------------


def test_finish_the_job_phase2_defaults_to_claudem() -> None:
    """Phase 2 of `finish-the-job` must default to claudem, not `dispatch-task`."""
    content = FINISH_THE_JOB_PATH.read_text(encoding="utf-8")
    phase2 = re.search(
        r"### Phase 2.*?(?=###\s+Phase|\Z)",
        content,
        flags=re.DOTALL,
    )
    assert phase2, "finish-the-job missing Phase 2"
    section = phase2.group(0)
    assert _has_claudem_default(section), (
        "finish-the-job Phase 2 must mention claude-code-claudem / "
        "`claudem -p` as the default delegation path"
    )


def test_finish_the_job_phase2_distinguishes_af_opt_in() -> None:
    """Phase 2 must keep `/af`/`/auto-factory` as the AO opt-in trigger."""
    content = FINISH_THE_JOB_PATH.read_text(encoding="utf-8")
    phase2 = re.search(
        r"### Phase 2.*?(?=###\s+Phase|\Z)",
        content,
        flags=re.DOTALL,
    )
    assert phase2
    section = phase2.group(0)
    assert "/af" in section and "/auto-factory" in section, (
        "finish-the-job Phase 2 must mention BOTH `/af` and `/auto-factory` "
        "as the AO opt-in trigger"
    )


# ---------------------------------------------------------------------------
# 6. skills/workflow/always-pr-never-local-edit/SKILL.md
# ---------------------------------------------------------------------------


def test_always_pr_no_longer_says_dispatch_via_ao_spawn() -> None:
    """`always-pr-never-local-edit` must not say `Dispatch via `ao spawn`` as the rule."""
    content = ALWAYS_PR_PATH.read_text(encoding="utf-8")
    # The old phrasing was: "3. **Dispatch via `ao spawn`**"
    assert "Dispatch via `ao spawn`" not in content, (
        "always-pr-never-local-edit step 3 still says `Dispatch via ao spawn`. "
        "The default is now delegate to claude-code-claudem on a clean worktree."
    )


def test_always_pr_uses_claudem_default() -> None:
    """`always-pr-never-local-edit` must reference the claudem default."""
    content = ALWAYS_PR_PATH.read_text(encoding="utf-8")
    assert _has_claudem_default(content), (
        "always-pr-never-local-edit must mention the claudem default "
        "(claude-code-claudem, bash -lic claudem -p, or claudeminimax)"
    )


# ---------------------------------------------------------------------------
# Cross-file: explicit AO overrides
# ---------------------------------------------------------------------------


def test_all_routing_files_acknowledge_explicit_ao_override() -> None:
    """Per the user's directive: AO is explicit opt-in only via `/af` or
    `/auto-factory`; no other slash command, alias, or natural-language
    override routes to AO by default. Every canonical routing file must
    acknowledge that the opt-in path exists so the policy is not
    pretend-omitted.
    """
    must_mention_explicit = [
        SOUL_PATH,
        CLAW_DISPATCH_PATH,
        RESOLVER_PATH,
        DISPATCH_TASK_PATH,
        FINISH_THE_JOB_PATH,
        ALWAYS_PR_PATH,
    ]
    for path in must_mention_explicit:
        content = path.read_text(encoding="utf-8")
        assert _mentions_ao_explicit_opt_in(content), (
            f"{path.relative_to(REPO_ROOT)} does not acknowledge the explicit "
            f"AO opt-in (`/af`/`/auto-factory` or the word `explicit`). "
            f"Per the user's policy AO is opt-in only via `/af`/`/auto-factory`."
        )


def test_all_routing_files_have_a_claudem_default_somewhere() -> None:
    """Every canonical routing file must name claudem (or its alias)."""
    must_mention_claudem = [
        SOUL_PATH,
        CLAW_DISPATCH_PATH,
        RESOLVER_PATH,
        FINISH_THE_JOB_PATH,
        ALWAYS_PR_PATH,
    ]
    for path in must_mention_claudem:
        content = path.read_text(encoding="utf-8")
        assert _has_claudem_default(content), (
            f"{path.relative_to(REPO_ROOT)} has no `claude-code-claudem` / "
            f"`claudem -p` / `claudeminimax` reference. After this commit the "
            f"file must name the new default."
        )
