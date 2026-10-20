# All-users WA campaign download — quick recipe for cross-user validation

Use this when you need to download all real-user campaigns (above some entry threshold) for cross-user pattern analysis — typical after a single-user feedback dump, to confirm whether a complaint is system-wide or user-specific.

**Source session**: 2026-08-17 kevin feedback review (37 campaigns downloaded to `~/Downloads/all_campaigns/` in ~3 min).

## The working pattern (inline, NOT subprocess)

Per `download-campaign/SKILL.md` Pitfall #1, never spawn `download_campaign.py` — gRPC FD inheritance. Use this inline script:

```python
# /tmp/download_all_inline.py — copy and adapt
import sys, os, json
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, "${HOME}/worldarchitect.ai/mvp_site")
sys.path.insert(0, "${HOME}/worldarchitect.ai")

os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = os.path.expanduser("~/serviceAccountKey.json")
os.environ["WORLDAI_DEV_MODE"] = "true"

from clock_skew_credentials import apply_clock_skew_patch
apply_clock_skew_patch()

import firebase_admin
from firebase_admin import auth, credentials, firestore
if not firebase_admin._apps:
    firebase_admin.initialize_app(credentials.Certificate(os.path.expanduser("~/serviceAccountKey.json")))

import firestore_service
import document_generator
from google.cloud import firestore as fs

OUT_DIR = Path("${HOME}/Downloads/all_campaigns").expanduser()
OUT_DIR.mkdir(parents=True, exist_ok=True)
MANIFEST_PATH = OUT_DIR / "MANIFEST.jsonl"

TEST_PATTERNS = ("test", "anon", "dev-runner", "example.com", "jleechantest")
JLEECHAN_EMAILS = {"jleechan@gmail.com", "jleechan@worldarchitect.ai"}  # BOTH uids — see pitfall #9
MIN_ENTRIES = 21  # >20

def is_test(email: str) -> bool:
    return any(p in (email or "").lower() for p in TEST_PATTERNS)

def safe_filename(name: str) -> str:
    return "".join(c if c.isalnum() or c in "._-" else "_" for c in name)[:80]

# Build user list (one paginated call)
real_users = []
for u in auth.list_users().iterate_all():
    if not u.email or is_test(u.email):
        continue
    if u.email in JLEECHAN_EMAILS:  # EMAIL filter, not UID (see pitfall #9)
        continue
    real_users.append((u.uid, u.email))
print(f"Real users: {len(real_users)}", flush=True)

# Parallel scan with 8 workers (Firestore quotas allow this)
_local_db = {}
def get_db():
    tid = __import__("threading").get_ident()
    if tid not in _local_db:
        _local_db[tid] = firestore.client()
    return _local_db[tid]

def scan_user(uid_email):
    uid, email = uid_email
    db = get_db()
    found = []
    try:
        for camp_doc in db.collection("users").document(uid).collection("campaigns").list_documents():
            try:
                n = int(camp_doc.collection("story").count().get()[0][0].value)
            except Exception:
                n = 0
            if n > 20:
                meta = camp_doc.get().to_dict() or {}
                # Title fallback chain (pitfall #10)
                title = (meta.get("name") or meta.get("title")
                         or (str(meta.get("setting", ""))[:60] if meta.get("setting") else "")
                         or f"campaign-{camp_doc.id[:8]}")
                found.append((uid, email, camp_doc.id, title, n))
    except Exception:
        pass
    return found

candidates = []
with ThreadPoolExecutor(max_workers=8) as ex:
    futures = {ex.submit(scan_user, ue): ue for ue in real_users}
    for fut in as_completed(futures):
        try:
            candidates.extend(fut.result())
        except Exception:
            pass
        if len(candidates) % 5 == 0:
            print(f"  found {len(candidates)} so far", flush=True)

print(f"Found {len(candidates)} campaigns >{MIN_ENTRIES-1} entries", flush=True)
candidates.sort(key=lambda c: -c[4])  # largest first

# Download serially (single Firestore client — no race conditions)
db = firestore.client()
manifest_lines = []
for i, (uid, email, cid, title, n) in enumerate(candidates):
    safe_title = safe_filename(title)
    short_id = cid[:8]  # display only — keep full 22-char cid for Firestore lookups (pitfall #11)
    out_subdir = OUT_DIR / f"{safe_title}_{short_id}"
    out_subdir.mkdir(exist_ok=True)
    txt_path = out_subdir / f"{safe_title}_{short_id}.txt"

    if txt_path.exists() and txt_path.stat().st_size > 500:
        continue  # idempotent re-run

    try:
        campaign_data, story_context = firestore_service.get_campaign_by_id(uid, cid)
        # Cross-check helper output vs direct count (pitfall #8)
        direct_count = int(db.collection("users").document(uid)
                          .collection("campaigns").document(cid)
                          .collection("story").count().get()[0][0].value)
        if direct_count > len(story_context):
            docs = list(db.collection("users").document(uid)
                        .collection("campaigns").document(cid)
                        .collection("story").stream())
            story_context = [d.to_dict() for d in docs]
        story_text = document_generator.get_story_text_from_context_enhanced(
            story_context, include_scenes=True
        )
        txt_path.write_text(story_text)
        manifest_lines.append(json.dumps({"campaign_id": cid, "uid": uid, "email": email, "title": title, "entries": n}))
        print(f"  [{i+1}/{len(candidates)}] {email} / {title[:40]} ({n}e)", flush=True)
    except Exception as e:
        print(f"  ERR {email}: {e}", flush=True)

with open(MANIFEST_PATH, "w") as f:
    f.write("\n".join(manifest_lines) + "\n")
print(f"Done. Manifest: {MANIFEST_PATH}")
```

