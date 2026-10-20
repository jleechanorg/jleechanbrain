# Mac → Linux bead-store sync gap

Verified 2026-08-18 against jeff-ubuntu's daemon at `tick=81`, `consecutive_failures=0`.
**Corrected 2026-08-18** after PR #9070 session — the daemon's actual bead store was wrong in v0.1.0 of this reference.

## What fails and why

`br create <title>` on macOS writes to **macOS-local SQLite** (`~/projects/dark-factory/.beads/beads.db`). The daemon's `factory-overlay.sh` reads from **jeff-ubuntu's own SQLite + JSONL snapshot** at a DIFFERENT path, NOT the macOS one. There is no automatic sync.

### The actual daemon store path (verified 2026-08-18)

```bash
ssh jeff-ubuntu 'systemctl --user show ai.dark-factory.daemon.service -p Environment | grep DARK_FACTORY_BR_DB'
# → Environment=DARK_FACTORY_BR_DB=/home/jleechan/.local/state/dark-factory/.beads/beads.db
```

The daemon's authoritative bead store lives at:
```
/home/jleechan/.local/state/dark-factory/.beads/
├── beads.db          # SQLite (daemon reads this)
├── beads.db-wal      # SQLite write-ahead log
├── issues.jsonl      # JSONL snapshot (kept in sync with SQLite)
├── config.yaml       # br config
└── .br_history/      # history
```

This is a DIFFERENT path from `/home/jleechan/projects/dark-factory/.beads/` (a user-side repo clone that happens to live on Linux too).

### Symptom fingerprint

Run these in parallel to confirm this gap is the cause of a "bead filed but nothing happened":

```bash
# On Mac — bead IS in Mac SQLite
cd ~/projects/dark-factory && br show <bead_id> --json 2>&1 | head -1
# → returns the bead

# On Mac — bead NOT in Mac JSONL (last flush is older)
grep -c '"<bead_id>"' ~/projects/dark-factory/.beads/issues.jsonl
# → 0 (or whatever the stale count is)

# On Linux (jeff-ubuntu) — bead NOT in daemon's JSONL (this is what matters)
DAEMON_STORE=$(ssh jeff-ubuntu 'systemctl --user show ai.dark-factory.daemon.service -p Environment | grep DARK_FACTORY_BR_DB | sed "s/.*=//"' 2>/dev/null)
DAEMON_DIR=$(dirname "$DAEMON_STORE")
ssh jeff-ubuntu "grep -c '<bead_id>' ${DAEMON_DIR}/issues.jsonl"
# → 0

# Daemon's recent telemetry does NOT include the bead
ssh jeff-ubuntu "tail -300 /home/jleechan/Library/Logs/dark-factory/daemon.jsonl | grep -ac '<bead_id>'"
# → 0
```

If all four match, this is the sync gap, not a daemon bug.

## Why `br sync --flush-only` refuses by default (from the WRONG store)

```bash
$ cd ~/projects/dark-factory && br sync --flush-only
Error: Configuration error: Refusing to export stale database that would lose issues.
Database has 4408 issues, JSONL has 2607 unique issues.
Export would lose 2 issue(s): rev-fo34v, rev-hzch2.1
```

The Mac-side SQLite and the Mac-side JSONL are out of sync — Mac SQLite has 1801 more rows than Mac JSONL, including 2 (rev-fo34v and rev-hzch2.1) that ONLY exist in JSONL. The safety guard refuses to overwrite JSONL with a flush that would lose those.

This is by design. Forcing it with `--force` is destructive — those 2 issues would be lost. But **even after forcing, the daemon still can't see the bead** because the daemon reads from a DIFFERENT path entirely.

## Why manual rsync doesn't help

```bash
$ rsync -avz --update -e ssh \
    ~/projects/dark-factory/.beads/issues.jsonl \
    jeff-ubuntu:/home/jleechan/.local/state/dark-factory/.beads/issues.jsonl.tmp
```

This copies a `.tmp` file. The daemon reads from the canonical filename, not from `.tmp`. Even after a rename, it would be a one-way overwrite that risks:

