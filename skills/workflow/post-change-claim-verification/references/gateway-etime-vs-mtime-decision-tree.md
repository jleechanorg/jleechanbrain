# Gateway etime vs File mtime — Decision Tree

The runtime-vs-disk delta check (see SKILL.md §"The Runtime-vs-Disk Delta Check") hinges on comparing **when the gateway started** vs **when the file was last modified**. This document spells out the exact comparison logic and edge cases.

## The Core Comparison

```bash
PID=$(pgrep -f "hermes gateway run" | head -1)
PID_LSTART_EPOCH=$(ps -p "$PID" -o lstart= | date -j -f "%a %b %d %T %Y" "+%s" 2>/dev/null)
FILE_MTIME_EPOCH=$(stat -f "%m" ~/.smartclaw/workspace/SOUL.md)

if [ "$FILE_MTIME_EPOCH" -gt "$PID_LSTART_EPOCH" ]; then
  echo "D1: file modified AFTER gateway started → gateway has NOT loaded the change"
else
  echo "OK: file modified BEFORE gateway started → gateway has the change"
fi
```

## Edge Cases

### 1. `cp -p` preserves mtime

If you used `cp -p ~/.smartclaw/workspace/SOUL.md ~/.smartclaw_prod/workspace/SOUL.md` to deploy (preserves timestamps), the file mtime stays at the original edit time — NOT the copy time. The delta check still works correctly because the mtime reflects the actual edit, not the deployment.

**Anti-pattern:** `cp` (no `-p`) updates mtime to copy time. This makes the check report "file modified AFTER gateway started" even when the file CONTENT is unchanged from the gateway's perspective. Always use `cp -p` for policy-file deployment.

### 2. `git checkout` preserves mtime

`git checkout <sha>` for an already-tracked file preserves the file's index mtime, but the working-tree mtime updates to checkout time. The runtime-vs-disk check uses the **working-tree mtime** (`stat -f "%m"`), which after a checkout reflects the checkout time.

**Implication:** if the agent runs `git checkout` to "deploy" a policy file change, the mtime is updated and the delta check works correctly. But this also means a `git checkout` of an OLDER SHA on an unchanged file will falsely report "modified" — re-check the file CONTENT (`grep -c "^## COMMIT: <name>$"`) not just the mtime.

### 3. `deploy.sh` rewrites mtime even on `[single-dir]` mode

In `[single-dir]` mode (`~/.smartclaw_prod` is a symlink to `~/.smartclaw`), `deploy.sh` Stage 4.5 file-sync is a no-op for the actual file content, but the script may still `touch` the prod tree to bump the mtime. This makes the delta check report "modified" without an actual content change.

**Workaround:** after a deploy, also check the file CONTENT diff (`diff -q` or `grep -c`) before trusting the mtime alone.

### 4. SOUL.md in workspace/ is gitignored except for tracked files

`~/.smartclaw/workspace/SOUL.md` is gitignored (with the `!workspace/README.md` exception). To commit a SOUL.md change, use `git add -f workspace/SOUL.md`. If you forget the `-f`, `git status` doesn't show the change and `git commit` skips it — but the working-tree mtime DOES update, so the runtime-vs-disk check still works (it reads from disk, not git).

### 5. Gateway restart resets the comparison anchor

After a `hermes gateway restart`, the PID changes AND the lstart updates to the restart time. Any file mtime older than the restart time now correctly reports "gateway started AFTER the change → LOADED." This is the success case.

**Verify the restart took effect** by checking the PID post-restart: `pgrep -f "hermes gateway run" | head -1` should return a NEW PID, not the old one.

### 6. Two gateways running simultaneously

`pgrep -f "hermes gateway run" | head -1` takes only the first PID. If a stale gateway is running alongside the new one (race during restart), the check may inspect the wrong process. Use `pgrep -fa "hermes gateway run"` to see ALL matching processes, and check that exactly one is running.

## Visual Decision Tree

```
file mtime > gateway lstart?
├── YES → D1: gateway started BEFORE the change
│         → action: `hermes gateway restart` from a separate terminal
│         → after restart, PID changes; new lstart > file mtime → LOADED
└── NO → file mtime < gateway lstart (gateway started AFTER)
          └── check file CONTENT diff (not just mtime)
              ├── diff -q returns 0 → content matches → fix is live
              └── diff -q returns non-0 → staging/prod drift
                  ├── D2: skill file or config in wrong tree
                  │     → action: `cp -p <file> ~/.smartclaw_prod/<file>`
                  └── D3: SOUL.md COMMIT in wrong tree
                        → action: `cp -p ~/.smartclaw/workspace/SOUL.md ~/.smartclaw_prod/workspace/SOUL.md`
```

## What "live" actually means for each class

| Class | "Live" criteria |
|---|---|
| **D1 — config change** | PID post-restart has lstart > config mtime, AND `/health` returns 200, AND a probe of the changed config (e.g., `disabled_toolsets` reflects the change) returns the expected value |
| **D2 — skill / config file** | `diff -q` returns 0 AND the running process has re-loaded the skill (next session start, or `skill_view` returns the new version) |
| **D3 — SOUL.md COMMIT** | `grep -c` returns ≥1 in BOTH trees AND the next session-init loads the new COMMIT trigger |
| **D4 — deploy silent-fail** | `deploy.sh` Stage 4.5/4.6 logs show "synced" markers AND `diff -q` on the affected files returns 0 |

## See also

- SKILL.md §"The Runtime-vs-Disk Delta Check" — the canonical 4-command recipe.
- SKILL.md §"Per-Class Action Recipes" — D1/D2/D3/D4 specific fixes.
- `references/delta-check-one-liner.md` — the copy-pasteable one-liner.
