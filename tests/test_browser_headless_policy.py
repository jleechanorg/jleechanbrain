"""Unit tests for browser headless policy checker."""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills/browser-headless-default/scripts"))

from check_browser_policy import find_forbidden, user_opted_into_headed  # noqa: E402


def test_allows_headless_playwright() -> None:
    text = 'playwright launch headless: true navigate http://127.0.0.1:3000'
    assert find_forbidden(text) == []


def test_blocks_show_browser() -> None:
    assert "show_browser" in find_forbidden('{"action": "show_browser"}')


def test_blocks_headed_flag() -> None:
    assert "headed_flag" in find_forbidden("node mcp --headed")


def test_opt_in_phrases() -> None:
    assert user_opted_into_headed("please use headed mode for this demo")
    assert not user_opted_into_headed("scrape luma with browserclaw")