- wiping Linux-only beads (any bead added to jeff-ubuntu's repo between flushes would be clobbered by Mac's older state)
- getting clobbered itself by the daemon's next internal flush (which uses temp-file-then-rename and may race with rsync)

So manual rsync is wrong in both directions.

## The one-line fix (operator-side) — file in the daemon's store directly

On **jeff-ubuntu**, in the **daemon's bead-store directory**:

```bash
# 1. Discover the daemon store path
DAEMON_STORE=$(ssh jeff-ubuntu 'systemctl --user show ai.dark-factory.daemon.service -p Environment | grep DARK_FACTORY_BR_DB | sed "s/.*=//"' 2>/dev/null)
DAEMON_DIR=$(dirname "$DAEMON_STORE")

# 2. File the bead directly in the daemon's store
ssh jeff-ubuntu "cd ${DAEMON_DIR} && \
  ~/.local/bin/br create '<title>' --type task --priority N --labels factory \
  --description \"\$(cat /tmp/<bead-desc>.md)\""
```

This puts the bead directly into the daemon's authoritative SQLite + JSONL. The daemon's NEXT tick (within ~15s) reads it.

After this lands, verify:

```bash
ssh jeff-ubuntu "cd ${DAEMON_DIR} && ~/.local/bin/br show <bead_id>"
```

Should return the bead's title, description, and labels.

Then verify daemon visibility:

```bash
ssh jeff-ubuntu "tail -50 /home/jleechan/Library/Logs/dark-factory/daemon.jsonl | grep -aE '<bead_id>'"
```

## The actually-correct workflow

From Mac, when you need to drive a labeled PR through the daemon:

1. **Discover the daemon's store path** via `systemctl --user show ... -p Environment | grep DARK_FACTORY_BR_DB`.
2. **File the bead on Mac anyway** with all drive-existing-pr fields filled out — this gives you an audit record on the operator-client side and lets you verify the bead body before shipping it.
3. **`br show <id>` to verify** on Mac — title, labels, body, drive-existing-pr fields all correct.
4. **`scp` the bead description** to `/tmp/<bead-id>-description.md` on Linux.
5. **Run `br create` ON Linux in the daemon's store directory** with the full path: `ssh jeff-ubuntu "cd \$(dirname \$DARK_FACTORY_BR_DB) && ~/.local/bin/br create ... --description \"\$(cat /tmp/<bead-desc>.md)\""`.
6. **Run the verification shell** to confirm the daemon picks it up on the next tick.
7. **Post status update in the originating thread** with the cron job ID for the one-time status babysit.

## Alternative: file the bead ON Linux only

If filing the bead on Mac is overkill (audit trail, etc.), you can skip step 2 and just emit the shell command for the operator to run directly on jeff-ubuntu in the daemon's store directory. The bead audit history lives on Linux in that case.

## Future durable fix (tracked separately)

The right fix is a launchd-managed one-way `rsync` from jeff-ubuntu's `/home/jleechan/.local/state/dark-factory/.beads/` to a known operator-client mount, gated on JSONL mtime. This would let Mac sessions `read` daemon visibility without round-tripping through SSH. Until that's wired, this skill's operator-side workaround is the canonical path.

## What NOT to do

- ❌ `rsync` Mac JSONL → daemon's JSONL (wrong path; loses daemon's authoritative state).
- ❌ `br sync --flush-only --force` in `~/projects/dark-factory/` (wrong directory; loses 2 Mac-only beads: rev-fo34v, rev-hzch2.1 — these are part of an audit history; do not destroy).
- ❌ Edit daemon's `.beads/issues.jsonl` directly with `write_file` (the daemon will overwrite your edit on next internal flush).
- ❌ Pretend the bead is dispatched when only the Mac SQLite has it. The owner of "bead filed" is the daemon, not br on Mac.
- � **File a local bead with `factory` label and expect the daemon to pick up a PR**. The daemon's intake is GitHub-PR-driven; manually-filed beads with `factory` label will be parked as `unmapped_repo` (Class E). The entry point is to apply the `factory` label on the GitHub PR — the daemon creates its own bead.
