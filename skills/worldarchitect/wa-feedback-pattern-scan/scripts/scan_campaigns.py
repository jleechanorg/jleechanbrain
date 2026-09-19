#!/usr/bin/env python3
"""
Scan real WA user campaigns and score 3 feedback patterns:
  1. ONBOARDING/QUIZ - first 5 entries ask preference questions?
  2. INITIAL FRICTION - first 3 user actions get any obstacle?
  3. WIN CONDITION - first 15 entries establish a goal?

Writes per-user JSON + SUMMARY.json to /tmp/feedback_review/.
Uses real Firestore via in-process Python (no subprocess - gRPC FD bug).

Verified 2026-08-17 across 6 real-user campaigns.
"""
import json
import os
import re
import sys
import time
from pathlib import Path

# Path order per skill spec (mvp_site BEFORE root, so clock_skew_credentials wins)
sys.path.insert(0, "${HOME}/worldarchitect.ai/mvp_site")
sys.path.insert(0, "${HOME}/worldarchitect.ai")

# Auth per skill spec - WORLDAI_DEV_MODE=true is MANDATORY with creds
os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = os.path.expanduser("~/serviceAccountKey.json")
os.environ["WORLDAI_DEV_MODE"] = "true"

import firebase_admin  # noqa: E402
from firebase_admin import auth, credentials, firestore  # noqa: E402

if not firebase_admin._apps:
    cred = credentials.Certificate(os.environ["GOOGLE_APPLICATION_CREDENTIALS"])
    firebase_admin.initialize_app(cred)

from clock_skew_credentials import apply_clock_skew_patch  # noqa: E402
apply_clock_skew_patch()

db = firestore.client()

# Exclusion - test patterns AND known jleechan aliases (not just UID)
# See references/jleechan-email-aliases.md for why the alias list matters.
TEST_PATTERNS = ["test", "anon", "dev-runner", "example.com", "jleechantest"]
EXCLUDED_UID = "vnLp2G3m21PJL6kxcuAqmWSOtm73"  # jleechan's canonical UID
EXCLUDED_EMAILS = {"jleechan@worldarchitect.ai", "leechanfamilyjlc@gmail.com"}


def is_excluded_email(email):
    if not email:
        return True
    e = email.lower()
    if e in EXCLUDED_EMAILS:
        return True
    for p in TEST_PATTERNS:
        if p in e:
            return True
    return False


def safe_email(email):
    return re.sub(r"[^A-Za-z0-9._-]", "_", email)


def truncate(s, n=400):
    s = (s or "").strip().replace("\n", " ")
    return s[:n] + ("\u2026" if len(s) > n else "")


def get_entries_for_campaign(uid, camp_id, max_entries=30):
    """Read story subcollection, ordered by timestamp asc, limited to max_entries."""
    entries = []
    try:
        coll = (
            db.collection("users")
            .document(uid)
            .collection("campaigns")
            .document(camp_id)
            .collection("story")  # NOT story_entries - that's the pitfall
        )
        try:
            docs = coll.order_by("timestamp", direction=firestore.Query.ASCENDING).limit(max_entries).stream()
        except Exception:
            # Some campaigns have null timestamps on early entries; fall back
            docs = coll.limit(max_entries).stream()
        for d in docs:
            data = d.to_dict() or {}
            data["_doc_id"] = d.id
            entries.append(data)
    except Exception as e:
        print(f"  ERROR reading story entries for {uid}/{camp_id}: {e}", file=sys.stderr)
    return entries


def get_story_count(uid, camp_id):
    """Use aggregation count - one read, no doc materialization."""
    try:
        coll = (
            db.collection("users")
            .document(uid)
            .collection("campaigns")
            .document(camp_id)
            .collection("story")
        )
        agg = coll.count().get()
        return int(agg[0][0].value)
    except Exception:
        return 0


def score_onboarding(first_entries):
    """Score 0-2. Look at first 5 entries (any actor) for preference questions.
    See SKILL.md table for score semantics.
    """
    keywords_strong = [
        "what kind of", "what type of", "what do you like", "what are you interested",
        "interests", "non-interests", "experience level", "familiar with",
        "have you played", "genre", "preferences", "tell me about yourself",
        "your goals", "what do you want", "what would you", "pick a",
        "choose your", "preferred", "do you prefer", "what setting",
        "what theme", "what mood", "play style", "difficulty",
    ]
    snippets = []
    for e in first_entries[:5]:
        txt = e.get("narrative") or e.get("text") or ""
        snippets.append(txt)
        pb = e.get("planning_block") or {}
        snippets.append(pb.get("thinking", "") or pb.get("context", "") or "")
    blob = " ".join(snippets).lower()
    snippets_short = [truncate(s, 160) for s in snippets[:3] if s]

    for k in keywords_strong:
        if k in blob:
            if any(q in blob for q in ["?", "pick", "choose", "select"]) and len(blob) < 4000:
                return 2, snippets_short
            return 1, snippets_short
    return 0, snippets_short


