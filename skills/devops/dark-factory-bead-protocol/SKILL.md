---
name: dark-factory-bead-protocol
description: Filing /af factory beads the daemon adopts.
---

# Dark-Factory Bead Protocol

When the operator invokes `/af` or `/auto-factory` on a coding task, the work
is delegated to the dark-factory daemon (Mac launchd `ai.dark-factory.af-tick`
+ Linux polling daemon). The daemon only adopts beads that match its exact
intake contract. Filing a bead that doesn't match leaves it orphaned in the
queue — the operator sees "no progress" and escalates.

## When to file a factory-labeled bead

- Operator says `/af`, `/auto-factory`, or `/claw` AND the work targets a code
  change (not a one-off research request).
- You have an EXISTING PR (operator wants the existing branch driven to
  `/ready`) OR you are creating a NEW goal that needs a tracked bead.

## Bead body contract (canonical format)

The bead body is the dispatch brief the daemon reads. Format:

```
target_repo: jleechanorg/<repo>            # FIRST LINE — required
existing_pr: https://github.com/<owner>/<repo>/pull/<N>
existing_branch: <branch-name>
head_sha: <full-40-char-sha>
labels: factory

<scope summary ≤ 4 paragraphs>
<acceptance criteria — list the green-gate conditions>
<do-not clauses>
```

Hard limits:
- **Body ≤ 4096 chars** (AO spawn prompt cap — anything longer truncates and
  the AO worker never sees the rest).
- `target_repo:` MUST be the literal first non-blank line — the daemon parses
  it before anything else.
- `existing_branch` MUST match `git rev-parse --abbrev-ref HEAD` on the worktree
  you intend the factory to push to.
- `head_sha` MUST be the full 40-char SHA, not the short form.
- Use `--no-auto-flush` on feature branches; never commit `.beads/issues.jsonl`
  from a feature branch (the dark-factory repo's CI owns canonical flushes).

## GitHub label placement (the silent-adoption blocker)

The daemon's intake is two-phase:

1. `normalize_labeled_issues` — sweeps `factory`-labeled ISSUES on the target
   repo, creates a bead per issue, links external_ref.
2. `normalize_labeled_prs` — sweeps `factory`-labeled PRs. A PR is only
   adopted when its corresponding bead (with matching issue-side external_ref)
   already exists.

**Therefore: `factory` on the PR alone does NOT trigger adoption.** The bead
sits in the queue until the issue-side adoption fires. Always:

- Add the `factory` label to BOTH the GitHub issue (parent) AND the PR.
- For PR-only goals with no parent issue, open a minimal tracking issue first
  (e.g. `chore: factory-track PR #N`) and label THAT issue with `factory`.

## br create flags (the actual command)

```bash
cd ~/projects/dark-factory   # br workspace — daemon reads from here
br create "<title>" \
    --type task \
    --priority 1|2 \
    --labels factory \
    --description-file <body.md> \
    --no-auto-flush
```

Bugs caught in real sessions:
- **`--label` (singular) returns `error: unexpected argument '--label' found`**.
  Correct flag is `--labels` (plural). The error message helpfully suggests
  `--labels`, so this is a typo trap not a semantic flag — easy to miss in
  long output.
- Omit `--description-file` and a long body gets mangled by quote-escaping;
  write the body to a file first and pass `--description-file`.
- `cd` to the dark-factory repo before `br create` — br stores beads in
  `.beads/beads.db` relative to cwd, and the daemon only reads from
  `${HOME}/projects/dark-factory/.beads/`.

## Verification (post-file)

After filing, confirm:

1. `br show <bead-id>` — `status=open`, `labels: [factory]`, body has
   `target_repo: jleechanorg/<repo>` as first line.
2. `gh api repos/<owner>/<repo>/issues/<n> --jq '.labels[].name'` — both PR
   AND parent issue show `"factory"`.
3. Watch `af-tick.out.log` (Mac) or the Linux daemon JSONL for
   `{"target_repo": ..., "beads_created": N}` and confirm `N` increments within
   ~30s (daemon polls every 5s, full sweep ~2 min for 35+ issues).
4. Confirm the daemon row exists in `~/.dark-factory/daemon-cxdb.sqlite`:
   `sqlite3 ~/.dark-factory/daemon-cxdb.sqlite "SELECT * FROM bead_overlay WHERE bead_id='<id>'"`

## Pitfalls (real failures)

- **PR labeled `factory`, issue not labeled** → bead stays in QUEUED state
  forever; operator sees "0 progress"; 30+ min wasted. The fix is to add the
  label to the issue (one `gh api` POST), not to re-file the bead.
- **`target_repo:` missing from bead body** → daemon logs
  `[af] skip <bead>: no repo mapping (fail-closed, no bead_repo or
  TARGET_REPO)` repeatedly. The bead is filed but never picked up.
- **Body > 4096 chars** → AO worker spawn truncates the prompt; the worker
  can't see acceptance criteria and either does nothing or merges garbage.
- **`--label` instead of `--labels`** → command exits 2 with the misleading
  error message; no bead created. Easy to miss in long shell output.
- **Wrong cwd for `br create`** → bead is filed in the wrong `.beads.db`
  (e.g. `~/projects/worldarchitect.ai/.beads/`), invisible to the dark-factory
  daemon. Symptom: bead appears in `br list` from the wrong project, daemon
  has no record.

## Related skills

- `auto-factory` — the umbrella slash command (bundled; read-only).
- `dispatch-task` — for non-`/af` ao spawn flows.
- `babysit-stale-watchdog` — for tracking factory-bead stalls after adoption.