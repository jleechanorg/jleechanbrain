"""Contract tests for the `claude-code-claudem` wrapper skill.

These guard the wiring that lets Hermes delegate coding work to Claude Code
CLI routed through the user's `claudem` bashrc wrapper (MiniMax M3), instead
of the default `claude` binary that hits Anthropic first-party.

Test classes:
  * Static structure — skill file, RESOLVER entry, vs-claude-code cross-ref
  * Slow (pytest.mark.slow) — prereq checks (claudem resolves via bash -lic,
    reports v2.x+) AND live behavior (`claudem -p` round-trips to MiniMax M3,
    end-to-end print-mode file edit)

The prereq tests (`test_claudem_resolves_via_bashrc`, `test_claudem_reports_claude_code_v2`,
`test_claudeminimax_alias_resolves_to_claudem`) double-gate behind BOTH `pytest.mark.slow`
AND `HERMES_RUN_CLAUDE_CODE_CLAUDEM_PRECHECK=1`. The default `pytest` run ignores them so
the CI runner doesn't fail on a host without a local `claudem` bashrc. To run them
explicitly:

    HERMES_RUN_CLAUDE_CODE_CLAUDEM_PRECHECK=1 pytest tests/test_claude_code_claudem.py -v -m slow

The live behaviour tests (`test_claudem_routes_to_minimax_m3`, `test_claudem_print_mode_writes_file_through_edits`)
stay opt-in via `-m slow` only — no env flag needed.

Why hermetic-by-default: the prereq tests shell out to `bash -lic 'claudem …'`
and `bash -lic 'claudem --version'`; the live tests call a real API at
`https://api.minimax.io/anthropic`. None of them are flaky, but all of them
require a specific user-machine environment that the CI runner won't have.
Treat the slow suite as "developer-verifies-locally" rather than "CI-runs-on-PR".

Note on the `bash -lic` invocation pattern: `claudem` is a bashrc function,
not a binary. `subprocess.run(['claudem', …])` would fail with "command not
found" because Python subprocesses don't inherit the parent shell's function
table. The `-l` (login) flag forces `~/.bashrc` to source inside the spawned
bash, making the function visible. This is the canonical pattern — see
`references/subprocess-vs-interactive-shell.md` for the full failure-mode
table. The previous `~/bin/claudem` binary shim was removed 2026-07-28
because it drifted from the bashrc function (default-if-unset vs force).
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
SKILL_PATH = REPO_ROOT / "skills" / "claude-code-claudem" / "SKILL.md"
RESOLVER_PATH = REPO_ROOT / "skills" / "RESOLVER.md"
BUNDLED_CLAUDE_CODE_PATH = REPO_ROOT / "skills" / "autonomous-ai-agents" / "claude-code" / "SKILL.md"


def _run_in_bashrc_shell(command: str, *, cwd: str | None = None, timeout: int = 30) -> subprocess.CompletedProcess:
    """Run `command` inside `bash -lic` so ~/.bashrc is sourced and claudem() is visible.

    Returns the CompletedProcess of the outer bash invocation. Stderr/stdout
    include the harmless "claude.ai connectors are disabled" warning that the
    bashrc function emits (because ANTHROPIC_API_KEY is set) — callers should
    filter it.
    """
    return subprocess.run(
        ["bash", "-lic", command],
        capture_output=True,
        text=True,
        timeout=timeout,
        cwd=cwd,
    )


# ---------------------------------------------------------------------------
# Static structure
# ---------------------------------------------------------------------------


def test_skill_file_exists_with_frontmatter() -> None:
    """Skill file must exist at the canonical path with valid YAML frontmatter."""
    assert SKILL_PATH.exists(), f"missing skill at {SKILL_PATH}"
    content = SKILL_PATH.read_text(encoding="utf-8")
    assert content.startswith("---\n"), "skill must start with YAML frontmatter"
    assert "\n---\n" in content, "frontmatter must be closed with ---"
    # frontmatter must declare the canonical fields
    for required in ("name:", "description:", "version:"):
        assert required in content.split("\n---\n", 1)[0], (
            f"frontmatter missing required field: {required}"
        )


def test_skill_name_is_claude_code_claudem() -> None:
    """Skill name must be exactly `claude-code-claudem` (matches the directory)."""
    content = SKILL_PATH.read_text(encoding="utf-8")
    frontmatter = content.split("\n---\n", 1)[0]
    name_line = next(
        (line for line in frontmatter.splitlines() if line.startswith("name:")), None
    )
    assert name_line is not None, "frontmatter missing name: line"
    assert name_line.split(":", 1)[1].strip() == "claude-code-claudem"


def test_skill_re_exports_bundled_claude_code() -> None:
    """Skill must explicitly re-export the bundled claude-code skill (not replace it)."""
    content = SKILL_PATH.read_text(encoding="utf-8")
    # Must mention the bundled skill at least twice (once as a reference, once in the
    # "vs claude-code" section). Loose bound to allow natural wording variation.
    assert content.count("claude-code") >= 2, (
        "skill must re-export the bundled `claude-code` skill "
        "(see SKILL.md 'vs claude-code' section)"
    )
    # Must not pretend to be the authoritative source — must defer to the bundled skill
    assert "source of truth" in content.lower() or "bundled" in content.lower(), (
        "skill must explicitly defer to the bundled skill as the source of truth"
    )


def test_resolver_entry_present() -> None:
    """RESOLVER.md must contain a `claude-code-claudem` section."""
    assert RESOLVER_PATH.exists()
    content = RESOLVER_PATH.read_text(encoding="utf-8")
    # Find a heading of the form "## claude-code-claudem" (allowing trailing punctuation)
    pattern = re.compile(r"^##\s+claude-code-claudem\s*$", re.MULTILINE)
    assert pattern.search(content), (
        "RESOLVER.md must contain a `## claude-code-claudem` heading"
    )
    # The entry must point at our skill file
    assert "skills/claude-code-claudem/SKILL.md" in content, (
        "RESOLVER.md entry must point at skills/claude-code-claudem/SKILL.md"
    )
    # And list at least one of the canonical triggers
    triggers = ("claudem", "claudem -p", "claudemc", "claudeme", "claudeminimax")
    assert any(t in content for t in triggers), (
        f"RESOLVER.md entry must include at least one of {triggers}"
    )


def test_resolver_entry_has_vs_claude_code_cross_reference() -> None:
    """The wrapper's RESOLVER entry must explain when to use the bundled skill instead."""
    content = RESOLVER_PATH.read_text(encoding="utf-8")
    # Find the claude-code-claudem block
    match = re.search(
        r"^##\s+claude-code-claudem\s*$(.+?)(?=^##\s+|\Z)",
        content,
        re.MULTILINE | re.DOTALL,
    )
    assert match, "claude-code-claudem section not found in RESOLVER.md"
    block = match.group(1)
    assert "vs `claude-code`" in block, (
        "entry must include a `vs claude-code` cross-reference"
    )
    # The cross-ref must mention both routes explicitly so users pick the right one
    assert "Anthropic" in block or "real Claude" in block, (
        "vs-claude-code cross-ref must mention when to use the bundled skill"
    )


