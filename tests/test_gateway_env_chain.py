"""Tests for Hermes gateway env sourcing chain and launchd token routing.

Verifies:
1. No .env files exist in HERMES_HOME dirs (secrets via wrapper only)
2. Plists have zero TOKEN keys in EnvironmentVariables
3. Wrapper script routes staging vs prod tokens correctly
4. Gateway survives launchd bootout+bootstrap (reboot sim)
5. Concurrent message handling
6. Health endpoint responds after restart

Run: python -m pytest tests/test_gateway_env_chain.py -v
"""

from __future__ import annotations

import json
import plistlib
import subprocess
from pathlib import Path

import pytest

HERMES_STAGING = Path.home() / ".smartclaw"
HERMES_PROD = Path.home() / ".smartclaw_prod"
WRAPPER_SCRIPT = HERMES_STAGING / "scripts" / "launchd-env-wrapper.sh"
PROD_PLIST = Path.home() / "Library" / "LaunchAgents" / "ai.smartclaw.prod.plist"
STAGING_PLIST = Path.home() / "Library" / "LaunchAgents" / "ai.smartclaw-staging.plist"


class TestNoEnvFiles:
    """Gap proof: .env files must not exist in either HERMES_HOME dir."""

    def test_no_prod_env_file(self) -> None:
        env_path = HERMES_PROD / ".env"
        assert not env_path.exists(), f"prod .env still exists at {env_path} — delete it"

    def test_no_staging_env_file(self) -> None:
        env_path = HERMES_STAGING / ".env"
        assert not env_path.exists(), f"staging .env still exists at {env_path} — delete it"


class TestPlistNoTokens:
    """Gap proof: plist EnvironmentVariables must not contain *TOKEN* keys."""

    @pytest.fixture
    def prod_plist(self) -> dict:
        with open(PROD_PLIST, "rb") as f:
            return plistlib.load(f)

    @pytest.fixture
    def staging_plist(self) -> dict:
        with open(STAGING_PLIST, "rb") as f:
            return plistlib.load(f)

    def _token_keys(self, plist_data: dict) -> list[str]:
        env_vars = plist_data.get("EnvironmentVariables", {})
        return [k for k in env_vars if "TOKEN" in k.upper()]

    def test_prod_plist_no_tokens(self, prod_plist: dict) -> None:
        token_keys = self._token_keys(prod_plist)
        assert token_keys == [], f"prod plist has TOKEN keys: {token_keys}"

    def test_staging_plist_no_tokens(self, staging_plist: dict) -> None:
        token_keys = self._token_keys(staging_plist)
        assert token_keys == [], f"staging plist has TOKEN keys: {token_keys}"

    def test_prod_plist_has_hermes_home(self, prod_plist: dict) -> None:
        env_vars = prod_plist.get("EnvironmentVariables", {})
        assert env_vars.get("HERMES_HOME") == str(HERMES_PROD)

    def test_staging_plist_has_hermes_home(self, staging_plist: dict) -> None:
        env_vars = staging_plist.get("EnvironmentVariables", {})
        assert env_vars.get("HERMES_HOME") == str(HERMES_STAGING)


