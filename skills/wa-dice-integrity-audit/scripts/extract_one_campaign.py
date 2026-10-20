#!/usr/bin/env python3
"""One-campaign dice extractor with the venv + project fixes that the canonical
extract_user_dice.py needs on the worldarchitect.ai project venv (Python 3.12).

Differences from ~/.smartclaw/skills/wa-dice-integrity-audit/scripts/extract_user_dice.py:

  1. `firestore.client()` doesn't exist in this venv — use
     `from google.cloud.firestore import Client; db = Client(project="worldarchitecture-ai")`.
  2. `firebase_admin.initialize_app(cred, {"projectId": "worldarchitecture-ai"})` —
     bashrc `GOOGLE_CLOUD_PROJECT=ai-universe-2025` overrides the SA key's project;
     need to force worldarchitecture-ai explicitly or Firestore 403s the user reads.
  3. Scope to one campaign (cid passed in) — full `users.stream()` is denied.
  4. `normalize_roll` takes `campaign_name` so chi_squared_audit's
     `test_actor_by_campaign` doesn't KeyError on the 'campaign' field.

Usage:
    cd ~/projects/worldarchitect.ai
    WORLDAI_DEV_MODE=true .venv/bin/python \\
        ~/.smartclaw/skills/wa-dice-integrity-audit/scripts/extract_one_campaign.py \\
        --email jleechan@gmail.com \\
        --cid 7HHDMPe0wNLBDTfymzfT \\
        --output /tmp/<uid>_dice.json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter

WA_REPO = "${HOME}/worldarchitect.ai"


def init_wa() -> None:
    sys.path.insert(0, os.path.join(WA_REPO, "mvp_site"))
    sys.path.insert(0, WA_REPO)
    os.environ.setdefault("WORLDAI_DEV_MODE", "true")

    import firebase_admin
    from firebase_admin import credentials, auth

    if not firebase_admin._apps:
        try:
            from clock_skew_credentials import apply_clock_skew_patch
            apply_clock_skew_patch()
        except ImportError:
            pass
        cred_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS") or os.path.expanduser(
            "~/serviceAccountKey.json"
        )
        firebase_admin.initialize_app(
            credentials.Certificate(cred_path),
            {"projectId": "worldarchitecture-ai"},
        )

    return auth  # caller uses auth.get_user_by_email


def get_client():
    """Pin to worldarchitecture-ai even if GOOGLE_CLOUD_PROJECT overrides."""
    from google.cloud.firestore import Client
    return Client(project="worldarchitecture-ai")


def normalize_roll(r, campaign_name, cid):
    """Same shape as skill extractor but adds campaign/cid fields and takes them as args."""
    roll = r["roll"]
    notation = roll.get("notation") or roll.get("roll") or ""
    m = re.match(r"(\d*)d(\d+)", notation)
    if not m:
        return None
    n_dice = int(m.group(1) or "1")
    die_size = int(m.group(2))

    raw = (
        roll.get("rolls") or roll.get("faces") or roll.get("raw_faces")
        or roll.get("result") or roll.get("roll")
    )
    if isinstance(raw, list):
        faces = raw
    elif isinstance(raw, str):
        try:
            faces = [int(x) for x in raw.split(",")]
        except ValueError:
            try:
                faces = [int(raw)]
            except ValueError:
                return None
    elif isinstance(raw, (int, float)):
        faces = [int(raw)]
    else:
        return None

    total = roll.get("total") or roll.get("result")
    if total is not None and not isinstance(total, (int, float)):
        try:
            total = int(total)
        except (TypeError, ValueError):
            total = None

    return {
        "campaign": campaign_name,
        "cid": cid,
        "doc_id": r["doc_id"],
        "actor": r.get("actor"),
        "source": r.get("source"),
        "strategy": r.get("strategy"),
        "notation": notation,
        "n_dice": n_dice,
        "die_size": die_size,
        "faces": faces,
        "total": int(total) if total is not None else None,
        "dc": roll.get("dc"),
        "success": roll.get("success"),
        "purpose": roll.get("purpose") or roll.get("type") or roll.get("label"),
    }


def extract(uid, cid, email_for_print=""):
    from google.cloud.firestore import Client
    db = get_client()
    camp_ref = db.collection("users").document(uid).collection("campaigns").document(cid)
    camp_snap = camp_ref.get()
    if not camp_snap.exists:
        raise SystemExit(f"campaign {cid!r} not found under uid {uid}")
    camp_d = camp_snap.to_dict() or {}
    campaign_name = camp_d.get("title") or cid

    story_docs = list(camp_ref.collection("story").stream())

    raw_rolls = []
    audit_events = []
    text_dice = []
    strategy_counter = Counter()
    actor_counter = Counter()

    for doc in story_docs:
        sd = doc.to_dict() or {}
        actor = sd.get("actor", "?")
        actor_counter[actor] += 1
        debug = sd.get("debug_info") or {}
        strategy_counter[debug.get("dice_strategy", "?")] += 1

        ar = sd.get("action_resolution")
        if isinstance(ar, dict):
            mech = ar.get("mechanics", {})
            if isinstance(mech, dict):
                for r in mech.get("rolls", []) or []:
                    if isinstance(r, dict):
                        raw_rolls.append({
                            "doc_id": doc.id,
                            "actor": actor,
                            "strategy": debug.get("dice_strategy"),
                            "source": "action_resolution.mechanics.rolls",
                            "roll": r,
                        })
                for ae in mech.get("audit_events", []) or []:
                    if isinstance(ae, dict):
                        audit_events.append({"doc_id": doc.id, "audit": ae})

        for r in sd.get("dice_rolls", []) or []:
            if isinstance(r, dict):
                raw_rolls.append({
                    "doc_id": doc.id,
                    "actor": actor,
                    "strategy": debug.get("dice_strategy"),
                    "source": "dice_rolls (legacy)",
                    "roll": r,
                })

        text = sd.get("text", "") or ""
        for m in re.finditer(r"\b(\d*)d(\d+)([+\-]\d+)?\b", text):
            text_dice.append({"doc_id": doc.id, "actor": actor, "notation": m.group(0)})

    parsed = [n for r in raw_rolls if (n := normalize_roll(r, campaign_name, cid)) is not None]

    return {
        "uid": uid,
        "cid": cid,
        "campaign_meta": {
            "title": campaign_name,
            "created_at": str(camp_d.get("created_at")),
            "last_played": str(camp_d.get("last_played")),
            "story_count": len(story_docs),
        },
        "campaigns": [{"cid": cid, "title": campaign_name, "story_count": len(story_docs)}],
        "actor_counts": dict(actor_counter),
        "strategy_counts": dict(strategy_counter),
        "rolls_normalized": parsed,
        "audit_events": audit_events[:50],
        "text_dice_count": len(text_dice),
    }, parsed


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--email", help="User email (Firebase Auth lookup)")
    ap.add_argument("--uid", help="Or pass UID directly")
    ap.add_argument("--cid", required=True, help="Campaign ID to scope to")
    ap.add_argument("--output", required=True, help="Output JSON path")
    args = ap.parse_args()

    if not args.email and not args.uid:
        ap.error("Must supply --email or --uid")

    auth = init_wa()
    uid = args.uid or auth.get_user_by_email(args.email).uid
    print(f"UID={uid} CID={args.cid}", file=sys.stderr)

    data, parsed = extract(uid, args.cid, email_for_print=args.email)
    with open(args.output, "w") as f:
        json.dump(data, f, indent=2, default=str)

    print(f"  story entries: {data['campaign_meta']['story_count']}", file=sys.stderr)
    print(f"  raw rolls    : {len(parsed) + sum(1 for _ in data['audit_events'])}", file=sys.stderr)
    print(f"  parsed rolls : {len(parsed)}", file=sys.stderr)
    print(f"  audit_events : {len(data['audit_events'])}", file=sys.stderr)
    print(f"  actor split  : {data['actor_counts']}", file=sys.stderr)
    print(f"  strategy     : {data['strategy_counts']}", file=sys.stderr)
    from collections import Counter as _C
    ds = _C(p["die_size"] for p in parsed)
    print(f"  per die_size : {dict(sorted(ds.items()))}", file=sys.stderr)
    print(f"wrote {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()