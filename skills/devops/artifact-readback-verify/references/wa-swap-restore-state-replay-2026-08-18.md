# wa-swap-restore-state-replay — disk-state integrity check during BEFORE/AFTER capture

Two distinct failure patterns from the **PR #9096** (`fix/avatar-circular-add-btn`) session, both observed in the local BEFORE/AFTER PNG capture loop. Both are subtle because the file looked plausible under `ls -la` but the bytes were wrong.

## Failure A: silent disk-state replay (bytes reverted, working tree doesn't show it under diff against origin/main yet)

### Sequence

1. Agent edited two files in a `git worktree add -b fix/... origin/main` worktree: `mvp_site/frontend_v1/css/avatar.css` and `mvp_site/frontend_v1/app.js`. Both patches landed; `node --check` passed.
2. To capture BEFORE, the agent's Playwright capture script did:
   - `git show origin/main:mvp_site/frontend_v1/css/avatar.css > $CSS_PATH` (swap to baseline)
   - `git show origin/main:mvp_site/frontend_v1/app.js > $JS_PATH`
   - `restart_server()` (so Flask picked up the baseline bytes)
3. Mid-capture, the network or process group caused a `ConnectionRefusedError` on the Playwright run, throwing inside the script before the `restore backup_*` step ran.
4. Script resumed; agent re-ran `restart_server()` and a second capture attempt and the **"restore fix"** step — `open($CSS_PATH, 'wb').write(backup_css)`. But the `backup_css` variable was set BEFORE the swap. The expected state on disk should have been the patched bytes; instead the bytes being written back were the same pre-fix baseline that the swap also wrote. Net effect: the file ended up at pre-fix content even though the variable name said "fix".
5. `git diff --stat origin/main..HEAD` reported **empty** — because `HEAD = origin/main` (this is fresh worktree, no commits yet); the modifications live in the working tree only, and at this point the working tree ALSO matches origin/main by accident.
6. `git status -sb` showed `## fix/avatar-circular-add-btn...origin/main` with the `M` markers, but `git diff --stat origin/main..HEAD` was empty because both `HEAD` and `origin/main` resolved to the same commit AND the working-tree patches were now reverted.

### The tell

`rg -c "game-avatar-add-btn" mvp_site/frontend_v1/css/avatar.css` returned **0**, even though the agent had already seen 10 hits earlier in the session. That was the proof the bytes were wrong; the working tree was at pre-fix content.

### The fix — pre/post integrity check with sha256sum + expected-token grep

```python
import hashlib, subprocess

def file_token(path, token):
    return int(subprocess.run(['rg', '-c', token, path], capture_output=True, text=True).stdout.strip() or 0)

def file_sha(path):
    return hashlib.sha256(open(path, 'rb').read()).hexdigest()[:12]

# BEFORE the swap (post-fix state)
expected_sha = file_sha(css_path)
expected_token_count = file_token(css_path, 'game-avatar-add-btn')

# Save into the captured log:
print(f'STATE BEFORE SWAP: sha={expected_sha} tokens={expected_token_count}')
# expected_sha = 'a1b2c3d4...'  (post-fix hash)
# expected_token_count = 10

# Do the swap, capture BEFORE, then restore.

# AFTER the restore (re-apply)
# Re-apply the patch if the post-restore sha/tokens don't match:
post_restore_sha = file_sha(css_path)
post_restore_tokens = file_token(css_path, 'game-avatar-add-btn')
assert post_restore_sha == expected_sha and post_restore_tokens == expected_token_count, (
    f'DISK-STATE REPLAY DETECTED: '
    f'sha was={expected_sha} now={post_restore_sha}, '
    f'tokens was={expected_token_count} now={post_restore_tokens}. '
    f'Re-apply the patch and re-verify.'
)
```

The `assert` is the readback. If the restoration silently reverted the working tree to pre-fix content, the post-restore sha/tokens differ from the pre-swap recorded values, the assertion fires, and the script logs the discrepancy with enough detail to know which file to re-patch.

