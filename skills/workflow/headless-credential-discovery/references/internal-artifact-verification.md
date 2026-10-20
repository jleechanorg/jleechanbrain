# Internal-artifact verification — the 6-check recipe

Companion to the main `headless-credential-discovery` SKILL.md. Where the
parent skill probes **credential stores** (cookies, keychain, password vaults,
cloud drives) to **find** content, this reference probes **existence surfaces**
to **verify** a user-named internal artifact (env var, tool, code path, project
codename, saved browser session) before guessing.

## Why this is a separate recipe

The parent skill assumes the artifact name is real and we need to find its
content. The internal-artifact case is the inverse: the user names an artifact
the agent has no record of ("use firework", "deploy k8s", "the new beacon
tool"), and the cost of guessing wrong is a wasted worktree + a wasted
claudem budget + a user-correction round-trip.

The 6-check recipe verifies the artifact exists on this machine in ~3-5 seconds
(pure local greps, no LLM) before any dispatch.

## When to fire this

ANY of:
- The user names an internal tool, env var, or feature by name and the agent
  has no record of it ("use firework to repro", "run the beacon tool", "load
  the quasar creds").
- The user gives a 1-word tool/feature name with no qualifier ("use firework").
- The user provides a name that could be (a) a vendor (use vendor-webcheck-first)
  OR (b) something internal (this recipe). Run both — cheap, parallel.
- The user says "from bashrc", "the creds", "the tool we use" — those are
  pointers to check, not the answer itself.

## The 6-check recipe

Run all 6 in **one `execute_code` call** (or parallel terminal commands) so
they execute concurrently. Read-only probes; no mutations until the artifact
is verified.

```python
import subprocess

def run(label, cmd, cwd=None):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                       timeout=30, cwd=cwd)
    print(f"--- {label} ---")
    print(r.stdout if r.stdout else "(empty)")
    if r.stderr.strip():
        print(f"stderr: {r.stderr.strip()[:200]}")
    return r

# 1. Shell env (current)
run("1. env",
    "env | grep -i '<name>' | sed 's/=.*/=<set>/'")

# 2. Persistent env files (bashrc, zshrc, profile, .env_secrets vault)
run("2. bashrc/zshrc",
    "grep -in '<name>' ~/.bashrc ~/.zshrc ~/.profile ~/.env_secrets 2>/dev/null | sed 's/=.*/=<set>/'")

# 3. macOS Keychain (if applicable)
run("3. keychain",
    "security find-generic-password -l '*<name>*' 2>&1 | head -3; "
    "security find-generic-password -s '<name>*' 2>&1 | head -3")

# 4. Repo source code (current working repo + known alternates)
run("4. source code",
    "grep -rln -i '<name>' mvp_site/ testing_mcp/ testing_ui/ scripts/ "
    "--include='*.py' --include='*.ts' --include='*.tsx' --include='*.js' "
    "--include='*.yaml' --include='*.yml' --include='*.json' 2>/dev/null "
    "| grep -v node_modules | grep -v __pycache__ | grep -v '.git/' | head -10")

# 5. Git history (commit messages, file references)
run("5. git history",
    "git log --all --oneline --grep -i '<name>' 2>/dev/null | head -10",
    cwd="<repo>")

# 6. Open / closed PRs and issues
run("6. PRs + issues",
    "gh pr list --repo <owner>/<repo> --search '<name>' --state all --limit 10; "
    "gh issue list --repo <owner>/<repo> --search '<name>' --state all --limit 10")
```

**Total cost:** ~3-5 seconds wall time when run in parallel. Each check is
read-only. The output is 6 grep results + a clear verdict.

## Interpreting the result

| Hits | Verdict | Action |
|---|---|---|
| 6/6 | Real artifact, widely used | Proceed with the user's task. No clarification. |
| 1-2/6, but in obvious places (bashrc, keychain) | Real but limited surface | Proceed; note the surface in your reply. |
| 1-2/6, in unexpected places (vendored deps, code that doesn't import) | Possibly a typo | Symbol-search the canonical form before assuming. |
| 0/6 across all checks | **Artifact is undefined** on this machine. | Surface the negatives + ask ONE question with ranked possibilities. |

## What to do when 0/6

Do NOT post a multi-option menu / fork. Do NOT pre-create a worktree or
dispatch a worker — they cost budget the agent will need to retry once the
user clarifies.

DO:
1. Paste the actual command output (the 6 negatives) — proof of attempt.
2. Ask ONE question with the most likely interpretations ranked. Examples:
   - "I checked 6 surfaces (bashrc, env, keychain, source, git log, PRs) — zero hits for 'firework'. Most likely: (1) Fireworks AI as a new provider, (2) typo for 'firefox', (3) something else. Reply with the one that fits."
3. Honor the 60-min silence rule from `finish-the-job` — if the user doesn't
   answer within an hour, make the most-likely interpretation explicit and
   act on it (e.g., dispatch on interpretation #1). Don't keep waiting.

## Worked example — 2026-08-17 firework incident

Operator message (Slack thread `C0BDEAJH8PK/p1786998957.366159`):
> "Investigate and see if we can repro using firework and use jleechantest creds from bashrc"

The 6-check recipe returned **0 hits everywhere** for "firework":
- `~/.bashrc` only had `TEST_EMAIL="jleechantest@gmail.com"` and `TEST_PASSWORD="yttesting"` (the creds the user asked us to use).
- env: 0 hits.
- Keychain `*firework*`: not found.
- `~/projects/worldarchitect.ai/mvp_site/`: 0 hits (WA's LLM providers are gemini/cerebras/openrouter/openclaw/minimax/minimax_portal — no Fireworks integration).
- `git log --all --grep -i firework`: 0 hits.
- `gh pr list --search firework`: 0 hits.

Also checked `https://api.fireworks.ai/` — 404 (network reachable but endpoint
path wrong, OR the API surface changed).

**Action taken:** Pasted the 6 negatives + 3 ranked possibilities (Fireworks AI
typo for firefox / something else) + offered the smallest concrete next step
("reply 'firefox' to greenlight a claudem worker on headed Firefox with
jleechantest creds"). No worktree created, no claudem dispatched, no
speculative execution.

**Cost saved:** ~60-min claudem budget on a clean worktree + the user-correction
round-trip that would have followed once the worker discovered "firework" was
undefined.

## When NOT to use this recipe

- **The user gave explicit credentials in the current message** — use them
  directly, no probe needed.
- **The user named an external vendor artifact** (a model name, API endpoint,
  public library) — use `vendor-webcheck-first` Section 1 instead (curl
  vendor docs).
- **The user is frustrated about a 2+ option fork** — use the parent
  `headless-credential-discovery` skill (probes for content, not existence).
- **You're in a single-source-only context** (e.g., Claude Code sandbox with
  no repo access) — the git-log / PR-list checks won't run; rely on env +
  bashrc + keychain + a quick question.

## Cross-references

- `vendor-webcheck-first` — Section 1 covers external (vendor) artifact
  verification. Section 2 there is the parallel recipe for internal artifacts;
  this reference is the verbose version with the worked example.
- `finish-the-job` — drives the work to one of four end-states; this skill
  feeds it the verified state before dispatch.
- `pre-execution-option-bailout-guard` (SOUL.md COMMIT) — bans multi-option
  menus mid-stream. This recipe produces the evidence that lets you ask ONE
  precise question instead of guessing.
- `agent-autonomy-failure-classes` — the "guessing the tool name" failure
  class is a documented anti-pattern; this recipe is the structural fix.
