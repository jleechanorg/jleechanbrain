---
name: fail-closed-shell-lifecycle
description: Use when writing any shell wrapper that touches credentials.
---

# Fail-closed shell lifecycle

A shell script that creates credential-bearing or otherwise sensitive temp artifacts at rest MUST follow the **one-canonical-trap-per-artifact** discipline. This is the umbrella for the trap-arm, umask, recipe-extractor, and multi-round-review-iteration patterns that any credential-cleanup shell needs.

Class-level: covers any shell wrapper around `browserclaw`, `aside repl`, `chrome --dump-dom`, `keychain export`, HAR capture, DOM scrapes of auth-gated pages, etc.

## The canonical pattern (arm at top, never disarm)

```bash
set -euo pipefail
umask 077                  # restrict umask for every indirected write
TMP_COOKIES="$(mktemp -t xyz-XXXXXX.json)"
TMP_PAGE="$(mktemp -t xyz-page-XXXXXX.txt)"
chmod 600 "$TMP_COOKIES" "$TMP_PAGE"

cleanup() { rm -f "$TMP_COOKIES" "$TMP_PAGE"; }
trap cleanup EXIT INT TERM HUP

# ... work ...

# Clean exit: the EXIT trap fires cleanup once. No explicit
# cleanup call. No `trap -` line.
exit 0
```

Four rules, in priority order:

1. **`trap` is the cleanup. There is no explicit cleanup call.** `rm -f` is idempotent so a normal EXIT firing the trap is identical to an explicit cleanup call at the end.
2. **Trap is armed at the top and NEVER disarmed.** No `trap - EXIT INT TERM HUP` line anywhere.
3. **Signal handler exits with `128+sig`, NOT `kill -SIG $$`.** bash swallows a re-raised same signal; use `exit 130`/`143`/`129` directly.
4. **Every external writer that produces a credential artifact MUST be followed by `chmod 600`.** `Path.write_text()` and `open(..., 'w')` honor the process umask; they do not enforce restrictive modes themselves.

## Anti-pattern #1 — `trap -` at the end of the recipe

This is the single most common credential-leak bug. The recipe finishes its work, calls an explicit `cleanup`, then disarms the trap and exits normally. A signal arriving between the last artifact write and the disarm line leaves the trap empty, and the credential file orphans on disk.

```bash
# WRONG
cleanup_creds
trap - EXIT INT TERM HUP      # disarms the cleanup; any late signal
                              # leaves the credential file behind
```

### Diagnostic gate (run before declaring the recipe done)

The shipped audit script is canonical:

```bash
~/.smartclaw/skills/software-development/fail-closed-shell-lifecycle/scripts/audit-recipe.sh ./your-recipe.sh
```

It catches: missing `set -euo pipefail` / `umask 077`, `trap -` disarm lines, `kill -SIG $$` re-raises in signal handlers, fixed `/tmp/<name>` paths.

Manual equivalent:

```bash
grep -n 'trap - ' recipe.sh                # must be empty
grep -n 'kill -[A-Z]* \$\$' recipe.sh      # must be empty inside signal handlers
grep -n '^umask' recipe.sh                  # must have `umask 077`
grep -n 'chmod 600' recipe.sh              # must follow every external write
```

If any of those return hits, the recipe is not fail-closed.

## Anti-pattern #2 — `kill -SIG $$` re-raise in signal handlers

bash by default ignores the same signal twice in quick succession. `kill -INT $$` re-raises the signal that just arrived and bash stays alive in the trap.

```bash
# WRONG
exit_on_signal() {
  cleanup_creds || true
  kill -INT "$$" 2>/dev/null || true
  exit "$?"
}
```

The correct pattern exits `128+sig` directly from the handler:

```bash
exit_on_signal() {
  cleanup_creds || true
  case "${1:-INT}" in
    INT)  exit 130 ;;
    TERM) exit 143 ;;
    HUP)  exit 129 ;;
    *)    exit 130 ;;
  esac
}
trap 'exit_on_signal INT'  INT
trap 'exit_on_signal TERM' TERM
trap 'exit_on_signal HUP'  HUP
trap cleanup EXIT
```

## Anti-pattern #3 — relying on external tools to enforce `0600`

`browserclaw`, Playwright, `chrome --print-to-pdf`, and similar writers use `Path.write_text()` or `open(..., 'w')` which honor the process `umask` — they do not enforce a restrictive mode themselves. The recipe MUST:

1. `umask 077` at the top (defense in depth for any redirect that bypasses `chmod`).
2. Re-apply `chmod 600` immediately after every external write that produces a credential file. The order matters — `chmod` AFTER the write, never before:

```bash
env -i HOME="$HOME" ... browserclaw cookies decrypt \
    --output "$TMP_COOKIES" ... || true
chmod 600 "$TMP_COOKIES"
```

## Anti-pattern #4 — sweep that fails fast on first empty profile

A sweep over Chromium profiles (Aside, Chrome Default, Chrome Profile 1+, Brave, Edge) MUST tolerate empty DBs in early iterations and only break when a profile returns a non-empty cookie JSON. The sweep must run inside `set +e ... set -e` so any nonzero exit inside the loop doesn't abort the whole sweep:

