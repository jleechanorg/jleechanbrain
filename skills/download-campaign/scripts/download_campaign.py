#!/usr/bin/env python3
"""download_campaign.py — single + batch + all-users WA campaign download.

Modes:
  --mode one   --campaign-id <id>                        # pull a specific campaign (one user)
  --mode batch [--min-entries N] [--days N]             # one user (jleechan by default)
  --mode all-users [--min-entries N] [--exclude-jleechan] # every real user (skip test fixtures)

Required env:
  WORLDAI_DEV_MODE=true
  GOOGLE_APPLICATION_CREDENTIALS=~/serviceAccountKey.json

Run from inside ~/worldarchitect.ai or with the .venv on PATH.

The script inlines the Firestore call (no subprocess) to avoid the
gRPC FD inheritance bug. NEVER spawn download_campaign.py as a child process
of a Firebase-initialized parent — see SKILL.md "Pitfalls #1".
"""
import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Defaults — override via env or args
WORLDARCHITECT_REPO = Path(os.environ.get("WORLDAI_REPO", "${HOME}/worldarchitect.ai"))
CREDENTIALS = Path(os.environ.get("GOOGLE_APPLICATION_CREDENTIALS", os.path.expanduser("~/serviceAccountKey.json")))
EMAIL = os.environ.get("WA_EMAIL", "jleechan@gmail.com")
WIKI_SOURCES = Path(os.environ.get("WA_WIKI_SOURCES", "${HOME}/llm_wiki/wiki/sources"))
RAW_ROOT = Path(os.environ.get("WA_RAW_ROOT", "${HOME}/llm_wiki/raw/campaigns"))
MANIFEST = Path("/tmp/campaign_ingest_manifest.jsonl")

# Path order: mvp_site FIRST (for clock_skew_credentials), then root
sys.path.insert(0, str(WORLDARCHITECT_REPO / "mvp_site"))
sys.path.insert(0, str(WORLDARCHITECT_REPO))

from clock_skew_credentials import apply_clock_skew_patch  # noqa: E402
apply_clock_skew_patch()

import firebase_admin  # noqa: E402
from firebase_admin import auth, credentials, firestore  # noqa: E402
import firestore_service  # noqa: E402
import document_generator  # noqa: E402

# ---- Multi-user test-email filter (mirrors wa-prod-data-query) ----
# Tokens: test, anon, dev-runner, example.com, jleechantest
# Per wa-prod-data-query SKILL.md (verified 2026-06-23): campaigns/conversations
# collections contain zero real-user docs; real-user campaigns live at
# users/{uid}/campaigns/{camp_id}/story/{entry_id}. Test-user emails here are
# the only safe filter for batch --all-users mode.
_TEST_EMAIL_TOKENS = ("test", "anon", "dev-runner", "example.com", "jleechantest")


def is_test_email(email):
    """True if email looks like a test fixture (case-insensitive substring match)."""
    if not email:
        return True
    e = email.lower()
    return any(token in e for token in _TEST_EMAIL_TOKENS)


def list_real_users(exclude_jleechan=False):
    """Paginate auth.list_users(), return [{uid, email}] for non-test users.

    exclude_jleechan: pass True to skip jleechan@gmail.com.
    """
    init_firebase()
    jleechan_uid = None
    if exclude_jleechan:
        try:
            jleechan_uid = auth.get_user_by_email("jleechan@gmail.com").uid
        except Exception:
            pass

    users = []
    page = auth.list_users()
    while page:
        for u in page.users:
            email = (u.email or "").lower()
            if is_test_email(email):
                continue
            if exclude_jleechan and jleechan_uid and u.uid == jleechan_uid:
                continue
            users.append({"uid": u.uid, "email": email})
        page = page.get_next_page()
    return users


def slugify(text: str) -> str:
    """Title to kebab-case, max 80 chars."""
    text = text.lower()
    text = re.sub(r"[^a-z0-9]+", "-", text)
    return text.strip("-")[:80]


def init_firebase():
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = str(CREDENTIALS)
    os.environ["WORLDAI_DEV_MODE"] = "true"
    if not firebase_admin._apps:
        cred = credentials.Certificate(str(CREDENTIALS))
        firebase_admin.initialize_app(cred)
    return firestore.client()