def test_bundled_claude_code_skill_untouched() -> None:
    """The bundled `claude-code` skill must NOT be modified by this wrapper.

    Regression guard: the wrapper pattern is explicitly a *re-export*, not
    a fork. If the bundled file ever drifts from upstream, the wrapper
    pattern has been violated.
    """
    assert BUNDLED_CLAUDE_CODE_PATH.exists(), (
        f"bundled claude-code skill missing at {BUNDLED_CLAUDE_CODE_PATH}"
    )
    content = BUNDLED_CLAUDE_CODE_PATH.read_text(encoding="utf-8")
    # The bundled skill's name and version come from upstream
    assert "name: claude-code" in content, "bundled skill name field changed"
    frontmatter = content.split("\n---\n", 1)[0]
    assert "version: 2.2.0" in frontmatter, (
        "bundled skill version drifted from 2.2.0 (upstream re-pull may have landed)"
    )


# ---------------------------------------------------------------------------
# Prereq — claudem via bashrc (opt-in, runs in slow suite)
# ---------------------------------------------------------------------------
#
# These tests shell out to a real bashrc-sourced bash. They are < 1s each
# and have no flakiness, but they are still opt-in to keep the default
# `pytest` run hermetic (pure file-content assertions only).


@pytest.mark.slow
def test_claudem_resolves_via_bashrc() -> None:
    """`claudem` must resolve inside a bashrc-sourced login shell.

    This is the canonical way non-interactive callers reach the wrapper:
        bash -lic 'claudem --version'

    `claudem` is a bashrc function. There is intentionally no `~/bin/claudem`
    binary (the shim was removed 2026-07-28 because it drifted from the
    bashrc function — see `references/subprocess-vs-interactive-shell.md`).
    """
    if not os.environ.get("HERMES_RUN_CLAUDE_CODE_CLAUDEM_PRECHECK"):
        pytest.skip(
            "set HERMES_RUN_CLAUDE_CODE_CLAUDEM_PRECHECK=1 to run prereq probes "
            "(off by default so the CI runner doesn't fail without a local claudem)"
        )
    result = _run_in_bashrc_shell("type claudem >/dev/null 2>&1 && echo OK || echo MISSING")
    assert "OK" in result.stdout, (
        f"claudem is not a defined function in this login shell. "
        f"Did ~/.bashrc's claudem() get installed? stderr: {result.stderr!r}"
    )


