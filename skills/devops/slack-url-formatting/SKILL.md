---
name: slack-url-formatting
version: 1.0
description: Never wrap URLs in markdown bold/italic in Slack messages — asterisks render literally.
---

# Slack URL Formatting

## Rule: Never wrap URLs in markdown bold/italic

Slack does NOT render `**URL**` or `*URL*` around links — the asterisks appear literally in the message.

### Banned patterns
- `**https://github.com/org/repo/pull/123**` → renders as `**https://...**`
- `*https://example.com*` → renders as `*https://example.com*`
- `_https://example.com_` → renders as `_https://example.com_`

### Correct patterns
- Plain URL: `https://github.com/org/repo/pull/123`
- Link text: `<https://github.com/org/repo/pull/123|PR #123>` (Slack mrkdwn)
- Slack mrkdwn bold on label text only: `*PR*: https://github.com/org/repo/pull/123`

### Why this happens
Slack uses a subset of mrkdwn, not full CommonMark. Bold/italic markers (`**`, `*`, `_`) are NOT parsed when they wrap a bare URL — they pass through as literal asterisks/underscores.

### Bug-refs
- 2026-05-12: Historical incident — PR [#6886](https://github.com/jleechanorg/smartclaw/pull/6886) URL posted as `**URL**` in Slack, asterisks visible to user (second occurrence); this skill added via PR [#566](https://github.com/jleechanorg/smartclaw/pull/566)
