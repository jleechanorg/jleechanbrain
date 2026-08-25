"""Tests verifying agy OpenAI compat shim configuration, flags ordering, and plist templating."""

from __future__ import annotations

from pathlib import Path

def test_agy_shim_flag_order_and_docs() -> None:
    """Verify that agy command uses --print immediately before prompt, and docstring uses port 8766."""
    repo_root = Path(__file__).resolve().parents[1]
    shim_py = repo_root / "scripts" / "agy_openai_shim.py"

    assert shim_py.exists()
    content = shim_py.read_text(encoding="utf-8")

    # 1. Verify that docstring references 127.0.0.1:8766 (not 8765)
    assert "127.0.0.1:8766 that translates" in content
    assert "127.0.0.1:8765" not in content

    # 2. Verify that --print is placed immediately before prompt
    # The command array construction should have '--print' followed by the positional prompt
    expected_order = '        "--print-timeout", str(AGY_TIMEOUT_SECONDS),\n        "--print",\n        prompt,'
    assert expected_order in content

def test_agy_shim_plist_template() -> None:
    """Verify that com.jleechan.agy-shim.plist.template uses a @VENV_PY@ placeholder instead of hardcoded venv path."""
    repo_root = Path(__file__).resolve().parents[1]
    plist_template = repo_root / "launchd" / "com.jleechan.agy-shim.plist.template"

    assert plist_template.exists()
    content = plist_template.read_text(encoding="utf-8")

    # The template should use @VENV_PY@ instead of @HOME@/.smartclaw/.venv/bin/python3
    assert "@VENV_PY@" in content
    assert "@HOME@/.smartclaw/.venv/bin/python3" not in content

def test_agy_shim_installer_substitution() -> None:
    """Verify that install-agy-shim.sh substitutes @VENV_PY@ in the plist template."""
    repo_root = Path(__file__).resolve().parents[1]
    installer = repo_root / "scripts" / "install-agy-shim.sh"

    assert installer.exists()
    content = installer.read_text(encoding="utf-8")

    # The installer should substitute @VENV_PY@ with the computed VENV_PY path
    assert "@VENV_PY@" in content

def test_agy_shim_concurrency_and_security() -> None:
    """Verify that agy_openai_shim.py has concurrency limits, lock protection on stats, and validation of X-Add-Dir."""
    repo_root = Path(__file__).resolve().parents[1]
    shim_py = repo_root / "scripts" / "agy_openai_shim.py"
    content = shim_py.read_text(encoding="utf-8")

    # 1. Semaphore initialization
    assert "_CONCURRENCY_SEMAPHORE = threading.Semaphore(" in content

    # 2. lock protection on stats copying during health check
    assert "with _LOCK:\n                stats_copy = dict(_STATS)" in content

    # 3. Secure design: X-Add-Dir is removed to prevent client-side workspace override
    assert "X-Add-Dir" not in content
    assert "os.path.realpath" not in content
    assert "os.path.commonpath" not in content