def score_friction(entries):
    """Score 0-2. First 3 USER actions + next non-user response after each.
    STRONG (in-narrative obstacle) -> 2
    SOFT (system menu / CC flow) -> 1
    See references/friction-scoring-pitfall.md for why these lists are separated.
    """
    user_actions = [e for e in entries if e.get("actor") == "user"][:3]
    if not user_actions:
        return 0, "(no user actions found)"

    # Strong in-narrative friction
    friction_signals_strong = [
        "you can't", "you cannot", "blocked", "obstacle",
        "resist", "danger", "attack", "fail", "refuse", "denied",
        "stopped", "barrier", "guard", "intercept", "prevent",
        "roll", "difficulty", "challenge", "die", "dies", "wound",
        "hurt", "defeated", "rejected", "attack hits", "you take",
        "you fail", "fails the", "unsuccessful",
    ]
    # Soft: CC flow menus / system branches (still friction in the broad sense)
    friction_signals_soft = [
        "character creation", "edit character", "what aspect would you like",
        "are you sure", "do you want to", "are you certain",
        "would you like to", "banned list", "menu", "select",
    ]

    user_idx_to_action = {}
    for i, e in enumerate(entries):
        if e.get("actor") == "user":
            user_idx_to_action[i] = e.get("text", "")
            if len(user_idx_to_action) >= 3:
                break

    responses_after_user = []
    for ui in sorted(user_idx_to_action.keys())[:3]:
        for j in range(ui + 1, min(ui + 6, len(entries))):
            if entries[j].get("actor") in ("gemini", "claude", "system"):
                responses_after_user.append((user_idx_to_action[ui], entries[j]))
                break

    score = 0
    snippets = []
    for action, response in responses_after_user:
        blob = (
            (response.get("narrative") or "")
            + " "
            + (response.get("text") or "")
            + " "
            + ((response.get("planning_block") or {}).get("thinking") or "")
        ).lower()
        if any(s in blob for s in friction_signals_strong):
            score = max(score, 2)
        elif any(s in blob for s in friction_signals_soft):
            score = max(score, 1)
        snippets.append(f"USER: {truncate(action, 100)}\nGM: {truncate(response.get('narrative') or response.get('text', ''), 250)}")

    if score == 0:
        return 0, "\n---\n".join(snippets) or "(no friction detected, full compliance)"
    return score, "\n---\n".join(snippets)


def score_goal(first_15):
    """Score 0-2. First 15 entries for explicit mission/goal/deadline/antagonist.
    Both narrative field AND planning_block.context are searched.
    """
    strong_goal_signals = [
        "your mission", "your quest", "your task", "objective", "goal",
        "you must", "you need to", "save the", "defeat the", "stop the",
        "find the", "recover the", "rescue the", "before the deadline",
        "in X days", "within X days", "or else", "stakes", "the fate of",
        "the kingdom", "the world", "antagonist", "villain", "evil",
        "the dark lord", "the enemy", "threatening",
    ]
    blob_parts = []
    for e in first_15:
        blob_parts.append(e.get("narrative") or e.get("text") or "")
        pb = e.get("planning_block") or {}
        blob_parts.append(pb.get("thinking", "") or pb.get("context", "") or "")
    blob = " ".join(blob_parts).lower()

    matches = []
    for k in strong_goal_signals:
        if k in blob:
            matches.append(k)

    snippets = []
    for e in first_15[:8]:
        txt = e.get("narrative") or e.get("text") or ""
        if any(m in txt.lower() for m in matches):
            snippets.append(truncate(txt, 200))

    if len(matches) >= 2:
        return 2, "; ".join(matches[:6]) + " | " + " || ".join(snippets[:3])
    if len(matches) >= 1:
        return 1, "; ".join(matches[:6]) + " | " + " || ".join(snippets[:3])
    return 0, "(no goal signals in first 15 entries)"