def download_one(uid: str, campaign_id: str, title: str, entry_count: int = 0,
                 campaigns_dir: Path = None, user_email: str = "") -> dict:
    """Download a single campaign — returns manifest entry or raises."""
    print(f"  Downloading [{entry_count or '?'}] {title} ({campaign_id[:8]})"
          + (f" [{user_email}]" if user_email else ""), flush=True)

    campaign_data, story_context = firestore_service.get_campaign_by_id(uid, campaign_id)
    if campaign_data is None or story_context is None:
        raise RuntimeError(f"no data for {campaign_id}")
    if not isinstance(story_context, list):
        raise RuntimeError(f"story is not a list: {type(story_context)}")

    if not title or title == campaign_id:
        title = campaign_data.get("name") or campaign_data.get("title") or "Untitled"
    if not entry_count and isinstance(story_context, list):
        entry_count = len(story_context)

    try:
        story_text = document_generator.get_story_text_from_context_enhanced(
            story_context, include_scenes=True
        )
    except (AttributeError, TypeError):
        story_text = document_generator.get_story_text_from_context(story_context)

    base = campaigns_dir or RAW_ROOT
    safe_title = "".join(c if c.isalnum() or c in " -_" else "_" for c in title)[:50]
    camp_dir = base / campaign_id
    camp_dir.mkdir(parents=True, exist_ok=True)
    prefix = f"{safe_title}_{campaign_id[:8]}"
    raw_path = camp_dir / f"{prefix}.txt"
    raw_path.write_text(story_text, errors="replace")

    # Human-readable markdown archive
    md_path = camp_dir / f"{prefix}.md"
    try:
        document_generator.generate_md(
            story_text, str(md_path), campaign_title=title, campaign_id=campaign_id
        )
    except Exception as e:
        print(f"    [WARN] md export: {e}")

    # Game state
    try:
        gs = firestore_service.get_campaign_game_state(uid, campaign_id)
        gs_data = gs.to_dict() if gs is not None else {}
        gs_path = camp_dir / f"{prefix}_game_state.json"
        gs_path.write_text(json.dumps(gs_data, indent=2, default=str), errors="replace")
    except Exception as e:
        print(f"    [WARN] game state: {e}")

    # Wiki source page (id8-suffixed to avoid slug collision)
    base_slug = slugify(title)
    wiki_path = WIKI_SOURCES / f"{base_slug}-{campaign_id[:8]}.md"
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    user_lines = ""
    if user_email:
        user_lines = (
            f"user_email: \"{user_email}\"\n"
            f"user_uid: \"{uid}\"\n"
        )
    frontmatter = (
        "---\n"
        f'title: "{title}"\n'
        "type: source\n"
        f"tags: [campaign, worldarchitect, {base_slug}]\n"
        f"date: {today}\n"
        f"source_file: {raw_path}\n"
        f"campaign_id: {campaign_id}\n"
        f"entry_count: {entry_count}\n"
        f"{user_lines}"
        "ingest_batch: download-campaign-skill\n"
        "---\n\n"
    )
    body = story_text[:100000]
    wiki_path.write_text(frontmatter + body, errors="replace")
    print(f"  ✅ Wrote: {wiki_path.name}  ({len(story_text)} chars)", flush=True)

    return {
        "title": title,
        "campaign_id": campaign_id,
        "entry_count": entry_count,
        "user_email": user_email,
        "user_uid": uid,
        "wiki_path": str(wiki_path),
        "raw_path": str(raw_path),
        "story_chars": len(story_text),
    }


def _paginated_count(collection_ref, page_size: int = 2000) -> int:
    """Count docs in a Firestore collection by streaming pages of page_size."""
    total = 0
    offset = 0
    while True:
        page = list(collection_ref.limit(page_size).offset(offset).stream())
        total += len(page)
        if len(page) < page_size:
            break
        offset += page_size
    return total


def _count_collection(collection_ref, page_size: int = 2000) -> int:
    """Count docs in a Firestore collection without caps or streaming timeouts.

    Prefers native Firestore server-side aggregation count query (fast,
    unary request, no streaming timeout or _UnaryStreamMultiCallable._retry
    attribute bugs). Falls back to paginated streaming if count() is not
    supported (e.g. in test mocks).
    """
    try:
        if hasattr(collection_ref, "count"):
            res = collection_ref.count().get()
            if res and len(res) > 0 and len(res[0]) > 0 and hasattr(res[0][0], "value"):
                return int(res[0][0].value)
    except Exception:
        pass
    return _paginated_count(collection_ref, page_size=page_size)