## Wall time

- 152 users, 37 candidates, ~11 MB total: **~30s scan + ~3 min download = ~3.5 min total**
- Linear scaling: ~5 sec/user scan, ~5 sec/download for medium campaigns

## Reading phase — dispatch parallel subagents

After downloads land, dispatch 3 parallel subagents (max concurrent is `delegation.max_concurrent_children=3`) to score each subset. Use the `tasks[]` array form if >3 subsets. See `parallel-investigate-and-dispatch/SKILL.md` § Anti-patterns (4th sync pitfall).

Each subagent gets a subset of paths and a fixed scoring rubric. Example output structure:

```json
[{
  "campaign_id": "...",
  "path": "...",
  "onboarding_score": 0,
  "friction_score": 1,
  "goal_score": 2,
  "cc_turns": 0,
  "cc_uses_standarddnd": false,
  "action_resolution_warning_count": 0,
  "loop_severity": "mild",
  "readability": 1,
  "wall_of_text_evidence": "~600-800 chars/response",
  "notable_patterns": ["..."],
  "first_3_user_actions": ["...", "...", "..."],
  "first_post_cc_text": "..."
}]
```

## Aggregation

After all subagents return, aggregate scores into a distribution per dimension. The shape that goes into the issue bodies:

```
onboarding: 24/26 = subtle hint (score 1), 0/26 = explicit quiz (score 2)
            → P1 system-wide gap (no instance of the proposed feature)
friction: 14/26 = light, 7/26 = clear, 5/26 = none
            → P2 meaningful subset (24% have no friction)
loops: 2 severe, 8 moderate, 8 mild, 8 none
       → P2 (38% have meaningful loops)
```

Each filed issue body should cite the relevant distribution in the "Motivation" or "Severity" section so backlog readers can see the scope.

## Common pitfalls

1. **Use `WORLDAI_DEV_MODE=true` + the in-process path ordering** — see `download-campaign/SKILL.md` § Phase 1-3.
2. **Email filter for jleechan, not UID** — see pitfall #9 in `download-campaign/SKILL.md`.
3. **Title fallback chain** — see pitfall #10.
4. **Full 22-char campaign_id for Firestore** — see pitfall #11.
5. **Parallel scan, serial download** — see pitfall #12. The scan phase is the bottleneck; downloads benefit from serialization (no Firestore connection contention).
6. **3-subagent cap** — see `parallel-investigate-and-dispatch/SKILL.md` Anti-patterns.