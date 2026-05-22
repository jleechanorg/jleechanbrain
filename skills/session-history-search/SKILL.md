---
name: session-history-search
description: Search conversation history across Claude Code, Codex, and Hermes session stores in parallel.
version: 1.0.0
---

# Session History Search

Search past agent conversation history across three session stores in parallel.

## Session Stores

| Store | Path | Format | Count | Search Method |
|-------|------|--------|-------|----------------|
| Claude Code | `~/.claude/projects/*/*.jsonl` | JSONL per project | ~thousands | Python grep (keyword match on message content) |
| Codex | `~/.codex/state_5.sqlite` + 3 JSONL dirs (see below) | SQLite + JSONL | ~12K threads | SQLite title/preview query (fast), then JSONL deep-read |
| Hermes | `~/.smartclaw_prod/sessions/*.jsonl` + `state.db` | JSONL + SQLite with FTS5 | ~565 JSONL + 869 DB | SQLite FTS5 (fast) + JSONL fallback |

## Execution

### Phase 1: Parallel Search (run all three simultaneously)

**Hermes SQLite (fast path — always try first):**

```python
import sqlite3, os

db_path = os.path.expanduser("~/.smartclaw_prod/state.db")
if os.path.exists(db_path):
    conn = sqlite3.connect(db_path)
    # Search sessions by title
    title_hits = conn.execute(
        "SELECT id, title, model, source, started_at, message_count FROM sessions WHERE title LIKE ?",
        (f"%{query}%",)
    ).fetchall()
    # Search message content via FTS5
    content_hits = conn.execute(
        "SELECT s.id, s.title, s.model, s.source FROM messages m JOIN sessions s ON m.session_id = s.id WHERE messages_fts MATCH ? LIMIT 20",
        (query,)
    ).fetchall()
    conn.close()
```

**Claude Code sessions:**

```python
import glob, json, os

pattern = os.path.expanduser("~/.claude/projects/*/*.jsonl")
for f in glob.glob(pattern):
    # Stream-read: check each line for keyword
    # Extract role + first 200 chars of content if match
    with open(f) as fh:
        for line in fh:
            if query_lower in line.lower():
                # Parse and collect
                break  # one match per file is enough for listing
```

**Codex sessions (SQLite fast path + JSONL deep-read):**

Codex stores session metadata in `~/.codex/state_5.sqlite` (table: `threads`) with 12K+ rows.
Use SQLite first for title/cwd/branch filtering, then read the rollout JSONL for content search.

```python
import sqlite3, os

db_path = os.path.expanduser("~/.codex/state_5.sqlite")
if os.path.exists(db_path):
    conn = sqlite3.connect(db_path)
    # Search by title, cwd, or git_branch
    hits = conn.execute(
        """SELECT id, title, cwd, git_branch, model, created_at, rollout_path
           FROM threads
           WHERE title LIKE ? OR cwd LIKE ? OR git_branch LIKE ?
           ORDER BY created_at DESC LIMIT 20""",
        (f"%{query}%", f"%{query}%", f"%{query}%")
    ).fetchall()
    conn.close()
```

For content search inside messages, read the rollout JSONL from `rollout_path` (stored in the threads table):

```python
# Codex JSONL format: each line has {timestamp, type, payload}
# type="response_item" → payload has {type:"message", role:"user"|"assistant", content:[...]}
# type="session_meta" → metadata
import json

def search_codex_jsonl(path, query, limit=5):
    results = []
    query_lower = query.lower()
    with open(path) as fh:
        for line in fh:
            if len(results) >= limit:
                break
            if query_lower in line.lower():
                try:
                    obj = json.loads(line)
                    if obj.get("type") == "response_item":
                        payload = obj.get("payload", {})
                        role = payload.get("role", "?")
                        content = payload.get("content", [])
                        text = " ".join(
                            c.get("text", "") for c in content if isinstance(c, dict)
                        )[:200]
                        results.append({"role": role, "text": text})
                except (json.JSONDecodeError, KeyError):
                    pass
    return results
```

Codex JSONL locations (search in this order):
1. `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` — active sessions (~12K files)
2. `~/.codex/sessions_archive/YYYY/MM/DD/rollout-*.jsonl` — older archived sessions
3. `~/.codex/archived_sessions/rollout-*.jsonl` — flat archive (few files)

Always prefer SQLite for metadata search; only grep JSONL for message content search.

### Phase 2: Merge & Rank

1. Deduplicate by session ID (Hermes DB and JSONL may overlap).
2. Sort by recency (most recent session first).
3. For each hit, show: source, session ID/title, model, date, match snippet.

### Phase 3: Deep Read (optional, on selection)

If user picks a specific session:
- For Hermes: `SELECT role, content FROM messages WHERE session_id = ? ORDER BY timestamp`
- For Claude/Codex: stream-read the JSONL and extract matching messages with context.

## Output Format

```
=== Session History: "level_up" ===

🔴 Hermes (state.db — FTS)        3 sessions, 8 messages
🟢 Claude Code (~/.claude)         7 sessions
🔵 Codex (~/.codex)                12 sessions

--- Hermes ---
• 20260511_163525 | fix: level-up signal contracts | GLM-5.1 | 2026-05-11
• 20260428_092211 | rewards_pending until level-up | gpt-5.4 | 2026-04-28
  ↳ "level_up_available flag must stay true until..."

--- Claude Code ---
• -Users-jleechan-projects-worldarchitect/abc123.jsonl | 2026-04-11
  ↳ "The planning blocks in story_context when _maybe_trigger_level_up_modal..."

--- Codex ---
• 2026/04/07/rollout-2026-04-07T14-22-*.jsonl | 2026-04-07
  ↳ "level_up_now choice only appears AFTER the LLM processes..."
```

## Pitfalls

- **JSONL files can be huge** (50MB+). Always stream-read line-by-line; never `json.load()` the whole file.
- **Codex has 3 session dirs**: `~/.codex/sessions/YYYY/MM/DD/` (active), `~/.codex/sessions_archive/YYYY/MM/DD/` (older), and `~/.codex/archived_sessions/` (flat). Always prefer `state_5.sqlite` for metadata search; only JSONL-grep for message content.
- **Codex SQLite fast path**: `~/.codex/state_5.sqlite` table `threads` has title, cwd, git_branch, rollout_path, model — use LIKE query for keyword match. 12K+ rows, instant lookup.
- **Hermes dual format**: `state.db` has structured metadata + FTS5; `sessions/*.jsonl` has raw transcripts. Prefer DB for search, JSONL only for deep-read.
- **Archive dirs**: Codex has `sessions_archive/` and `archived_sessions/`; Claude Code does not archive (old sessions stay in `projects/`).
- **Permission errors**: some JSONL files may be unreadable; catch and skip gracefully.
- **Session ID overlap**: Hermes DB session IDs match JSONL filenames (prefix before `.jsonl`). Dedup by normalizing the ID.

## Performance Notes

- Hermes SQLite FTS5: sub-second for any query.
- Claude/Codex JSONL grep: ~2-10 seconds depending on keyword frequency. Limit to first match per file for listing speed. Codex SQLite metadata search: sub-second.
- Total session corpus: ~25GB across all three stores. Never load into memory.