def query_candidates(uid: str, min_entries: int = 0, days: int = 0) -> list[dict]:
    """Scan all campaigns, return those matching the filters."""
    db = init_firebase()
    campaigns_ref = db.collection("users").document(uid).collection("campaigns")
    cutoff = datetime.now(timezone.utc) - timedelta(days=days) if days else None

    results = []
    for camp in campaigns_ref.stream():
        data = camp.to_dict() or {}
        title = data.get("name", data.get("title", "Untitled"))
        story_ref = camp.reference.collection("story")
        # entry_count: TRUE count via server aggregation count() query with
        # fallback to pagination. Avoids the legacy .limit(2000) cap AND avoids
        # streaming connection drops / _retry attribute crashes across large
        # collections (regression test: tests/test_download_campaign.py).
        entry_count = _count_collection(story_ref, page_size=2000)
        if entry_count < min_entries:
            continue

        # Date filter — use campaign doc last_updated, then fall back to
        # max(timestamp) of story entries
        last_updated = data.get("last_updated") or data.get("updated_at") or data.get("lastActivity")
        if cutoff and not last_updated:
            try:
                last_doc = next(
                    story_ref.order_by("timestamp", direction=firestore.Query.DESCENDING)
                    .limit(1).stream(),
                    None,
                )
                if last_doc:
                    last_updated = last_doc.get("timestamp") or last_doc.get("created_at")
            except Exception:
                pass

        if cutoff and last_updated and hasattr(last_updated, "timestamp"):
            if last_updated.tzinfo is None:
                last_updated = last_updated.replace(tzinfo=timezone.utc)
            if last_updated < cutoff:
                continue

        results.append({
            "campaign_id": camp.id,
            "title": title,
            "entry_count": entry_count,
            "last_updated": str(last_updated) if last_updated else "",
        })
    results.sort(key=lambda c: -c["entry_count"])
    return results


def _stored_entry_count(wp_path: Path) -> int | None:
    """Read stored scene/entry count from an existing wiki source page.

    Parses `entry_count:` (or `scene_total:` / `scene_count:`) from YAML
    frontmatter, handling quotes, comments, indentation, BOM, and CRLF line endings.
    If frontmatter has no parseable count but the markdown contains scenes,
    falls back to counting `## Scene ` headings.
    Returns the integer count, or None if the file is missing or has no scenes.
    """
    if not wp_path.exists():
        return None
    try:
        text = wp_path.read_text(errors="replace")
    except OSError:
        return None

    # Strip BOM and leading whitespace/blank lines
    text_stripped = text.lstrip("\ufeff \t\r\n")

    # Extract frontmatter block between opening --- and closing ---
    fm = ""
    if text_stripped.startswith("---"):
        fm_match = re.search(r"^---\s*\r?\n(.*?)\r?\n---\s*(?:\r?\n|$)", text_stripped, re.DOTALL)
        if fm_match:
            fm = fm_match.group(1)

    if fm:
        # Check entry_count / scene_total / scene_count (with optional quotes, indentation, comments)
        m = re.search(
            r"^\s*(?:entry_count|scene_total|scene_count):\s*[\"']?(\d+)[\"']?\s*(?:#.*)?$",
            fm,
            re.MULTILINE,
        )
        if m:
            return int(m.group(1))

    # Body fallback: count scene headings (e.g. ## Scene 1, ## Scene 2)
    scenes = re.findall(r"^##\s*Scene\s+\d+", text, re.MULTILINE | re.IGNORECASE)
    if scenes:
        return len(scenes)

    return None


def _process_candidates(uid: str, user_email: str, candidates: list[dict],
                        args, campaigns_dir: Path) -> tuple[list[dict], int, int]:
    """Download candidates for a single user (shared logic for batch + all-users)."""
    results, errors, skipped = [], 0, 0
    for i, c in enumerate(candidates):
        print(f"\n[{i+1}/{len(candidates)}] [{user_email}]", flush=True)

        if args.skip_existing:
            slug = slugify(c["title"])
            wp = WIKI_SOURCES / f"{slug}-{c['campaign_id'][:8]}.md"
            stored = _stored_entry_count(wp)
            live_count = int(c.get("entry_count") or 0)
            if stored is not None and stored >= live_count:
                print(f"  ⏭️  Exists: {wp.name} (entry_count={stored} >= live {live_count})")
                skipped += 1
                continue
            if wp.exists() and stored is None:
                print(f"  🔄 Stale: {wp.name} (frontmatter has no entry_count; live={live_count})")
            elif wp.exists():
                print(f"  🔄 Stale: {wp.name} (stored={stored} < live {live_count})")
            else:
                print(f"  ⬇️  New: {wp.name} (live={live_count})")

        try:
            r = download_one(uid, c["campaign_id"], c["title"], c["entry_count"],
                            campaigns_dir, user_email=user_email)
            results.append(r)
        except Exception as e:
            print(f"  [ERROR] {c['campaign_id'][:8]}: {e}", flush=True)
            errors += 1
    return results, errors, skipped