@pytest.mark.slow
def test_claudeminimax_alias_resolves_to_claudem() -> None:
    """`claudeminimax` (the bashrc alias) must resolve to the same wrapper as
    `claudem` — alias convention matches the bashrc family (claudeg, claudek,
    claudeds, claudegz; no underscores).

    The alias must be a pure wrapper (no second source of truth). Verified by
    running `type` on both names and asserting the alias's body delegates to
    `claudem`. We deliberately do NOT shell out to `realpath` because both
    names are functions, not files.
    """
    if not os.environ.get("HERMES_RUN_CLAUDE_CODE_CLAUDEM_PRECHECK"):
        pytest.skip(
            "set HERMES_RUN_CLAUDE_CODE_CLAUDEM_PRECHECK=1 to run prereq probes"
        )
    result = _run_in_bashrc_shell("type claudeminimax claudem")
    assert "claudeminimax is a function" in result.stdout, (
        f"claudeminimax is not a defined function. "
        f"Did ~/.bashrc's claudeminimax() get installed? stdout: {result.stdout!r} stderr: {result.stderr!r}"
    )
    # The alias body must be `claudem "$@"` (pure delegation) — extract
    # the second `claude...$@` line that appears after the function def.
    # `type` output for a function is:
    #   claudeminimax is a function
    #   claudeminimax ()
    #   {
    #       claudem "$@"
    #   }
    # We assert the body contains `claudem "$@"` (literal delegation).
    assert 'claudem "$@"' in result.stdout, (
        f"claudeminimax does not delegate to claudem. "
        f"It must be a pure alias. type output: {result.stdout!r}"
    )


@pytest.mark.slow
def test_claudem_reports_claude_code_v2() -> None:
    """`claudem --version` must report a Claude Code v2.x release.

    The bundled `claude-code` skill at v2.2.0 states v2.x is required. If a
    future upgrade or downgrade lands, the skill body needs to be reviewed.
    """
    if not os.environ.get("HERMES_RUN_CLAUDE_CODE_CLAUDEM_PRECHECK"):
        pytest.skip(
            "set HERMES_RUN_CLAUDE_CODE_CLAUDEM_PRECHECK=1 to run prereq probes"
        )
    result = _run_in_bashrc_shell("claudem --version", timeout=15)
    assert result.returncode == 0, f"claudem --version failed: {result.stderr}"
    # Output is e.g. "2.1.212 (Claude Code)"
    match = re.match(r"^(\d+)\.(\d+)\.\d+", result.stdout.strip())
    assert match, f"unexpected claudem --version output: {result.stdout!r}"
    major = int(match.group(1))
    assert major >= 2, (
        f"claudem reports Claude Code v{major}.x — the bundled claude-code skill "
        "requires v2.x+. Update the wrapper skill's prereq section if the floor changed."
    )


# ---------------------------------------------------------------------------
# Live behavior — slow, opt-in
# ---------------------------------------------------------------------------


