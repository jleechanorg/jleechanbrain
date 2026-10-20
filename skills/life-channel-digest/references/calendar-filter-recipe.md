# Calendar filter recipe for #life digest

After `gog calendar events --from "$NOW" --to "$END" --json`, the
result contains entries that MUST be filtered out before sorting
for the digest.

## What `gog calendar events` returns (and why each is bad for a digest)

| Entry type | Why it appears | What to do |
|------------|----------------|------------|
| Past recurring-event masters | `gog` doesn't collapse recurrings — `Trip to Dublin` (start 2026-06-19) shows up because the series is "active" | Drop if `start < now` |
| All-day multi-day events | `{"date": "2026-07-25"}` ... `{"date": "2026-08-16"}` — a 22-day window | Drop if `end` is past `now + 24h` AND we only want 24h digest |
| Events that already started | `--from`/`--to` is a window filter, not a "starts after" filter | Drop if `start < now` |
| Declined events | User RSVP'd "no" | Optional — usually keep; digest is about time, not RSVP |

## The mandatory filter

```python
import json
from datetime import datetime, timezone

with open('/tmp/cal.json') as f:
    data = json.load(f)

events = data.get('events', [])
now = datetime.now(timezone.utc)
end = datetime.fromisoformat("2026-08-14T16:01:03+00:00")  # 24h from now

upcoming = []
for e in events:
    s = e.get('start', {})
    if 'dateTime' in s:
        # '2026-08-13T10:00:00-07:00' — has explicit offset
        start = datetime.fromisoformat(s['dateTime'].replace('Z', '+00:00'))
    elif 'date' in s:
        # All-day event '2026-07-25' — coerce to midnight UTC
        start = datetime.fromisoformat(s['date'] + 'T00:00:00+00:00')
    else:
        continue
    # Strict: must be in the future AND within the window
    if start > now and start <= end:
        upcoming.append((start, e))

upcoming.sort()
```

## Key points

1. **`start > now`** (strictly greater than) drops anything that
   has already started. Don't use `>=` — events that started 5
   minutes ago are noise in a digest.

2. **`start <= end`** drops events past the 24h horizon. For a
   Thu 09:00 PT digest, anything starting after Fri 09:00 PT is
   out of scope.

3. **Timezone handling is automatic** when you parse with
   `datetime.fromisoformat()`. The `Z` → `+00:00` substitution is
   required because Python's `fromisoformat` in 3.10 doesn't accept
   bare `Z` (3.11+ does).

4. **All-day events** get `start.date` not `start.dateTime`. The
   above handler coerces to midnight UTC, which makes them sort
   predictably but also means an all-day "tomorrow" event will
   appear in the digest if the window crosses midnight — usually
   fine.

## Common filter mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| `start >= now` (not strict) | Already-started events in the digest | Use `start > now` |
| Forgot `Z` → `+00:00` substitution | `ValueError` on parse | Substitute before `fromisoformat` |
| Treating `start.date` like `start.dateTime` | `KeyError: 'dateTime'` | Check for `'date'` first |
| Trusting the `--from/--to` window | 2018 recurring event in the result | Always post-filter |
| Not sorting | Events in arbitrary order | `upcoming.sort()` before display |

## Verified examples

- 2026-08-11 — found 10 events in window; 6 strictly upcoming; digest used 4.
- 2026-08-13 — found 10 events in window; 7 strictly upcoming; digest used 6.

In both cases the post-filter caught at least one "active recurring"
entry that the `--from/--to` window alone would have leaked through
(e.g. `Trip to Dublin` end-date 2026-08-23 with start 2026-06-19).