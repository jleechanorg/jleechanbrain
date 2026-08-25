"""Contract test for SOUL.md `## COMMIT: deploy-failure-classify-by-symptom`.

The rule says: when a deploy-failure symptom string appears in any
agent-facing message, the agent MUST load
`~/.claude/skills/wa-cloud-run-deploy-failure-debug/SKILL.md` BEFORE
forming a hypothesis. This test pins that contract by:

1. Asserting the `## COMMIT:` block exists in SOUL.md.
2. Asserting the trigger regex compiles in Python (the SOUL.md rule
   itself says "the regex MUST compile"; if it ever drifts, this
   test fails-fast before the rule silently degrades).
3. Asserting the trigger regex matches the canonical symptom strings
   ("PRECOMPUTE_FAILED:", "no interpreter with", "❌ FAILED: ... Deployment",
   "Cloud Run revision ... failed to become ready").
4. Asserting the rule references the expected downstream skill path.
5. Asserting the rule's `## COMMIT:` block sits alongside other rule
   blocks (i.e. wasn't orphaned into a comment block).

Why: 2026-07-13 the PRECOMPUTE_FAILED bug recurred for hours undetected
on jleechanorg/worldarchitect.ai#8380 because no agent had a trigger
that auto-loaded the deploy-failure recipe. This contract closes that gap.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOUL_MD = REPO_ROOT / "workspace" / "SOUL.md"
DEPLOY_FAILURE_BLOCK = "## COMMIT: deploy-failure-classify-by-symptom"
EXPECTED_SKILL_PATH = (
    "~/.claude/skills/wa-cloud-run-deploy-failure-debug/SKILL.md"
)


def _read_soul() -> str:
    return SOUL_MD.read_text()


def _extract_deploy_failure_block() -> str:
    """Return the body of the deploy-failure-classify COMMIT block.

    Reads from the `## COMMIT: deploy-failure-classify-by-symptom`
    header up to (but not including) the next `## COMMIT:` block.
    """
    body = _read_soul()
    start = body.index(DEPLOY_FAILURE_BLOCK)
    rest = body[start + len(DEPLOY_FAILURE_BLOCK):]
    # Find next `## COMMIT:` boundary.
    next_block = re.search(r"^## COMMIT: ", rest, flags=re.MULTILINE)
    if not next_block:
        return rest
    return rest[: next_block.start()]


def _extract_trigger_regex() -> re.Pattern[str]:
    """Pull the regex pattern out of the SOUL.md block.

    The block contains: `re.compile(r"(PRECOMPUTE_FAILED|...|❌ FAILED: .* Deployment)")`.
    Returns a compiled re.Pattern, or fails the test if the regex is missing
    or doesn't compile.
    """
    block = _extract_deploy_failure_block()
    m = re.search(r're\.compile\(r"([^"]+)"\)', block)
    if not m:
        raise AssertionError(
            "## COMMIT: deploy-failure-classify-by-symptom must contain "
            "an `re.compile(r\"<pattern>\")` call so the trigger contract "
            "is verifiable. Found no matching token."
        )
    return re.compile(m.group(1))


class TestDeployFailureClassifyContract(unittest.TestCase):
    """The SOUL.md COMMIT block must exist and the trigger must be honest."""

    def test_block_present(self) -> None:
        body = _read_soul()
        self.assertIn(
            DEPLOY_FAILURE_BLOCK,
            body,
            f"SOUL.md must define `{DEPLOY_FAILURE_BLOCK}`. "
            "Without it, the recurring deploy-failure pattern "
            "(e.g. PRECOMPUTE_FAILED on 2026-07-13) has no agent-side "
            "auto-trigger that loads the wa-cloud-run-deploy-failure-debug "
            "skill before forming a root-cause hypothesis.",
        )

    def test_block_sits_alongside_other_commits(self) -> None:
        """The block must be a real ## COMMIT: section, not a doc comment."""
        body = _read_soul()
        # At least 5 OTHER ## COMMIT: blocks must exist (precedent rule).
        commit_count = len(re.findall(r"^## COMMIT: ", body, flags=re.MULTILINE))
        self.assertGreaterEqual(
            commit_count, 5,
            f"Expected >=5 ## COMMIT: blocks; found {commit_count}. "
            "The deploy-failure rule should sit alongside other rule blocks "
            "so session-init scanning picks it up.",
        )

    def test_block_references_downstream_skill(self) -> None:
        block = _extract_deploy_failure_block()
        self.assertIn(
            EXPECTED_SKILL_PATH,
            block,
            f"The rule must reference {EXPECTED_SKILL_PATH} so agents "
            "auto-load the deploy-failure recipe.",
        )

    def test_trigger_regex_compiles(self) -> None:
        # Compiles or fails the test — this is the "verify CLI before
        # quoting" guard the rule itself mandates.
        pattern = _extract_trigger_regex()
        self.assertIsInstance(
            pattern, re.Pattern,
            "Extracted trigger must be a compiled re.Pattern",
        )

    def test_trigger_regex_matches_precompute_failed(self) -> None:
        pattern = _extract_trigger_regex()
        self.assertRegex(
            "PRECOMPUTE_FAILED: no interpreter with foo found",
            pattern,
        )

    def test_trigger_regex_matches_failed_email(self) -> None:
        pattern = _extract_trigger_regex()
        self.assertRegex(
            "❌ FAILED: dev Deployment - mvp-site-app-dev",
            pattern,
        )

    def test_trigger_regex_matches_cloud_run_not_ready(self) -> None:
        pattern = _extract_trigger_regex()
        self.assertRegex(
            "Cloud Run revision mvp-site-app-dev-03841-ftq failed to "
            "become ready within timeout",
            pattern,
        )

    def test_trigger_regex_matches_gunicorn_cant_open_file(self) -> None:
        pattern = _extract_trigger_regex()
        self.assertRegex(
            "gunicorn: can't open file 'wsgi.py'",
            pattern,
        )

    def test_trigger_regex_matches_port_bind(self) -> None:
        pattern = _extract_trigger_regex()
        self.assertRegex(
            "ERROR: failed to listen on the PORT (8080)",
            pattern,
        )

    def test_trigger_regex_matches_container_failed_to_start(self) -> None:
        pattern = _extract_trigger_regex()
        self.assertRegex(
            "container failed to start and listen on PORT 8080",
            pattern,
        )

    def test_block_documents_log_first_investigation_rule(self) -> None:
        """The rule must tell agents to read the GH Actions log FIRST."""
        block = _extract_deploy_failure_block()
        self.assertIn(
            "gh api actions/jobs",
            block,
            "The rule must instruct agents to read the GH Actions job log "
            "(`gh api actions/jobs/<job_id>/logs` or `gh run view --log-failed`) "
            "BEFORE chasing the commit SHA named in the failure alert. "
            "Skipping the log is the original PRECOMPUTE_FAILED trap.",
        )

    def test_block_documents_recurring_failure_dispatch(self) -> None:
        """The rule must route recurring deploy-infra bugs to AO + bead."""
        block = _extract_deploy_failure_block()
        self.assertIn(
            "br create",
            block,
            "The rule must instruct agents to open a `br create` bead for "
            "recurring deploy-infra failures (not keep re-investigating "
            "application code).",
        )
        self.assertIn(
            "ao spawn",
            block,
            "The rule must instruct agents to dispatch recurring deploy-infra "
            "failures via `ao spawn` rather than running them inline.",
        )


if __name__ == "__main__":
    unittest.main()