def scan_campaign(uid, email, camp_id, title):
    print(f"\n=== Scanning: {email} | {title} ({camp_id}) ===", file=sys.stderr)
    total_entries = get_story_count(uid, camp_id)
    print(f"  total story entries: {total_entries}", file=sys.stderr)
    if total_entries < 20:
        print(f"  SKIP (too few entries)", file=sys.stderr)
        return None
    entries = get_entries_for_campaign(uid, camp_id, max_entries=30)

    onb_score, onb_ev = score_onboarding(entries[:5])
    fric_score, fric_ev = score_friction(entries)
    goal_score, goal_ev = score_goal(entries[:15])

    result = {
        "campaign_id": camp_id,
        "title": title,
        "uid": uid,
        "email": email,
        "entries": total_entries,
        "onboarding_score": onb_score,
        "onboarding_evidence": onb_ev,
        "friction_score": fric_score,
        "friction_evidence": fric_ev,
        "goal_score": goal_score,
        "goal_evidence": goal_ev,
    }
    print(f"  ONB={onb_score} FRIC={fric_score} GOAL={goal_score}", file=sys.stderr)
    return result


def list_real_users_with_big_campaigns(target_n=5):
    """Paginate auth.list_users(), find ones with campaigns/{camp}/story where count >= 20."""
    candidates = []
    page = auth.list_users()
    seen = 0
    while page:
        for u in page.users:
            seen += 1
            if seen % 50 == 0:
                print(f"  ... scanned {seen} users, found {len(candidates)} candidates so far", file=sys.stderr)
            uid = u.uid
            if uid == EXCLUDED_UID:
                continue
            email = (u.email or "").lower()
            if is_excluded_email(email):
                continue
            if not email:
                continue
            try:
                camps_ref = db.collection("users").document(uid).collection("campaigns")
                camps = list(camps_ref.limit(20).stream())
            except Exception as e:
                print(f"  err listing campaigns for {email}: {e}", file=sys.stderr)
                continue
            for c in camps:
                title = (c.to_dict() or {}).get("title") or ""
                count = get_story_count(uid, c.id)
                if count >= 20:
                    candidates.append((uid, email, c.id, title, count))
            if len(candidates) >= 30:
                break
        if len(candidates) >= 30:
            break
        page = auth.list_users(page.next_page_token) if page.has_next_page else None

    candidates.sort(key=lambda x: x[4], reverse=True)
    return candidates


def main():
    out_dir = Path("/tmp/feedback_review")
    out_dir.mkdir(parents=True, exist_ok=True)

    print("Finding real WA users with >20 entry campaigns...", file=sys.stderr)
    candidates = list_real_users_with_big_campaigns()
    print(f"\nFound {len(candidates)} candidate campaigns:", file=sys.stderr)
    for c in candidates[:20]:
        print(f"  {c[1]:30s} {c[3][:50]:50s} {c[4]} entries", file=sys.stderr)

    if not candidates:
        print("NO candidates found!", file=sys.stderr)
        return 1

    seen_emails = set()
    results = []
    for uid, email, camp_id, title, story_count in candidates:
        if email in seen_emails:
            continue
        seen_emails.add(email)
        r = scan_campaign(uid, email, camp_id, title)
        if r:
            results.append(r)
            safe = safe_email(email)
            with open(out_dir / f"{safe}.json", "w") as f:
                json.dump(r, f, indent=2)
        if len(results) >= 6:
            break

    summary = {
        "onboarding": {"0": 0, "1": 0, "2": 0},
        "friction": {"0": 0, "1": 0, "2": 0},
        "goal": {"0": 0, "1": 0, "2": 0},
        "campaigns_scanned": len(results),
        "campaigns": [
            {
                "email": r["email"],
                "title": r["title"],
                "entries": r["entries"],
                "onboarding_score": r["onboarding_score"],
                "friction_score": r["friction_score"],
                "goal_score": r["goal_score"],
            }
            for r in results
        ],
    }
    for r in results:
        summary["onboarding"][str(r["onboarding_score"])] += 1
        summary["friction"][str(r["friction_score"])] += 1
        summary["goal"][str(r["goal_score"])] += 1

    with open(out_dir / "SUMMARY.json", "w") as f:
        json.dump(summary, f, indent=2)

    print(f"\n=== SUMMARY ===\n{json.dumps(summary, indent=2)}", file=sys.stderr)
    print(f"\nWrote {len(results)} per-user files + SUMMARY.json to {out_dir}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())