```bash
set +e
for entry in \
  "Aside:$HOME/Library/Application Support/Aside/Default/Cookies:Aside Safe Storage:Aside" \
  "Chrome-Default:$HOME/Library/Application Support/Google/Chrome/Default/Cookies:Chrome Safe Storage:Chrome" \
  "Edge:$HOME/Library/Application Support/Microsoft Edge/Default/Cookies:Microsoft Edge Safe Storage:Microsoft Edge"; do
  IFS=: read label db svc acct <<< "$entry"
  [ -f "$db" ] || continue
  env -i HOME="$HOME" ... browserclaw cookies decrypt \
    --output "$TMP_COOKIES" --keychain-service "$svc" \
    --keychain-account "$acct" --domain-filter '%<vendor>%' --summary >/dev/null 2>&1 || true
  if [ -s "$TMP_COOKIES" ]; then
    count="$(jq -r '.cookies | length' "$TMP_COOKIES" 2>/dev/null || echo 0)"
    [ "$count" -gt 0 ] && { chmod 600 "$TMP_COOKIES"; break; }
  fi
  rm -f "$TMP_COOKIES"
done
set -e
```

The matched profile is logged to stderr for traceability.

## Recipe-extractor pattern (for testing recipes embedded in markdown)

When testing a documented bash recipe by extracting it from a markdown block and running it in a hermetic temp dir, the extractor MUST replace ALL THREE of:

1. **Every `env -i ... \` continuation block** (including those inside loops). Replacing only the FIRST block leaks real tool calls into the user's environment.
2. **Every `set +e ... set -e` block** (the sweep). Same reason.
3. **Every other external-tool invocation** that would touch user state.

Replace each block with a hermetic no-op stub (e.g. `jq -n '...' > "$TMP_COOKIES"`). The point: the test runs THE EXACT documented lifecycle shape but with deterministic no-op content, so it never invokes the real tool.

```python
import re
def extract_recipe(md_text: str, marker: str) -> str:
    body = md_text.split(marker, 1)[1]
    m = re.search(r"```bash\n(.*?)\n```", body, re.DOTALL)
    recipe = m.group(1)
    recipe = re.sub(
        r"set \+e\n.*?\nset -e\n",
        'echo "[stub: sweep elided]"\n',
        recipe, flags=re.DOTALL,
    )
    recipe = re.sub(
        r"env -i[^\n]*\\\n(?:[ \t]*[^\n]*\\\n)*",
        'jq -n \'{"cookies":[{"name":"__test__","value":"stub"}]}\' '
        '> "$TMP_COOKIES" \\\n',
        recipe, flags=re.MULTILINE,
    )
    return recipe
```

The hermetic test runs the recipe with `TMPDIR=td` and asserts no leftover `browserclaw-*` files AND that the cleanup trap fires on `bash -INT $$`.

## Multi-round review iteration expectation

Recipes that handle credentials/secret-pages/cookies typically need **at least 6 rounds** of /er + /advice review before PASS, and a late-arriving verdict (delivered AFTER a "PASS" was declared) can still flag real defects. The pattern:

- Run /er and /advice in parallel after each fix.
- Apply round-N fixes; re-run /er and /advice for round N+1.
- When /er and /advice both say PASS, COMMIT and open the PR.
- If a LATER round delivers NOT_APPROVED after you committed the prior PASS state, the round's defensible finding wins. Patch the recipe, add a regression test that would have caught it, push the new commit, and let the one-time status cron re-check.
- The contract test file MUST grow with every reviewer-flagged defect — if a finding is unaddressed, the next reviewer will find it again.

## Lifecycles that MUST use this skill

- Auth-gated share-link reading (cookie decrypt → inject → page text)
- HAR-based capture (only when explicitly required for non-secret APIs)
- Keychain export to temp JSON
- Playwright scripts that read auth-gated DOM into `$TMP_PAGE`
- Any shell wrapper that touches cookies, sessions, tokens, or captured DOM

## Lifecycles that do NOT need this skill

- One-shot curl with no temp file
- Long-running daemons (trap on signal, no temp cleanup needed)
- Wrapper scripts that only proxy stdin/stdout

## Quick checklist before declaring done

- [ ] `set -euo pipefail` at the top
- [ ] `umask 077` at the top
- [ ] `mktemp -t <prefix>-XXXXXX.<ext>` for every artifact
- [ ] `chmod 600` after every external write
- [ ] ONE cleanup trap on `EXIT INT TERM HUP` (and `TERM` if the lifecycle is long)
- [ ] Signal handlers exit `128+sig` directly — never `kill -SIG $$`
- [ ] No `trap -` line anywhere
- [ ] No explicit `cleanup_function` call followed by `exit` (the trap IS the cleanup)
- [ ] No /tmp/ fixed paths — every output is `$TMP_*`
- [ ] No `print_text | tee /tmp/...` — every captured artifact routes through `$TMP_*`
- [ ] `grep -n 'trap - '` returns no hits
- [ ] `grep -n 'kill -[A-Z]* \$\$'` returns no hits inside signal handlers
- [ ] All sweep loops wrap in `set +e ... set -e`
- [ ] Recipe-extractor test is hermetic (no real tool calls against user profiles)
- [ ] Cleanup-on-signal test asserts `128+sig` exit AND zero leftover temp files

## Bundled assets

- `scripts/audit-recipe.sh` — runs the diagnostic gate over any shell recipe
