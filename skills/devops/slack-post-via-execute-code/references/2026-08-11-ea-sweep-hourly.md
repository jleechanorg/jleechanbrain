# Reference — EA Sweep Hourly Cron (2026-08-11)

Recipe actually executed by `clawchief:ea-sweep-hourly` (job_id `2f942031797e`) at 16:00 PDT on 2026-08-11. Posted to `#ai-general` (C0AJQ5M0A0Y), ts=`1786489273.132549`, ok=true.

## Channel-routing override

Skill default = operator DM `${SLACK_CHANNEL_ID}`. Cron directive explicitly overrides to `#ai-general` (C0AJQ5M0A0Y). This matches `SOUL.md → ## COMMIT: slack-channel-routing-policy` rule (4): "User explicitly asked for a different channel — respect one-time override."

The previous sweep at 12:01 PDT (ts=`1786474954.020389`) also routed to `#ai-general`, confirming this is the established override for THIS specific cron, not a one-off.

## Token path used

`SLACK_BOT_TOKEN` is already in `os.environ` inside the `execute_code` sandbox (verified by direct read; no need to bash-login-shell `$SLACK_BOT_TOKEN` dance). Posting via `curl -H "Authorization: Bearer ${SLACK_BOT_TOKEN}"` succeeds with `ok=true`.

This is simpler than the `slack-post-via-execute-code` SKILL.md primary recipe (which uses bash-login-shell for the token). When `SLACK_BOT_TOKEN` is already populated, skip that step entirely.

## gog CLI gotchas (verified today)

1. **Gmail search is positional, not `--query`:**
   ```bash
   # CORRECT
   gog gmail search 'is:starred OR is:important' -a jleechan@gmail.com --max=10 --json --results-only

   # WRONG (returns "unknown flag --query")
   gog gmail list --query 'is:starred OR is:important' ...
   ```
   The top-level command is `gog gmail search` (alias `find/query/list`). The query string is the first positional arg. `--query` flag does not exist.

2. **Account selection:** `-a <email>` selects which Gmail account to query. Primary for this user is `jleechan@gmail.com`. Secondary `m@gon.to` workspace account will refuse with `No auth for calendar m@gon.to. OAuth (browser flow): gog auth add m@gon.to --services calendar` when auth is missing — skip silently rather than inventing calendar data.

3. **`--results-only` flag is essential for JSON-mode parsing** — without it, the output wraps the array in envelope fields (`nextPageToken` etc.) that break naive `json.loads()`.

4. **Calendar events with `start.dateTime` are timed events, `start.date` are all-day.** When filtering "today", match both `dateTime.startswith(today)` AND `date == today`.

## EA-sweep dedup check

Before posting, query the target channel's most recent message:

```bash
curl -fsS -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  "https://slack.com/api/conversations.history?channel=C0AJQ5M0A0Y&limit=1"
```

Read the `ts` of the last message. If it was posted by the same cron within 30 minutes (gate per SKILL.md "never post the briefing twice for the same sweep run"), suppress. Today's gap was 4h (12:01 PDT → 16:00 PDT), so fresh post was justified.

## execute_code string-parsing pitfall (NEW PITFALL observed today)

The `execute_code` sandbox's Python parser chokes on triple-quoted strings that begin with a colon-prefixed emoji literal + newline:

```python
text = """:spiral_calendar_pad: *Now / Today*
- line 1
"""
# raises: SyntaxError: unterminated triple-quoted string literal (detected at line 49)
```

The error position is misleading — it points at the end of the script, not the actual problematic string. Workaround: build multiline strings via parenthesized string concatenation OR write the script to a file (e.g. `/tmp/ea_post.py`) and run via `terminal('python3 /tmp/ea_post.py')`. The file-write path is robust.

The `slack-post-via-execute-code` SKILL.md already documents the `/tmp/<name>.json` + `--data-binary @<file>` pattern. This is a generalization: **whenever `execute_code` raises SyntaxError on multiline string literals, write the script body to `/tmp/<name>.py` and invoke via `terminal('python3 /tmp/<name>.py')` instead of debugging the literal.** Verified 2026-08-11.

## Calendar filtering gotcha

The `gog calendar events --all` output includes overlapping recurring events (e.g. "Maid - Lily" appears at both 09:30 with `originalStartTime` AND in the recurring-event list). Filter client-side by:

```python
events = [e for e in data if e.get('start',{}).get('dateTime','').startswith(today_str)
          or e.get('start',{}).get('date') == today_str]
```

The recurring-event master + individual instance will both match — that's expected. Display the original instance once.

## Briefing sections (per skill)

Final posted briefing included: Now/Today, Tomorrow, Email (IMPORTANT/Starred/unread), Slack action items, Deploys/system, dedup footer.

Notable today:
- 4 IMPORTANT/unread emails: Structure Law Group invoice (just landed 16:00), MLB Ballpark, dodgers.com ticket, American Express
- 0 Slack action items in monitored channels
- Deploy-CI check via `gh run list` returned empty for `jleechanorg/worldarchitect.ai` in the 12h window — operator may want to verify whether that's expected idle or a query glitch; noted but not raised as a blocker
- 8 calendar events on Tue Aug 11, plus trip-to-Dublin all-day anchor (8/23)