### Companion rule — don't trust `git diff --stat origin/main..HEAD` alone as the patch readback

`git diff --stat` reports the diff between the named commits, **not** the working-tree state. On a freshly-checked-out worktree, both `HEAD` and `origin/main` resolve to the same commit, and the working-tree delta vs. `HEAD` is invisible to `git diff <rev>..HEAD` — you need `git status -sb` (which shows working-tree mods as ` M <path>`) or `git diff HEAD -- <path>` (working-tree vs HEAD) or `git diff -- <path>` (working-tree vs index).

Use **all four** of these readbacks before claiming a fix is ready:

```bash
# 1. Working-tree vs HEAD  (catches edits not yet staged)
git diff HEAD -- mvp_site/frontend_v1/css/avatar.css | rg -c 'game-avatar-add-btn'

# 2. Index vs HEAD  (catches staged edits)
git diff --cached -- mvp_site/frontend_v1/css/avatar.css | rg -c 'game-avatar-add-btn'

# 3. Working-tree token grep  (catches the byte-content itself)
rg -c 'game-avatar-add-btn' mvp_site/frontend_v1/css/avatar.css

# 4. SHA  (catches silent bit-rot from a bad restore)
sha256sum mvp_site/frontend_v1/css/avatar.css
```

If (3) returns 0 after the agent is supposed to be at the fix state, but (1) `git diff HEAD` shows 80+ lines of `+` for that class — investigate. The most likely cause: a stale `backup_*` variable silently overwrote the working tree.

## Failure B: file:// harness cannot load cross-origin CSS, getComputedStyle returns browser defaults

### Sequence

1. Agent created a standalone HTML harness at `<worktree>/evidence/_harness.html` to render BEFORE/AFTER side-by-side. The harness `<link>`s the real worktree CSS:

   ```html
   <link rel="stylesheet" href="../../mvp_site/frontend_v1/css/avatar.css" />
   ```

2. Playwright opens the harness via `file://` URL (because no Flask server was running). The page loads, but `<style>` rules in the harness override the new `.game-avatar-add-btn` rule — the `--add-btn-icon svg { width: 32px }` etc. are inherited, but `border-radius`, `width`, `height`, `border-style`, `box-shadow` — set in the worktree CSS — are NOT applied. The button renders as a default browser button: `width: 115px; height: 41px; border-radius: 0; border-style: outset; background: rgb(239,239,239)`.

3. `await page.evaluate(...)['.game-avatar-add-btn'].getComputedStyle(...)` returns:
   ```
   {'width': '115.953px', 'height': '41px', 'borderRadius': '0px', ...}
   ```

4. `rg -c "game-avatar-add-btn" mvp_site/frontend_v1/css/avatar.css` returns 10 — the CSS rule IS on disk. The browse-time behavior is decoupled from the disk-time assertion.

### The fix — serve the harness from the same Flask server, then curl the CSS endpoint to verify

```bash
# Start the test server
cd <worktree> && TESTING_AUTH_BYPASS=true ./run_test_server.sh start
# -> Port 8081 / 8082 printed

# Curl the CSS endpoint directly to confirm the rule is in the served bytes
curl -s "http://localhost:8081/frontend_v1/css/avatar.css" | grep -c "game-avatar-add-btn"
# Expect 10+

# Open the harness via the server, NOT file://
# Playwright: page.goto("http://localhost:8081/evidence/_harness.html")
```

The double-curse of `file://`:

- Chromium treats each `file://` origin as a separate origin for security purposes. A `<link href="../../mvp_site/frontend_v1/css/avatar.css">` from `file:///private/tmp/wt-.../evidence/_harness.html` cross-origin-requests the CSS from a different `file://` origin. **Result: 404 or CORS rejection depending on Chromium version.**
- Even when the link resolves (e.g. via symlink resolution), file:// headers don't match `text/css` MIME expectations, so some renderers silently drop the ruleset.

