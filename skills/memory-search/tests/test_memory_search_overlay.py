"""Tests for the Hermes-side memory-search skill overlay.

Contract:
1. Overlay file exists at `skills/memory-search/SKILL.md` under the jleechanbrain repo.
2. Frontmatter parses with valid YAML (name, description, ---).
3. Owns an explicit repository-side mechanics allowlist and rejects user-scope
   skill files as policy or mechanics sources.
4. Lists all 10 memory sources in the fan-out (roadmap, beads, claude memories, hermes sqlite, hermes briefings, hermes index, openclaw memories, wiki, history, slack).
5. Triggers on the standard phrases: 'search memories', '/ms', 'look up in memory', 'find in my memories'.
6. SOUL.md `## COMMIT: ms-on-new-task` references this overlay (no broken skill_view calls).
7. AGENTS.md Session Startup references this overlay.
8. Resolver exposes the overlay through its canonical path.
9. SOUL.md confines full personal-store fan-out to private one-to-one sessions.
10. The direct `/ms` command preserves the same privacy gate and fails closed
    rather than delegating policy to a user-scope command.

Run: python3 -m pytest skills/memory-search/tests/test_memory_search_overlay.py -v
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]  # skills/memory-search/tests/ -> repo root
WORKSPACE = REPO_ROOT / "workspace"
class TestMemorySearchOverlay(unittest.TestCase):
    def setUp(self) -> None:
        self.overlay = REPO_ROOT / "skills" / "memory-search" / "SKILL.md"
        self.soul = WORKSPACE / "SOUL.md"
        self.agents = WORKSPACE / "AGENTS.md"
        self.resolver = REPO_ROOT / "skills" / "RESOLVER.md"
        self.command = REPO_ROOT / "skills" / "memory-search" / "commands" / "ms.md"

    def test_overlay_file_exists_in_repo(self):
        self.assertTrue(
            self.overlay.exists(),
            f"overlay missing in repo: {self.overlay} — must live at skills/memory-search/SKILL.md",
        )

    def test_overlay_has_valid_yaml_frontmatter(self):
        text = self.overlay.read_text()
        self.assertTrue(text.startswith("---\n"), "overlay must start with ---")
        # Find the closing ---
        end = text.find("\n---\n", 4)
        self.assertGreater(end, 4, "overlay must have a closing --- in frontmatter")
        fm = text[4:end]
        self.assertIn("name: memory-search", fm, "frontmatter must declare name=memory-search")
        self.assertIn("description:", fm, "frontmatter must have a description")

    def test_overlay_owns_mechanics_and_rejects_user_scope_skills(self):
        text = self.overlay.read_text()
        normalized = " ".join(text.split())
        self.assertIn("fail closed on personal-store fan-out", normalized)
        self.assertIn("complete allowlist", normalized)
        self.assertIn("must not be read or executed as policy or source mechanics", normalized)
        self.assertIn("Do not load instructions from", text)
        self.assertIn("Repository-owned execution allowlist", text)
        self.assertNotIn("read the canonical implementation", text)
        execution = re.search(
            r"### Repository-owned execution allowlist\s*\n(.*?)(?=\n## |\Z)",
            text,
            re.DOTALL,
        ).group(1)
        self.assertNotIn("~/.claude/skills/", execution)
        self.assertNotIn("~/.codex/skills/", execution)
        self.assertNotIn("implementation fallback", execution)

    def test_overlay_lists_all_10_memory_sources(self):
        text = self.overlay.read_text().lower()
        required_sources = [
            "~/roadmap",
            "beads",
            "claude memories",
            "hermes sqlite",
            "hermes briefings",
            "hermes index",
            "openclaw memories",
            "wiki",
            "history",
            "slack",
        ]
        for src in required_sources:
            self.assertIn(src, text, f"overlay must list '{src}' as a fan-out source")

    def test_overlay_triggers_on_standard_phrases(self):
        text = self.overlay.read_text().lower()
        required_triggers = [
            "search memories",
            "/ms",
            "look up in memory",
            "find in my memories",
        ]
        for trig in required_triggers:
            self.assertIn(trig, text, f"overlay must trigger on '{trig}'")

    def test_soul_md_references_overlay(self):
        text = self.soul.read_text()
        # The COMMIT block must mention the overlay (so the resolver path is wired)
        m = re.search(
            r"## COMMIT: ms-on-new-task\s*\n(.*?)(?=\n## COMMIT:|\Z)",
            text,
            re.DOTALL,
        )
        self.assertIsNotNone(m, "## COMMIT: ms-on-new-task must exist in SOUL.md")
        block = m.group(1)
        self.assertIn(
            "skills/memory-search/SKILL.md",
            block,
            "SOUL.md ms-on-new-task COMMIT must reference the Hermes-side overlay",
        )

    def test_agents_md_references_overlay(self):
        text = self.agents.read_text()
        self.assertIn(
            "skills/memory-search/SKILL.md",
            text,
            "AGENTS.md must reference the overlay in Session Startup",
        )

    def test_resolver_references_overlay(self):
        text = self.resolver.read_text()
        self.assertIn(
            "**File:** `skills/memory-search/SKILL.md`",
            text,
            "RESOLVER.md must expose the canonical memory-search overlay",
        )

    def test_full_fanout_is_private_session_only(self):
        text = self.soul.read_text()
        m = re.search(
            r"## COMMIT: ms-on-new-task\s*\n(.*?)(?=\n## COMMIT:|\Z)",
            text,
            re.DOTALL,
        )
        self.assertIsNotNone(m, "## COMMIT: ms-on-new-task must exist in SOUL.md")
        block = m.group(1)
        self.assertIn("only when BOTH this COMMIT and the repository overlay", block)
        self.assertIn("If either policy owner is unavailable", block)
        self.assertIn("private one-to-one session with Jeffrey", block)
        self.assertIn("never run that full fan-out", block)
        self.assertIn("scoped to the current thread, channel, or task", block)
        self.assertIn("without worker/subagent dispatch", block)

    def test_startup_order_is_executable_and_consistent(self):
        soul = self.soul.read_text()
        agents = self.agents.read_text()
        soul_block = re.search(
            r"## COMMIT: ms-on-new-task\s*\n(.*?)(?=\n## COMMIT:|\Z)",
            soul,
            re.DOTALL,
        ).group(1)
        agents_block = re.search(
            r"## Session Startup\s*\n(.*?)(?=\n## |\Z)",
            agents,
            re.DOTALL,
        ).group(1)
        soul_normalized = " ".join(soul_block.split())
        agents_normalized = " ".join(agents_block.split())
        self.assertIn("Read `SOUL.md` and `USER.md` as mandatory initialization preflight", soul_normalized)
        self.assertIn("sole exception to the first-task-tool rule", soul_normalized)
        self.assertIn("After that initialization preflight", soul_normalized)
        self.assertIn("startup policy reads precede task-directed tool use", agents_normalized)
        self.assertIn("make `session_search` the first task-directed tool call", agents_normalized)
        self.assertLess(
            soul_normalized.index("Read `SOUL.md` and `USER.md`"),
            soul_normalized.index("first task-directed tool call in a private direct session MUST"),
        )
        self.assertLess(
            agents_normalized.index("Read [SOUL.md]"),
            agents_normalized.index("make `session_search` the first task-directed tool call"),
        )
        self.assertLess(
            agents_normalized.index("make `session_search` the first task-directed tool call"),
            agents_normalized.index("read today's and yesterday's"),
        )
        self.assertIn("Only after that recall gate succeeds", agents_normalized)
        self.assertIn("call `session_search` first", soul_normalized)
        self.assertIn("Only after it completes, call `skill_view", soul_normalized)
        self.assertIn("MUST be `session_search`", soul_normalized)

    def test_personal_store_searches_stay_in_private_parent(self):
        overlay_text = self.overlay.read_text()
        command_text = self.command.read_text()
        overlay = " ".join(overlay_text.split())
        command = " ".join(command_text.split())
        self.assertIn("Personal-store searches must run in that private parent session", overlay)
        self.assertIn("do not dispatch them through", overlay)
        self.assertIn("direct calls from that private parent session", command)
        self.assertIn("never dispatch them", command)
        execution = re.search(
            r"### Repository-owned execution allowlist\s*\n(.*?)(?=\n## |\Z)",
            overlay_text,
            re.DOTALL,
        ).group(1)
        self.assertNotIn("delegate_task", execution)
        self.assertNotIn("/e", execution)
        self.assertIn("~/llm_wiki/", execution)
        self.assertIn("~/llm_wiki/` directly with `rg`", execution)
        execution_normalized = " ".join(execution.split())
        for bounded_phrase in (
            "`~/roadmap/` with `rg` and return at most 20 matches",
            "`~/.claude/projects/*/memory/*.md` with `rg` and return at most 20 matches",
            "`~/.smartclaw/MEMORY.md` with `rg` and return at most 20 matches",
            "`~/openclaw-repo/MEMORY.md` and Markdown files under `~/.smartclaw/memory/` with `rg` and return at most 20 matches total",
            "`~/llm_wiki/` directly with `rg` and return at most 20 matches",
        ):
            self.assertIn(bounded_phrase, execution_normalized)

    def test_command_action_only_forwards_to_repo_workflow(self):
        text = self.command.read_text()
        action = re.search(r"## Action\s*\n(.*?)(?=\n## |\Z)", text, re.DOTALL).group(1)
        self.assertIn("skills/memory-search/SKILL.md", action)
        self.assertIn("repository-owned", action)
        self.assertNotIn("~/.claude/skills/", action)
        self.assertNotIn("~/.codex/skills/", action)

    def test_slash_discovery_cannot_bypass_repo_ms_workflow(self):
        soul = self.soul.read_text()
        discovery = re.search(
            r"## Slash Command Discovery\s*\n(.*?)(?=\n## |\Z)",
            soul,
            re.DOTALL,
        ).group(1)
        normalized = " ".join(discovery.split())
        self.assertIn("Exception: `/ms` and `/memory_search`", normalized)
        self.assertIn("skills/memory-search/commands/ms.md", normalized)
        self.assertIn("skills/memory-search/SKILL.md", normalized)
        self.assertIn("Do not read or execute a user-scope command or skill file", normalized)
        self.assertIn("user-scope adapter may only forward", normalized)

    def test_ms_command_preserves_privacy_gate(self):
        text = self.command.read_text()
        self.assertIn("only in a private one-to-one session with", text)
        self.assertIn("shared, cron, or worker contexts", text)
        self.assertIn("is not a policy owner", text)
        self.assertIn("Both owners are required", text)
        self.assertIn("If either the workspace gate or the repo overlay is", text)
        self.assertIn("fail closed", text)
        self.assertIn("repository-owned", text)
        self.assertIn("never load a user-scope skill", text)


if __name__ == "__main__":
    unittest.main()
