"""Tests for domain_lock_integration adapter."""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from merge_train.domain_lock import DomainHeldError


def test_registry_loads_from_yaml(tmp_path: Path) -> None:
    """The adapter loads file_domains.yaml and returns a valid Registry."""
    path = tmp_path / "file_domains.yaml"
    path.write_text(yaml.dump({
        "domains": {
            "test-domain": {
                "paths": ["src/foo/*.py"],
                "owners": ["@test"],
            }
        }
    }))

    from orchestration.domain_lock_integration import get_registry
    reg = get_registry(str(path))
    assert "test-domain" in reg.domains


def test_log_path_resolved(tmp_path: Path) -> None:
    """get_log returns a LockLog instance."""
    from orchestration.domain_lock_integration import get_log
    log = get_log(cwd=tmp_path)
    assert log is not None


def test_reserve_and_release_round_trip(tmp_path: Path) -> None:
    """Reserve a domain for a PR, then release it."""
    registry_file = tmp_path / "file_domains.yaml"
    registry_file.write_text(yaml.dump({
        "domains": {
            "test-domain": {
                "paths": ["src/foo.py"],
            }
        }
    }))

    from orchestration.domain_lock_integration import (
        reserve_domain_for_pr,
        release_domain_for_pr,
    )
    entries = reserve_domain_for_pr(
        pr_number=42,
        changed_files=["src/foo.py"],
        agent="test",
        branch="feat/test",
        registry_path=str(registry_file),
        cwd=tmp_path,
    )
    assert len(entries) >= 1
    assert entries[0].domain == "test-domain"

    released = release_domain_for_pr(pr_number=42, cwd=tmp_path)
    assert len(released) >= 1


def test_rollback_preserves_prior_reservation(tmp_path: Path) -> None:
    """When a second reserve_domain_for_pr fails, rollback only releases
    domains from the failed call — not a prior successful reservation."""
    registry_file = tmp_path / "file_domains.yaml"
    registry_file.write_text(yaml.dump({
        "domains": {
            "domain-a": {"paths": ["src/a.py"]},
            "domain-b": {"paths": ["src/b.py"]},
        }
    }))

    from orchestration.domain_lock_integration import (
        reserve_domain_for_pr,
        check_domain_conflict,
    )

    # PR 10 reserves domain-a successfully in call 1
    entries_a = reserve_domain_for_pr(
        pr_number=10,
        changed_files=["src/a.py"],
        registry_path=str(registry_file),
        cwd=tmp_path,
    )
    assert entries_a[0].domain == "domain-a"

    # PR 20 holds domain-b, so PR 10's attempt to reserve it will fail
    reserve_domain_for_pr(
        pr_number=20,
        changed_files=["src/b.py"],
        registry_path=str(registry_file),
        cwd=tmp_path,
    )

    # PR 10 tries to reserve domain-b in call 2 — should fail
    with pytest.raises(DomainHeldError):
        reserve_domain_for_pr(
            pr_number=10,
            changed_files=["src/b.py"],
            registry_path=str(registry_file),
            cwd=tmp_path,
        )

    # domain-a should still be held by PR 10 (rollback of call 2
    # only touched domains from that call, not the prior reservation)
    result = check_domain_conflict(
        changed_files=["src/a.py"],
        registry_path=str(registry_file),
        cwd=tmp_path,
    )
    assert not result.ok
    held_domains = [domain for domain, _entry in result.held]
    assert "domain-a" in held_domains


def test_check_detects_conflict(tmp_path: Path) -> None:
    """check_domain_conflict reports held domains."""
    registry_file = tmp_path / "file_domains.yaml"
    registry_file.write_text(yaml.dump({
        "domains": {
            "test-domain": {
                "paths": ["src/foo.py"],
            }
        }
    }))

    from orchestration.domain_lock_integration import (
        check_domain_conflict,
        reserve_domain_for_pr,
    )
    reserve_domain_for_pr(
        pr_number=99,
        changed_files=["src/foo.py"],
        registry_path=str(registry_file),
        cwd=tmp_path,
    )
    result = check_domain_conflict(
        changed_files=["src/foo.py"],
        registry_path=str(registry_file),
        cwd=tmp_path,
    )
    assert not result.ok
    assert len(result.held) >= 1