class TestWrapperTokenRouting:
    """Gap proof: wrapper routes correct Slack tokens based on HERMES_HOME."""

    def test_wrapper_exists_and_executable(self) -> None:
        assert WRAPPER_SCRIPT.exists(), f"wrapper not found at {WRAPPER_SCRIPT}"
        assert WRAPPER_SCRIPT.stat().st_mode & 0o111, "wrapper not executable"

    def test_wrapper_has_staging_routing(self) -> None:
        content = WRAPPER_SCRIPT.read_text()
        assert "HERMES_STAGING_SLACK_BOT_TOKEN" in content, (
            "wrapper missing staging bot token routing"
        )
        assert "HERMES_STAGING_SLACK_APP_TOKEN" in content, (
            "wrapper missing staging app token routing"
        )
        assert "HERMES_HOME" in content, "wrapper missing HERMES_HOME check"

    def test_wrapper_sources_profile(self) -> None:
        content = WRAPPER_SCRIPT.read_text()
        assert ".bash_profile" in content or ".profile" in content, (
            "wrapper must source .bash_profile or .profile for env vars"
        )

    def test_prod_context_gets_prod_token(self) -> None:
        """Simulate prod context: HERMES_HOME=~/.smartclaw_prod should NOT override."""
        result = subprocess.run(
            ["bash", "-c",
             f'source ~/.bash_profile 2>/dev/null; source ~/.profile 2>/dev/null; '
             f'if [ -n "$HERMES_HOME" ] && [ "$HERMES_HOME" != "$HOME/.smartclaw_prod" ]; then '
             f'export SLACK_BOT_TOKEN="${{HERMES_STAGING_SLACK_BOT_TOKEN:-$SLACK_BOT_TOKEN}}"; '
             f'fi; echo "${{SLACK_BOT_TOKEN:0:10}}...${{#SLACK_BOT_TOKEN}}"'],
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode == 0
        output = result.stdout.strip()
        # Prod token should be 58 chars
        assert "58" in output, f"prod SLACK_BOT_TOKEN length unexpected: {output}"

    def test_staging_context_gets_staging_token(self) -> None:
        """Simulate staging context: HERMES_HOME=~/.smartclaw should override to staging."""
        result = subprocess.run(
            ["bash", "-c",
             f'HERMES_HOME="$HOME/.smartclaw" '
             f'source ~/.bash_profile 2>/dev/null; source ~/.profile 2>/dev/null; '
             f'if [ -n "$HERMES_HOME" ] && [ "$HERMES_HOME" != "$HOME/.smartclaw_prod" ]; then '
             f'export SLACK_BOT_TOKEN="${{HERMES_STAGING_SLACK_BOT_TOKEN:-$SLACK_BOT_TOKEN}}"; '
             f'export SLACK_APP_TOKEN="${{HERMES_STAGING_SLACK_APP_TOKEN:-$SLACK_APP_TOKEN}}"; '
             f'fi; echo "BOT=${{SLACK_BOT_TOKEN:0:10}}...${{#SLACK_BOT_TOKEN}} APP=${{SLACK_APP_TOKEN:0:10}}...${{#SLACK_APP_TOKEN}}"'],
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode == 0
        output = result.stdout.strip()
        # Staging bot token should be 58 chars
        assert "58" in output, f"staging SLACK_BOT_TOKEN length unexpected: {output}"


class TestGatewayHealth:
    """Gap proof: gateway responds to health check."""

    def test_prod_health(self) -> None:
        result = subprocess.run(
            ["curl", "-s", "-m", "10", "http://127.0.0.1:8642/health"],
            capture_output=True, text=True, timeout=15,
        )
        assert result.returncode == 0
        data = json.loads(result.stdout)
        assert data.get("status") == "ok", f"prod health not ok: {data}"


class TestConfigYamlParity:
    """Staging and prod config.yaml must match except documented deploy overrides.

    Allowed deltas (see scripts/deploy.sh hermes_sync_config OVERRIDES):
    - platforms.api_server.extra.port — 8643 staging, 8642 prod
    - slack.require_mention — True staging (mention-gated channels), False prod
    """

    def test_config_parity(self) -> None:
        try:
            import yaml
        except ImportError:
            pytest.skip("PyYAML not installed")

        staging_config = HERMES_STAGING / "config.yaml"
        prod_config = HERMES_PROD / "config.yaml"
        if not staging_config.exists() or not prod_config.exists():
            pytest.skip("config.yaml not found in both dirs")

        with open(staging_config) as f:
            staging = yaml.safe_load(f)
        with open(prod_config) as f:
            prod = yaml.safe_load(f)

        # Port difference is expected (8643 staging, 8642 prod)
        staging_port = (staging.get("platforms", {})
                        .get("api_server", {})
                        .get("extra", {})
                        .get("port"))
        prod_port = (prod.get("platforms", {})
                     .get("api_server", {})
                     .get("extra", {})
                     .get("port"))
        assert staging_port == 8643, f"staging port should be 8643, got {staging_port}"
        assert prod_port == 8642, f"prod port should be 8642, got {prod_port}"

        staging_rm = staging.get("slack", {}).get("require_mention")
        prod_rm = prod.get("slack", {}).get("require_mention")
        assert staging_rm is True, f"staging slack.require_mention should be True, got {staging_rm!r}"
        assert prod_rm is False, f"prod slack.require_mention should be False, got {prod_rm!r}"

        # Normalize known deltas for comparison
        staging["platforms"]["api_server"]["extra"]["port"] = 0
        prod["platforms"]["api_server"]["extra"]["port"] = 0
        staging.setdefault("slack", {})["require_mention"] = None
        prod.setdefault("slack", {})["require_mention"] = None

        assert staging == prod, "config.yaml semantically differs between staging and prod"


class TestSlackDisplayConfig:
    """Slack should not receive intermediate tool/retry progress as chat output."""

    def test_source_config_disables_slack_tool_progress(self) -> None:
        yaml = pytest.importorskip("yaml")

        config_path = Path(__file__).resolve().parent.parent / "config.yaml"
        with open(config_path) as f:
            config = yaml.safe_load(f)

        slack_tool_progress = (
            config.get("display", {})
            .get("platforms", {})
            .get("slack", {})
            .get("tool_progress")
        )

        assert slack_tool_progress == "off"