def main():
    p = argparse.ArgumentParser(description="WorldArchitect.AI campaign downloader")
    p.add_argument("--mode", choices=["one", "batch", "all-users"], required=True)
    p.add_argument("--campaign-id", help="for --mode one")
    p.add_argument("--email", default=None, help="user email override")
    p.add_argument("--uid", default=None, help="user UID override")
    p.add_argument("--title", default=None, help="campaign title override")
    p.add_argument("--min-entries", type=int, default=0)
    p.add_argument("--days", type=int, default=0, help="filter to last N days of activity")
    p.add_argument("--skip-existing", action="store_true")
    p.add_argument("--campaigns-dir", default=str(RAW_ROOT))
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--tag", default="download-campaign-skill")
    p.add_argument("--exclude-jleechan", action="store_true",
                   help="(all-users) skip jleechan@gmail.com")
    args = p.parse_args()

    campaigns_dir = Path(args.campaigns_dir)
    campaigns_dir.mkdir(parents=True, exist_ok=True)

    init_firebase()

    if args.mode == "one":
        user_email = args.email or EMAIL
        uid = args.uid
        if not uid:
            user = auth.get_user_by_email(user_email)
            uid = user.uid
        print(f"UID: {uid}  email: {user_email}")
        if not args.campaign_id:
            print("--campaign-id required for --mode one", file=sys.stderr)
            sys.exit(1)
        result = download_one(uid, args.campaign_id, args.title or "",
                              entry_count=args.min_entries,
                              campaigns_dir=campaigns_dir, user_email=user_email)
        with open(MANIFEST, "a") as f:
            f.write(json.dumps(result) + "\n")
        return

    # batch — single user (jleechan by default; --email override)
    if args.mode == "batch":
        user = auth.get_user_by_email(EMAIL)
        uid = user.uid
        user_email = user.email or EMAIL
        print(f"UID: {uid}  email: {user_email}")

        print(f"Scanning campaigns (min-entries={args.min_entries}, days={args.days})...")
        t0 = time.time()
        candidates = query_candidates(uid, args.min_entries, args.days)
        print(f"Found {len(candidates)} candidates in {time.time()-t0:.1f}s")

        if args.dry_run:
            for c in candidates:
                print(f"  {c['entry_count']:5d} | {c['title']} ({c['campaign_id'][:8]})")
            return

        results, errors, skipped = _process_candidates(uid, user_email, candidates,
                                                      args, campaigns_dir)
        with open(MANIFEST, "a") as f:
            for r in results:
                f.write(json.dumps(r) + "\n")

        print(f"\n=== Done ({user_email}) ===")
        print(f"Downloaded: {len(results)}")
        print(f"Skipped:    {skipped}")
        print(f"Errors:     {errors}")
        print(f"Manifest:   {MANIFEST}")
        return

    # all-users — paginate auth.list_users(), skip test fixtures, iterate
    print(f"Discovering real users (exclude_jleechan={args.exclude_jleechan})...")
    t0 = time.time()
    users = list_real_users(exclude_jleechan=args.exclude_jleechan)
    print(f"Found {len(users)} real users in {time.time()-t0:.1f}s")

    if args.dry_run:
        for u in users:
            print(f"  {u['email']}  uid={u['uid']}")
        return

    grand_results, grand_errors, grand_skipped = [], 0, 0
    for u_idx, user in enumerate(users):
        uid, email = user["uid"], user["email"]
        print(f"\n========== [{u_idx+1}/{len(users)}] user: {email} (uid={uid}) ==========")
        try:
            candidates = query_candidates(uid, args.min_entries, args.days)
            print(f"  Found {len(candidates)} candidates (>= {args.min_entries} scenes)")
        except Exception as e:
            print(f"  [ERROR] scan failed for {email}: {e}", flush=True)
            grand_errors += 1
            continue

        if args.dry_run:
            for c in candidates:
                print(f"    {c['entry_count']:5d} | {c['title']} ({c['campaign_id'][:8]})")
            continue

        if not candidates:
            continue

        r, e, s = _process_candidates(uid, email, candidates, args, campaigns_dir)
        grand_results.extend(r)
        grand_errors += e
        grand_skipped += s

    with open(MANIFEST, "a") as f:
        for r in grand_results:
            f.write(json.dumps(r) + "\n")

    print(f"\n=== Done (all-users, {len(users)} real users scanned) ===")
    print(f"Downloaded: {len(grand_results)}")
    print(f"Skipped:    {grand_skipped}")
    print(f"Errors:     {grand_errors}")
    print(f"Manifest:   {MANIFEST}")


if __name__ == "__main__":
    main()