The Flask static server in `worldarchitect.ai` already serves everything from the worktree root, including `evidence/` (because Flask's catch-all route in `main.py` returns 200 OK for any path not under `/api/...`). Verify with:

```bash
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8081/evidence/_harness.html"
# Expect 200
```

If the harness route 404s, the Flask catch-all isn't catching it. Move the harness under `<worktree>/mvp_site/frontend_v1/evidence/` so it lives inside Flask's static dir, or symlink `<worktree>/evidence` → `<worktree>/mvp_site/frontend_v1/evidence`.

### Companion rule — `git show origin/main: > file` swap requires server restart even when nothing changed

Flask (and most static-file servers) caches by file mtime + path. After `git show origin/main:foo.css > foo.css`, file mtime updates, but Flask's `send_from_directory` may still hit a previous response if the headers include a strong ETag matching the pre-swap content. Always `run_test_server.sh restart` between BEFORE and AFTER captures to bust the cache. Verified: the script in PR #9096 forgot to restart between swap-and-restore, captured "BEFORE" content that was actually still showing post-fix CSS, and only caught it when `curl -s http://localhost:8081/frontend_v1/css/avatar.css | grep -c` returned 10 instead of 0.

## The combined checklist for any UI BEFORE/AFTER PNG capture

```bash
# 1. Working tree is clean from origin/main
git -C <worktree> diff --stat HEAD
git -C <worktree> status -sb
# Expect: M <path> for the files you'll edit, ?? for evidence/

# 2. (After patches) record pre-swap state for the swap-and-restore round-trip
sha256sum mvp_site/frontend_v1/css/avatar.css app.js > /tmp/before_swap.sha
rg -c <expected-new-token> mvp_site/frontend_v1/css/avatar.css > /tmp/before_swap.tokens

# 3. Swap to origin/main for BEFORE PNG
git -C <worktree> show origin/main:mvp_site/frontend_v1/css/avatar.css > <css_path>
git -C <worktree> show origin/main:mvp_site/frontend_v1/app.js        > <js_path>

# 4. Restart the server so the cache is busted
<worktree>/run_test_server.sh restart

# 5. Verify the served CSS is now baseline
curl -s http://localhost:8081/frontend_v1/css/avatar.css | grep -c <expected-new-token>
# Expect 0 for BEFORE state

# 6. Capture BEFORE PNG via Playwright, vision_verify

# 7. Restore: rewrite the post-fix bytes from the SAME source you saved (NOT a re-`git show`)
#    This is what makes the swap-restore safe — never re-read source mid-script
open(<css_path>, 'wb').write(<saved_post_fix_bytes>)
open(<js_path>,  'wb').write(<saved_post_fix_bytes>)

# 8. Restart server, verify served CSS is post-fix
<worktree>/run_test_server.sh restart
curl -s http://localhost:8081/frontend_v1/css/avatar.css | grep -c <expected-new-token>
# Expect 10+ for AFTER state

# 9. Post-restore integrity check
sha256sum -c /tmp/before_swap.sha  # SHOULD report mismatch on the patched file!
# The mismatch is EXPECTED — the saved sha was the post-fix state, the file should match it now.
# The check that FAILS the bug is: hashes match when the post-restore bytes were stale.
# Or, simpler: re-record the post-restore sha and compare to the pre-swap recorded sha.
sha256sum mvp_site/frontend_v1/css/avatar.css >> /tmp/before_swap.sha
diff <(head -1 /tmp/before_swap.sha) <(tail -1 /tmp/before_swap.sha)
# Empty diff = bytes are identical = restoration succeeded.

# 10. Capture AFTER PNG via Playwright, vision_verify
# 11. Commit + push + gh pr create + visual proof attached.
```

The bug class is **silent disk-state replay under a swap-and-restore script**. The single-line guard is `sha256sum` + `grep -c <expected-token>` BEFORE the swap and AGAIN AFTER the restore; if the AFTER values don't match the BEFORE values, the restoration silently reverted to a stale baseline, and re-applying the patch is cheaper than shipping a PR with no diff.
