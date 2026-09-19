# RESOLVER — wa-daily-dice-audit-fix

## Trigger phrases

- "Daily Dice Audit failed"
- "wa-daily-dice-audit FAIL"
- "[GCP Cron] Daily Dice Audit - FAIL"
- "dice audit integrity failure"
- "compound notation cron"
- "fp_calc notation"
- "rhaenrya house dragon integrity"
- "Overlord shy lich unparseable"

## Match

Use the skill `wa-daily-dice-audit-fix` when:
- The GCP cron `wa-daily-dice-audit` has exit code 1
- Email/Slack alerts about `[GCP Cron] Daily Dice Audit - FAIL` arrive
- GCS evidence at `gs://wa-test-evidence/daily-dice-audit/YYYY-MM-DD/` shows `[Integrity Failure]` lines
- Daily-dice-audit cron was working before and starts failing in a campaign whose notation field contains `2d10+10+4d6`, `fp_calc`, or similar non-standard patterns

## Don't match

- Other GCP cron failures (level-up, daily-test, etc.) — those have their own skills
- LLM dice-notation contract changes that the prompt should fix (separate skill family for `dice-notation-contract` work)
- `scripts/daily_dice_audit.py` script errors (different code path; not the audit predicate)
