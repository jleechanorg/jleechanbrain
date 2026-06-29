"""Tests verifying that the domain lock integration is completely retired."""

from __future__ import annotations

from pathlib import Path
import pytest


def test_domain_lock_module_not_found() -> None:
    """Verify that orchestration.domain_lock_integration cannot be imported."""
    with pytest.raises(ImportError):
        import orchestration.domain_lock_integration  # type: ignore


def test_no_references_in_codebase() -> None:
    """Verify there are no occurrences of domain_lock_integration or domain_lock in the repo."""
    repo_root = Path(__file__).resolve().parents[1]

    matches = []
    # Exclude directories that are not part of the active codebase or contain build/cache/tool files
    exclude_dirs = {
        ".git",
        ".pytest_cache",
        ".venv",
        "venv",
        "__pycache__",
        ".gemini",
        ".openclaw",
        ".claude",
    }
    exclude_files = {"test_domain_lock_retirement.py"}

    for path in repo_root.rglob("*"):
        if any(part in exclude_dirs for part in path.parts):
            continue
        if path.name in exclude_files:
            continue
        if not path.is_file():
            continue
        try:
            content = path.read_text(encoding="utf-8", errors="ignore")
            if "domain_lock" in content:
                for line_idx, line in enumerate(content.splitlines(), 1):
                    if "domain_lock" in line:
                        matches.append(
                            f"{path.relative_to(repo_root)}:{line_idx}: {line.strip()}"
                        )
        except Exception:
            pass

    assert len(matches) == 0, f"Found remaining references to domain_lock in codebase: {matches}"

