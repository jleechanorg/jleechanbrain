"""Verify hermes_sync_config() covers the files that MUST be synced to prod.

This test catches regressions where a file that should be synced to prod
(e.g. a policy/config file tracked in git) is inadvertently removed from
the deploy sync list.

Also validates provider-key consistency in config.yaml: no provider name
should appear in both `providers` and `custom_providers`, and api_keys
should not be empty strings (except for local providers like ollama).

Run: python -m pytest tests/test_deploy_sync_completeness.py -v
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

HERMES_REPO = Path(os.environ.get("HERMES_REPO", str(Path.home() / ".smartclaw")))
DEPLOY_SCRIPT = HERMES_REPO / "scripts" / "deploy.sh"


def _parse_policy_loop_files(script_content: str) -> list[str]:
    """Extract files listed in the hermes_sync_config() policy files loop.

    The loop looks like:
      for policy_file in SOUL.md AGENTS.md TOOLS.md HEARTBEAT.md prefill.json agent-orchestrator.yaml; do
    Returns the list: ['SOUL.md', 'AGENTS.md', 'TOOLS.md', 'HEARTBEAT.md', 'prefill.json', 'agent-orchestrator.yaml']
    """
    match = re.search(
        r"# Policy files.*?\n\s+for policy_file in (.+?)\s*;?\s*do",
        script_content,
        re.DOTALL,
    )
    if not match:
        pytest.fail("Policy files loop not found in deploy.sh")
    return [f for f in match.group(1).split() if f]


def _parse_sync_dirs(script_content: str) -> list[str]:
    """Extract directories synced via rsync --delete in hermes_sync_config().

    Handles multi-line rsync commands with --exclude flags between
    the rsync invocation and the source/dest paths.
    """
    match = re.search(
        r"^hermes_sync_config\(\)\s*\{(.+?)\n^}\s*$",
        script_content,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        pytest.fail("hermes_sync_config() function not found in deploy.sh")
    func_body = match.group(1)
    synced_dirs: list[str] = []
    # Normalize whitespace: collapse backslash-continued lines into single lines
    normalized = re.sub(r'\\\n\s+', ' ', func_body)
    for m in re.finditer(
        r'rsync\s+[^\n]*"\$HERMES_STAGING_HOME/([^"/]+)/"\s+"\$HERMES_PROD_HOME/\1/"',
        normalized,
    ):
        synced_dirs.append(m.group(1))
    return synced_dirs


# ─── Curated must-sync list ────────────────────────────────────────────────────
# These are files/dirs that hermes_sync_config() MUST sync to prod.
# If any of these are missing from the sync list, prod will run stale code/config.

MUST_SYNC_FILES: list[str] = [
    "SOUL.md",
    "AGENTS.md",
    "TOOLS.md",
    "HEARTBEAT.md",
    "prefill.json",
    "agent-orchestrator.yaml",
]

MUST_SYNC_DIRS: list[str] = [
    "skills",
]


def test_policy_files_loop_contains_must_sync():
    """Every must-sync policy file must appear in the policy files loop."""
    script_content = DEPLOY_SCRIPT.read_text()
    policy_files = _parse_policy_loop_files(script_content)

    missing = [f for f in MUST_SYNC_FILES if f not in policy_files]
    assert not missing, (
        f"Policy files missing from hermes_sync_config() loop: {missing}\n"
        "These files are tracked in git and MUST be synced to prod."
    )


def test_sync_dirs_contain_must_sync():
    """Every must-sync directory must be synced via rsync --delete."""
    script_content = DEPLOY_SCRIPT.read_text()
    synced_dirs = _parse_sync_dirs(script_content)

    missing = [d for d in MUST_SYNC_DIRS if d not in synced_dirs]
    assert not missing, (
        f"Directories missing from hermes_sync_config() rsync: {missing}\n"
        "These dirs are tracked in git and MUST be synced to prod."
    )


def test_config_yaml_is_synced():
    """config.yaml must be synced (with prod-native override patching)."""
    script_content = DEPLOY_SCRIPT.read_text()
    # config.yaml is synced via explicit cp, not the loop
    assert "config.yaml" in script_content and "cp" in script_content, (
        "config.yaml must be synced via hermes_sync_config()"
    )


# ─── Provider key consistency ────────────────────────────────────────────────────

CONFIG_YAML = HERMES_REPO / "config.yaml"


def _load_config_yaml() -> dict:
    """Load and return config.yaml as a dict."""
    return yaml.safe_load(CONFIG_YAML.read_text())


def _provider_names_from_providers(providers: dict | None) -> set[str]:
    """Extract provider names from the `providers` section.

    The section is a dict keyed by provider name, e.g.:
        providers:
          wafer:
            name: wafer
            base_url: ...
            api_key: ...
    """
    if not providers:
        return set()
    return set(providers.keys())


def _provider_names_from_custom_providers(custom_providers: list | None) -> set[str]:
    """Extract provider names from the `custom_providers` section.

    The section is a list of dicts, each with a `name` key, e.g.:
        custom_providers:
          - name: wafer
            base_url: ...
            api_key: ...
    """
    if not custom_providers:
        return set()
    names: set[str] = set()
    for entry in custom_providers:
        name = entry.get("name")
        if name:
            names.add(name)
    return names


def _is_local_provider(base_url: str | None) -> bool:
    """Return True if the base_url points to localhost (no auth needed)."""
    if not base_url:
        return False
    return "localhost" in base_url or "127.0.0.1" in base_url


def test_no_duplicate_provider_entries():
    """No provider name should appear in both `providers` and `custom_providers`.

    Duplicate entries cause key-resolution ambiguity: one section may have an
    empty api_key while the other has the real key, leading to 401 errors
    when the wrong entry is resolved first (e.g. compression picking the
    empty-key variant).
    """
    cfg = _load_config_yaml()

    providers_names = _provider_names_from_providers(cfg.get("providers"))
    custom_names = _provider_names_from_custom_providers(cfg.get("custom_providers"))

    duplicates = providers_names & custom_names
    assert not duplicates, (
        f"Provider names found in BOTH `providers` and `custom_providers`: {sorted(duplicates)}\n"
        "This causes key-resolution ambiguity — one entry may have an empty "
        "api_key while the other has the real key, leading to 401 failures. "
        "Remove the duplicate or merge the entries."
    )


def test_provider_api_keys_not_empty():
    """Provider api_key fields must not be empty strings.

    Empty api_key values cause 401 errors when the provider is used
    (e.g. for compression, vision, or auxiliary tasks). Local providers
    (localhost/127.0.0.1 base_url) are exempt since they typically
    require no authentication.
    """
    cfg = _load_config_yaml()

    empty_key_providers: list[str] = []

    # Check `providers` section
    providers = cfg.get("providers")
    if providers and isinstance(providers, dict):
        for name, entry in providers.items():
            if not isinstance(entry, dict):
                continue
            base_url = entry.get("base_url", "")
            api_key = entry.get("api_key")
            if _is_local_provider(base_url):
                continue
            if api_key == "":
                empty_key_providers.append(f"providers.{name}")

    # Check `custom_providers` section
    custom_providers = cfg.get("custom_providers")
    if custom_providers and isinstance(custom_providers, list):
        for entry in custom_providers:
            if not isinstance(entry, dict):
                continue
            name = entry.get("name", "<unnamed>")
            base_url = entry.get("base_url", "")
            api_key = entry.get("api_key")
            if _is_local_provider(base_url):
                continue
            if api_key == "":
                empty_key_providers.append(f"custom_providers[{name}]")

    assert not empty_key_providers, (
        f"Providers with empty api_key (non-local): {empty_key_providers}\n"
        "Empty api_key causes 401 errors when the provider is used. "
        "Either set the key or, for local/authless providers, ensure "
        "base_url contains 'localhost' or '127.0.0.1'."
    )


# ─── Launchd watchdog presence ──────────────────────────────────────────────────


def test_watchdog_launchd_loaded():
    """Verify ai.smartclaw-watchdog is loaded in launchd on macOS.

    The watchdog runs every 5 minutes and restarts the prod gateway if it
    crashes. If the watchdog is not loaded, gateway outages go undetected
    and unrecovered until a human intervenes.
    """
    if sys.platform != "darwin":
        pytest.skip("launchd is macOS-only")

    result = subprocess.run(
        ["launchctl", "list"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            f"launchctl list failed (exit {result.returncode}): {result.stderr.strip()}"
        )

    assert "ai.smartclaw-watchdog" in result.stdout, (
        "Watchdog not loaded — run:\n"
        "  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.smartclaw-watchdog.plist"
    )


def test_watchdog_plist_template_in_repo():
    """Verify the watchdog plist template is tracked in the repo.

    Without this template, a fresh clone/reinstall loses the watchdog and gateway
    outages go undetected and unrecovered until a human intervenes.
    """
    template = HERMES_REPO / "launchd" / "ai.smartclaw-watchdog.plist.template"
    assert template.exists(), (
        f"Watchdog plist template missing from repo: {template}\n"
        "Create launchd/ai.smartclaw-watchdog.plist.template so install-launchagents.sh "
        "can bootstrap the watchdog on a fresh clone."
    )
