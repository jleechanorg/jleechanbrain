---
name: vendor-webcheck-first
internal-aliases: []
version: 1.0.0
description: "Use when a user names a specific external artifact (model name, API endpoint, library version, product release, public figure's recent claim) and the agent's training-data cutoff or session memory may be older than the artifact. Trigger pattern: 'Where is the <X> PR?', 'Add <model Y> to settings', 'Did <company> ship <thing>?', 'Is <Z> a real thing?'. Behavior: curl the vendor's authoritative source (docs site, release notes, official API reference) and grep for the named artifact BEFORE treating it as a typo, fictional, or stale. Only ask the user 'did you mean something else?' after the vendor check returns 404 or no-match. Companion to SOUL.md `## COMMIT: vendor-webcheck-first`."
tags: ["verification", "harness", "autonomy", "no-clarification-freeze", "web-check"]
category: workflow
triggers:
  - "user named an external artifact"
  - "model name PR"
  - "add to settings"
  - "shipped today"
  - "is X real"
  - "did Y release Z"
  - "is this a typo"
  - "stopping to confirm"
  - "user named vendor thing"
changelog:
  - "1.0.0 (2026-08-14): Initial authoring. Origin incident: Slack DM thread ${SLACK_CHANNEL_ID}/p1786698333.972209, message 1786698423.832949. Agent treated 'Gemini 3.7 flash' as likely typo and posted a 4-way clarification menu instead of curl-checking https://ai.google.dev/gemini-api/docs/models first. Trigger-based SOUL.md COMMIT added in same pass."
---

# vendor-webcheck-first — verify user-named artifacts at the source, not from memory

## The rule

When a user names a specific external artifact and you have ANY doubt about its current existence, currency, or identity, your **first** action is to fetch the vendor's authoritative source and grep for the named artifact. Only after a confirmed no-match do you post a clarification.

**Anti-pattern (the failure this skill prevents):** "Hmm, that sounds like a typo, let me search my session memory… nothing found… posting a 4-way menu asking which of i/ii/iii/iv the user actually meant." The cost of this anti-pattern is one full round-trip + a user-correction ("It's real, web search it"). The cost of the correct path is one curl call (~2-5 sec) and either a confirmation or a precise "no, X doesn't exist, did you mean Y?".

## Trigger phrases

Fire this skill when ANY of:

- User names a specific external artifact and the message implies it should exist right now: "Where is the <X> PR?", "Add <Y> to settings", "Make <Z> default".
- User asserts an external fact that your training-data cutoff might not cover: "X released today", "Did Y ship Z?", "Is W still maintained?".
- User names a vendor model / API / library / product that you have no record of: "Gemini 3.7 flash", "GPT-5.1", "Claude Code 2.5", "Cloud Run v2.9".
- You are about to classify any user-named thing as a typo, fictional, or out-of-date. **STOP. Webcheck first.**

## The 5-second recipe

For any vendor (Google, OpenAI, Anthropic, AWS, GitHub, npm, PyPI, etc.):

```bash
# 1. The authoritative source. If unsure of URL, start at vendor.com/docs or vendor.com/release-notes.
curl -fsSL -A "Mozilla/5.0" "<vendor-source-url>" | grep -iE "<artifact-name>|<key-term>" | head -10
```

If `web_extract` or `browser_navigate` is available, prefer them (they handle JS-rendered pages). For Slack DMs or any time the user pushed back on a "this is a typo" claim, **always** webcheck — even if you already apologized.

## Vendor source map (defaults)

