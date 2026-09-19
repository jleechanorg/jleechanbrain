#!/usr/bin/env python3
"""
Surgical YAML patcher: convert path-filter-gated GHA jobs from `skipped`
to synthetic-success.

For each gated job, perform three surgical edits scoped to ONE job's region:
  (a) Job-level `if:` rewrite — drop the path-filter clause (keep draft/fork guard).
  (b) Insert synthetic-success step at top of `steps:` that runs ONLY when
      the path filter is 'false'.
  (c) Add step-level `if: outputs.<key> == 'true'` to EVERY existing step that
      doesn't already have its own `if:` (preserves runner.os, always(),
      failure() guards).

Scoping: locate each job's region by anchoring on its job name (`  <job>:`),
then walk forward until the next sibling job. All edits for one job stay
within its region, so the same patcher works on multi-job workflow files.

Usage (from a clean checkout):
  1. Edit the JOBS list at the bottom of this file to enumerate your jobs.
  2. python3 scripts/patch_path_filter_skipped.py
  3. actionlint .github/workflows/*.yml        # verify no new warnings
  4. python3 scripts/tests/test_workflow_skip_synthetic_success.py

Tested against:
  - jleechanorg/worldarchitect.ai (PR #9140, 2026-08-19, 16 jobs across 3 files)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Iterable

import yaml

# === Configuration: edit this for your repo ===

WT = Path(".github/workflows")  # relative to repo root


def jobs_for_file() -> dict[Path, list[tuple[str, str, str]]]:
    """Return {file_path: [(job_name, filter_output_key, label_for_notice), ...]}.

    Override this for your repo. The (job, key, label) triple must match what's
    in the workflow YAML:
      - job:  the 2-space-indented key under `jobs:`
      - key:  the detect-changes output name (e.g. 'python', 'schemas', 'has-changes')
      - label: human-readable label for the `::notice::` line

    Reference from jleechanorg/worldarchitect.ai PR #9140:
    """
    return {
        WT / "presubmit.yml": [
            ("schema-coverage", "schemas", "schemas"),
            ("prompt-contracts", "prompts", "prompt/tool contract"),
            ("narrative-response-schema-ci", "prompts", "prompt/schema"),
            ("function-loc-ratchet", "loc_ratchet", "function LOC ratchet"),
            ("agy-json-contract", "agy", "AGY JSON contract"),
            ("python-lint", "python", "Python lint"),
            ("python-typecheck", "python", "Python type check"),
            ("javascript-lint", "js", "JavaScript lint"),
        ],
        WT / "test.yml": [
            ("import-validation", "python", "import validation"),
            ("beads-jsonl-validation", "beads", "beads JSONL"),
            ("shell-script-tests", "shell", "shell script"),
            ("test", "has-changes", "directory tests"),
        ],
        WT / "self-hosted-mvp-shard1.yml": [
            ("harness-autonomy-self-hosted", "harness-changes", "harness autonomy"),
            ("mvp-shard-1", "mvp-changes", "MVP shard 1"),
            ("mvp-shard-2", "mvp-changes", "MVP shard 2"),
            ("mvp-shard-3", "mvp-changes", "MVP shard 3"),
        ],
    }


# === Implementation ===

SIBLING_RE = re.compile(r"^  [a-zA-Z_][a-zA-Z0-9_-]*:\s*(#.*)?$")


def find_job_regions(text: str) -> tuple[dict[str, list[int]], list[str]]:
    """Return ({job_name: [start_line, end_line_exclusive]}, lines).

    A job's region starts at its `  <job>:` line and ends just before the
    next sibling job (`  <other_job>:`) or end-of-file.
    """
    lines = text.splitlines(keepends=True)
    regions: dict[str, list[int]] = {}
    in_jobs = False
    for i, line in enumerate(lines):
        if line.strip() == "jobs:":
            in_jobs = True
            continue
        if not in_jobs:
            continue
        if SIBLING_RE.match(line) and line.startswith("  ") and not line.startswith("   "):
            name = line.split(":", 1)[0].strip()
            regions[name] = [i, None]
    keys = list(regions.keys())
    for idx, name in enumerate(keys):
        end_line = regions[keys[idx + 1]][0] if idx + 1 < len(keys) else len(lines)
        regions[name][1] = end_line
    return regions, lines


def patch_one(path: Path, job: str, key: str, label: str) -> None:
    """Patch one gated job in path. All edits scoped to the job's region.

    Raises RuntimeError on any structural issue so the caller can decide
    whether to abort or continue.
    """
    # Re-find regions on the CURRENT text (mutated by previous iteration).
    regions, lines = find_job_regions(path.read_text())
    if job not in regions:
        raise RuntimeError(f"{path.name}/{job}: job not found in workflow")
    s, e = regions[job]
    body = "".join(lines[s:e])

    # === (a) Strip path-filter clause from job-level if: ===
    # Two forms: single-line `outputs.X == 'true' && (...)` and
    # multi-line `|(...)\n&& (outputs.X == 'true' || github.event_name != 'pull_request')`.
    if1_re = re.compile(
        rf"needs\.detect-changes\.outputs\.{re.escape(key)} == 'true'\s*&&\s*"
    )
    if2_re = re.compile(
        rf"\(needs\.detect-changes\.outputs\.{re.escape(key)} == 'true'\s*\|\|\s*github\.event_name != 'pull_request'\)"
    )

    if1_count = len(if1_re.findall(body))
    if2_count = len(if2_re.findall(body))
    if if1_count + if2_count == 0:
        raise RuntimeError(f"{path.name}/{job}: no path-filter pattern found in if:")
    if if1_count > 1 or if2_count > 1:
        raise RuntimeError(
            f"{path.name}/{job}: too many path-filter matches (if1={if1_count}, if2={if2_count})"
        )

    body = if1_re.sub("", body, count=1)
    body = if2_re.sub("", body, count=1)

    # === (b) Insert synthetic step at top of `steps:` ===
    # Auto-detect first existing step's leading whitespace (varies by file).
    steps_marker = "    steps:\n"
    if body.count(steps_marker) != 1:
        raise RuntimeError(
            f"{path.name}/{job}: expected exactly 1 `steps:` marker, found {body.count(steps_marker)}"
        )
    body_after_steps = body.split(steps_marker, 1)[1]
    first_step_line = next(
        (ln for ln in body_after_steps.splitlines(keepends=True) if ln.lstrip().startswith("- name:")),
        None,
    )
    if first_step_line is None:
        raise RuntimeError(f"{path.name}/{job}: no - name: step found after `steps:`")
    step_indent_ws = first_step_line[: len(first_step_line) - len(first_step_line.lstrip())]
    child_indent_ws = step_indent_ws + "  "

    synth = (
        f'{step_indent_ws}- name: "No {label}-relevant changes - synthetic success"\n'
        f"{child_indent_ws}if: needs.detect-changes.outputs.{key} != 'true'\n"
        f"{child_indent_ws}run: |\n"
        f"{child_indent_ws}  echo \"::notice::No {label}-relevant changes in this PR; emitting synthetic success (filter: {key})\"\n"
    )
    body = body.replace(steps_marker, steps_marker + synth, 1)

    # === (c) Add step-level `if:` to EVERY non-synthetic step that doesn't
    #         already have one (preserves runner.os, always(), failure() guards).
    step_entry_re = re.compile(
        rf"^{re.escape(step_indent_ws)}- name: (\"[^\n]+?\"|[^\n]+?)\s*$", re.MULTILINE
    )
    matches = list(step_entry_re.finditer(body))
    if not matches:
        raise RuntimeError(f"{path.name}/{job}: no step entries found")

    n_patched = 0
    new_body_chunks = []
    last_end = 0
    for m in matches:
        # +1 to step past the `\n` so we can peek the next line for an existing `if:`.
        end_of_name_line = m.end() + 1
        name_text = m.group(1).strip().strip('"')

        # Always advance past the `- name:` line itself (including its `\n`).
        new_body_chunks.append(body[last_end:end_of_name_line])
        last_end = end_of_name_line

        if name_text.startswith('"No ') or name_text.startswith('No '):
            # Synthetic — skip; do not insert.
            continue
        # Peek the next line for an existing `if:`.
        peek_idx = end_of_name_line
        while peek_idx < len(body) and body[peek_idx] == "\n":
            peek_idx += 1
        next_line_end = body.find("\n", peek_idx)
        next_line = body[peek_idx : next_line_end if next_line_end != -1 else len(body)]
        if next_line.lstrip().startswith("if:"):
            # Step already has its own control `if:` — leave it alone.
            continue
        # No existing if: — insert our filter gate.
        new_body_chunks.append(
            f"{child_indent_ws}if: needs.detect-changes.outputs.{key} == 'true'\n"
        )
        n_patched += 1
    new_body_chunks.append(body[last_end:])
    body = "".join(new_body_chunks)
    if n_patched == 0:
        raise RuntimeError(f"{path.name}/{job}: no non-synthetic steps patched")

    # Splice back into the workflow file.
    body_lines = body.splitlines(keepends=True)
    lines[s:e] = body_lines
    path.write_text("".join(lines))


def run(path: Path, jobs: Iterable[tuple[str, str, str]]) -> None:
    """Apply patches for all jobs in `path`, then validate the YAML parses."""
    for job, key, label in jobs:
        patch_one(path, job, key, label)
    # Validate.
    with path.open() as f:
        yaml.safe_load(f)
    print(f"OK {path.name}")


def main() -> int:
    job_map = jobs_for_file()
    for path, jobs in job_map.items():
        if not path.exists():
            print(f"MISSING {path}", file=sys.stderr)
            continue
        run(path, jobs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