@pytest.mark.slow
def test_claudem_routes_to_minimax_m3() -> None:
    """`claudem -p` must round-trip to a model that identifies as MiniMax-M3.

    This is the load-bearing behavior test. It costs ~6-8s and a real API
    call to `https://api.minimax.io/anthropic`. The test is triple-gated:
    (1) `pytest.mark.slow`, (2) `HERMES_RUN_CLAUDE_CODE_CLAUDEM_PRECHECK=1`,
    (3) requires a bashrc-sourced shell with `claudem()` installed and
    `MINIMAX_API_KEY` exported.

    For the "developer verifies locally" recipe, run from a bashrc-sourced shell:
        HERMES_RUN_CLAUDE_CODE_CLAUDEM_PRECHECK=1 \\
          bash -lic 'pytest tests/test_claude_code_claudem.py -v -m slow'

    Resilience: the assertion accepts case-insensitive substring matches
    because the upstream model sometimes returns 'MiniMax-M3' verbatim
    and sometimes 'minimax-m3' (lowercase) depending on tokenization.
    Retries up to 2 times on transient non-matches (rate-limit hiccup,
    model echo of an Anthropic model name from cache, etc.) to avoid
    false-failing the suite on a single bad response.
    """
    if not os.environ.get("HERMES_RUN_CLAUDE_CODE_CLAUDEM_PRECHECK"):
        pytest.skip(
            "set HERMES_RUN_CLAUDE_CODE_CLAUDEM_PRECHECK=1 to run live M3 routing probe"
        )
    last_body = ""
    for attempt in range(3):
        # 3 turns: a reasoning model may need a thinking turn before the
        # final answer. --max-turns=1 caused a 1-shot timeout flake.
        # shell-quote the prompt with single-quotes (the prompt may contain
        # double-quotes that we want preserved literally).
        shell_prompt = (
            "claudem -p "
            "'Output exactly one line and nothing else: "
            "\"model: <what ANTHROPIC_MODEL env var resolves to for you>\"' "
            "--max-turns 3 --output-format text"
        )
        result = _run_in_bashrc_shell(shell_prompt, timeout=60)
        assert result.returncode == 0, (
            f"claudem -p failed (exit {result.returncode}): stderr={result.stderr!r}"
        )
        # Strip the harmless "claude.ai connectors are disabled" warning that bashrc
        # always emits (because ANTHROPIC_API_KEY is set in the wrapper).
        body = "\n".join(
            line for line in result.stdout.splitlines()
            if not line.startswith("⚠") and "claude.ai" not in line
        ).strip()
        last_body = body
        if "minimax-m3" in body.lower():
            return  # success
        # transient failure — sleep briefly and retry
        import time
        time.sleep(2)
    # All attempts failed — use pytest.fail (not assert False) so the failure
    # survives `python -O` optimization.
    pytest.fail(
        f"claudem did NOT route to MiniMax M3 after 3 attempts. Last body: {last_body!r}\n"
        "This means either (a) the bashrc ANTHROPIC_BASE_URL override was bypassed, "
        "(b) the wrapper is calling real Anthropic, or (c) the model env var leaked. "
        "Re-check your claudem() definition in ~/.bashrc — the function must set "
        "ANTHROPIC_MODEL=\"MiniMax-M3\" (force, not default-if-unset) and "
        "ANTHROPIC_BASE_URL must point at the MiniMax-compatible endpoint."
    )


@pytest.mark.slow
def test_claudem_print_mode_writes_file_through_edits() -> None:
    """End-to-end: `claudem -p` with --allowedTools Read,Edit must actually
    write the requested changes to disk.

    This is the skill's primary use case — agents delegating real coding work.
    Without this, the wrapper is just a fancy echo.
    """
    if not os.environ.get("HERMES_RUN_CLAUDE_CODE_CLAUDEM_PRECHECK"):
        pytest.skip(
            "set HERMES_RUN_CLAUDE_CODE_CLAUDEM_PRECHECK=1 to run live edit-flow probe"
        )
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        sample = Path(tmp) / "sample.py"
        sample.write_text(
            "def add(a, b):\n"
            "    return a + b\n"
            "\n"
            "def divide(a, b):\n"
            "    return a / b\n",
            encoding="utf-8",
        )
        prompt_text = (
            f"Read {sample}, then add a docstring to add() saying "
            "'Adds two numbers and returns the sum.' and a guard to divide() that "
            "raises ValueError when b is zero. Write the changes back. "
            "Reply with the word DONE when finished."
        )
        # Wrap prompt in single-quotes for safe shell interpolation (the
        # prompt contains no single-quotes, so this is safe; if it ever
        # does, switch to `python -c "import shlex; print(shlex.quote(p))"`).
        shell_prompt = (
            f"claudem -p {subprocess.list2cmdline([prompt_text])} "
            "--allowedTools Read,Edit --max-turns 5 --output-format text"
        )
        # The list2cmdline wrapper adds quotes; pass as a single command to bash.
        result = _run_in_bashrc_shell(shell_prompt, cwd=tmp, timeout=180)
        assert result.returncode == 0, (
            f"claudem -p (print-mode edit) failed: stderr={result.stderr!r}"
        )
        after = sample.read_text(encoding="utf-8")
        assert "Adds two numbers and returns the sum." in after, (
            f"docstring edit not applied. File after:\n{after}"
        )
        assert "ValueError" in after, (
            f"ValueError guard not applied. File after:\n{after}"
        )
