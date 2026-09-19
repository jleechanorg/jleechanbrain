#!/usr/bin/env python3
"""rollback_aside_default_core.py — the actual rollback logic, called by rollback-aside-default.sh.

This is split into a Python file (rather than embedded in the bash script) to avoid
shell quoting hell when handling regex patterns with special characters.
"""
import json
import re
import sys
from pathlib import Path


def revert_soul_md(path: Path) -> int:
    """Remove the aside-browser-default COMMIT block from SOUL.md."""
    if not path.exists():
        return 0
    text = path.read_text()
    pattern = re.compile(
        r"## COMMIT: aside-browser-default \(PRIMARY\)\n"
        r"(?:.*\n)*?"
        r"(?=## )",
        re.MULTILINE,
    )
    new_text, n = pattern.subn("", text)
    if n > 0:
        new_text = re.sub(r"\n{4,}", "\n\n\n", new_text)
        path.write_text(new_text)
    return n


def revert_browser_default_section(path: Path) -> int:
    """Remove the Aside-default sections from a policy file. Returns count of changes."""
    if not path.exists():
        return 0
    text = path.read_text()
    original = text
    n_total = 0

    # 1. Delete "## Browser default — Aside is PRIMARY..." block
    p1 = re.compile(
        r"## Browser default — Aside is PRIMARY, Playwright MCP is fallback\n"
        r"(?:.*\n)*?"
        r"(?=\n## )",
        re.MULTILINE,
    )
    text, n1 = p1.subn("", text)
    n_total += n1

    # 2. Revert fallback heading back to original
    p2 = re.compile(r"## Browser testing — always use Playwright MCP headless \(FALLBACK\)\n")
    text, n2 = p2.subn("## Browser testing — always use Playwright MCP headless\n", text)
    n_total += n2

    # 3. Revert body wording in Claude/Codex browser-testing description
    p3 = re.compile(
        r"Always use `mcp__playwright-mcp` \(headless\) to test localhost URLs and web UIs as a fallback when Aside browser is unavailable\."
    )
    text, n3 = p3.subn(
        "Always use `mcp__playwright-mcp` (headless) to test localhost URLs and web UIs.",
        text,
    )
    n_total += n3

    # 4. browser-headless-default (staging) primary-tool callout + table row
    p5 = re.compile(
        r"\*\*Primary tool \(2026-06-27\):\*\* \*\*Aside browser\*\* \(`aside` CLI / `aside-mcp`\)\. Use it first for all browser work\. This skill is the fallback for Playwright MCP / superpowers-chrome paths\.\n\n"
    )
    text, n5 = p5.subn("", text)
    n_total += n5

    p5b = re.compile(r"\| \*\*Aside CLI / `aside-mcp`\*\* \| \*\*PRIMARY\*\*.*\n")
    text, n5b = p5b.subn("", text)
    n_total += n5b

    # 5. browser-headless-default (prod) callout
    p7 = re.compile(
        r"\*\*Primary tool \(2026-06-27\):\*\* \*\*Aside browser\*\* \(`aside` CLI / `aside-mcp`\)\. Use Aside first; Playwright MCP / superpowers-chrome are fallbacks\. This skill covers the fallback path\.\n\n"
        r"For the Aside-primary workflow, see `~/.smartclaw/skills/aside-browser-default/SKILL\.md`\.\n\n"
    )
    text, n7 = p7.subn("", text)
    n_total += n7

    # 6. RESOLVER.md entries
    p8 = re.compile(
        r"## aside-browser-default\n\n"
        r"\*\*File:\*\* `skills/aside-browser-default/SKILL\.md`\n"
        r"\*\*Triggers:\*\* aside browser, aside cli, aside mcp, default browser, aside primary, browser tool default\n\n"
    )
    text, n8 = p8.subn("", text)
    n_total += n8

    p9 = re.compile(
        r"\*\*Note:\*\* Playwright MCP / superpowers-chrome headless fallback for cases `aside-browser-default` doesn't cover\.\n"
    )
    text, n9 = p9.subn("", text)
    n_total += n9

    if n_total > 0 or text != original:
        text = re.sub(r"\n{4,}", "\n\n\n", text)
        path.write_text(text)

    return n_total


def remove_aside_mcp_from_claude_json(path: Path) -> bool:
    """Remove aside-mcp from ~/.claude.json mcpServers. Returns True if removed."""
    if not path.exists():
        return False
    data = json.loads(path.read_text())
    mcps = data.get("mcpServers", {})
    if "aside-mcp" in mcps:
        del mcps["aside-mcp"]
        data["mcpServers"] = mcps
        path.write_text(json.dumps(data, indent=2))
        return True
    return False


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    if cmd == "revert-soul":
        for p in sys.argv[2:]:
            n = revert_soul_md(Path(p))
            label = Path(p).name
            print(f"  {'✓' if n > 0 else '-'} Reverted {n} COMMIT block(s) in {p}")
    elif cmd == "revert-section":
        for p in sys.argv[2:]:
            n = revert_browser_default_section(Path(p))
            label = Path(p).name
            print(f"  {'✓' if n > 0 else '-'} Reverted {n} change(s) in {p}")
    elif cmd == "remove-aside-mcp":
        p = Path(sys.argv[2])
        removed = remove_aside_mcp_from_claude_json(p)
        print(f"  {'✓' if removed else '-'} aside-mcp {'removed' if removed else 'already absent'} from {p}")
    else:
        print(f"Unknown command: {cmd}")
        print("Usage: rollback_aside_default_core.py {revert-soul|revert-section|remove-aside-mcp} <paths>")
        sys.exit(1)