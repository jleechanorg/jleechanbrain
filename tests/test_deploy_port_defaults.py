"""Tests verifying that deploy.sh defaults to port 8643 and propagates it correctly.

PR #619 corrected the watchdog port mapping on 2026-06-13 (prod 8642→8643,
staging 8643→8644) but deploy.sh was not updated in the same PR. This test
was updated alongside the deploy.sh fix to reflect the new canonical mapping
so `pytest tests/test_deploy_port_defaults.py` continues to pass.
"""

from __future__ import annotations

from pathlib import Path

def test_deploy_port_defaults_correct() -> None:
    """Verify that deploy.sh defaults to port 8643 and propagates it to checks."""
    repo_root = Path(__file__).resolve().parents[1]
    deploy_sh = repo_root / "scripts" / "deploy.sh"

    assert deploy_sh.exists()
    content = deploy_sh.read_text(encoding="utf-8")

    # 1. Verify that the default port is set to 8643 and is env-overridable
    assert 'PROD_PORT="${PROD_PORT:-8643}"' in content

    # 2. Verify that it is propagated to hermes-health.sh
    assert 'HERMES_HEALTH_PORT="$PROD_PORT" bash "$SCRIPT_DIR/hermes-health.sh"' in content

    # 3. Verify that it is propagated to hermes-canary.sh
    assert 'HERMES_CANARY_PORT="$PROD_PORT" bash "$SCRIPT_DIR/hermes-canary.sh"' in content