| Vendor | Authoritative source for model/library releases |
|---|---|
| Google (Gemini, Vertex) | `https://ai.google.dev/gemini-api/docs/models` or `/models/<model-name>` |
| OpenAI (GPT, o-series) | `https://platform.openai.com/docs/models` |
| Anthropic (Claude) | `https://docs.anthropic.com/en/docs/about-claude/models` or `https://docs.claude.com/en/docs/claude-code/overview` |
| AWS (Bedrock, SageMaker) | `https://docs.aws.amazon.com/bedrock/latest/userguide/models-supported.html` |
| GitHub repos | `<repo>/releases`, `<repo>/tags`, or `gh release list -R <owner>/<repo>` |
| npm packages | `https://www.npmjs.com/package/<name>` or `curl https://registry.npmjs.org/<name>` |
| PyPI packages | `https://pypi.org/project/<name>/` or `curl https://pypi.org/pypi/<name>/json` |

If the vendor is not on this map, default to `<vendor>.com/<artifact-path>` or `<vendor>.com/docs/<topic>`. If still no match, fall back to `web_search` (non-Tavily backend per `research-integrity.md`).

## What to do with the result

- **Match found → proceed with the user's task.** Do not post a confirmation menu. Just dispatch.
- **No match, vendor returns 200 → say so precisely** with the closest match if grep surfaces a near-name (e.g., "I checked Google's Gemini docs — `gemini-3.7-flash` is not listed; closest is `gemini-3.6-flash`. Did you mean that, or is it in a private preview?"). **One question max.**
- **Vendor returns 404 → say so precisely** ("The model page returned 404 — it's not on Google's public docs. Are you on a private preview?"). **One question max.**
- **curl/web_extract fails entirely → fall back to web_search** (non-Tavily backend per `research-integrity.md`). Do not stall.

## Companion to existing rules

- **`## COMMIT: pre-execution-option-bailout-guard`** — covers social share-links (LinkedIn / X / public blog) and 2+ option user-authorized forks. This skill extends it to **vendor artifact existence checks**.
- **`## COMMIT: no-confirmation-gate`** — banned phrases like "Want me to…?", "Should I…?". This skill prevents the menu-posting form of that anti-pattern.
- **`## COMMIT: ms-on-new-task`** — still fires; `session_search` and `memory-search` are good for **prior-session context**, but they are NOT authoritative for current vendor state. The webcheck is the authoritative check.

## Anti-patterns

- "I'll search my session memory first" — memory is stale-by-design for vendor state. Webcheck is authoritative.
- "Let me think about whether that's a typo" — that IS the clarification freeze. Webcheck or admit you don't know.
- "Post a 4-way menu listing i/ii/iii/iv" — banned. Webcheck first, one question only after no-match.
- "Apologize, then webcheck" — order matters. Webcheck FIRST when you have doubt. Apology is for after you've already done the work and realized you were wrong.

## Worked example — the originating incident

User message (Slack DM `${SLACK_CHANNEL_ID}`, thread 1786698333.972209, ts 1786698333.972209): "Where is the Gemini 3.7 flash PR? Let's make it default model and ensure Pr is /ready".

**What the prior agent did (failure):**
1. `session_search` + skill memory → no "3.7" hit, only 3.5/3.6.
2. Treated no-match in session memory as authoritative for current Google docs.
3. Posted 4-way menu: (i) typo for 3.6, (ii) PR #8592 (draft, far from green), (iii) brand-new PR, (iv) different repo.
4. User pushed back: "It's real idiot web search 3.7 flash released today".

**What this skill does (correct):**
1. First call: `curl -fsSL -A "Mozilla/5.0" "https://ai.google.dev/gemini-api/docs/models" | grep -i "3.7"` (or `web_extract` to same URL).
2. Match found → confirm to user, dispatch immediately via `claudem -p "..."` on clean worktree.
3. Total round-trip: 1 user turn + 1 assistant turn. Zero clarification menus.

## Test file

`tests/test_vendor_webcheck_first_contract.py` (pytest, runs locally without network — uses monkeypatched curl).

## Deploy sync awareness

Per `hermes-deploy-pipeline`, `~/.smartclaw_prod/` is a symlink to `~/.smartclaw/` — staging = prod = live runtime. Writing the skill here is sufficient for the prod resolver to see it. The companion SOUL.md `## COMMIT: vendor-webcheck-first` is auto-loaded at session-init.
