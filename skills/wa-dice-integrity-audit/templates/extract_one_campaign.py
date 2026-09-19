#!/usr/bin/env python3
"""Single-campaign dice extractor with provenance tagging.

Use this when the user gives you a campaign URL (cid) and wants
chi-squared analysis on JUST that campaign, not all of their
campaigns. Tags every roll with `debug_info.rng_verified` so Step 6
can split by provenance.

Usage:
    cd ~/worldarchitect.ai
    .venv/bin/python \\
        ~/.smartclaw/skills/wa-dice-integrity-audit/templates/extract_one_campaign.py \\
        --uid <firebase-uid> --cid <campaign-id> \\
        --output /tmp/<uid>_dice.json

Or with email resolution:
    .venv/bin/python ... --email user@example.com --cid <cid> ...

This is a TEMPLATE — copy and customize for your campaign. The
canonical extractor at scripts/extract_user_dice.py is for the
per-user × all-campaigns view; this template is for the
single-campaign scope where you want provenance tagging and the
audit crashes without a `campaign` field on every roll.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter

# Adjust paths for the venv that ships with worldarchitect.ai.
sys.path.insert(0, "${HOME}/worldarchitect.ai/mvp_site")
sys.path.insert(0, "${HOME}/worldarchitect.ai")
os.environ.setdefault("WORLDAI_DEV_MODE", "true")


def ensure_firebase(project_id: str = "worldarchitecture-ai"):
    """Initialize firebase-admin + Firestore with project override.

    The `worldarchitect.ai/.venv` only exposes `Client` (not the
    `firestore.client()` helper), and `google.auth.default()` will
    fall through to `ai-universe-2025` from bashrc unless you
    pin the project here. Both tweaks are required.
    """
    import firebase_admin
    from firebase_admin import credentials

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
            {"projectId": project_id},
        )

    from google.cloud.firestore import Client

    return Client(project=project_id)


def resolve_uid(db, email: str) -> str:
    """Email -> UID via Firebase Auth. Do NOT scan the users
    collection (production rules forbid it)."""
    from firebase_admin import auth

    return auth.get_user_by_email(email).uid


def extract_one_campaign(db, uid: str, cid: str) -> dict:
    """Pull all story entries for one campaign and emit a JSON dict
    ready for `chi_squared_audit.py --input <file>` AND for Step 6
    provenance split.

    Output JSON shape:
      {
        uid, cid, campaigns: [{cid, title, story_count}],
        campaign_meta: {title, created_at, last_played},
        actor_counts: Counter,
        strategy_counts: Counter,
        rng_verified_counts: Counter,    # NEW: provenance distribution
        rolls_normalized: [roll dicts with `campaign` + `cid` keys],
        audit_events: [...],
        text_dice_count: int,
      }
    """
    camp_ref = db.collection("users").document(uid).collection("campaigns").document(cid)
    camp_snap = camp_ref.get()
    camp_d = camp_snap.to_dict() or {}
    title = camp_d.get("title") or cid

    raw_rolls = []
    audit_events = []
    text_dice = []
    actor_counter = Counter()
    strategy_counter = Counter()
    rng_verified_counter = Counter()

    for doc in camp_ref.collection("story").stream():
        sd = doc.to_dict() or {}
        actor = sd.get("actor", "?")
        actor_counter[actor] += 1

        debug = sd.get("debug_info") or {}
        strategy_counter[debug.get("dice_strategy", "?")] += 1
        rng_verified_counter[str(debug.get("rng_verified", "unset"))] += 1

        # Structured rolls path
        ar = sd.get("action_resolution")
        if isinstance(ar, dict):
            mech = ar.get("mechanics", {})
            if isinstance(mech, dict):
                for r in mech.get("rolls", []) or []:
                    if isinstance(r, dict):
                        raw_rolls.append(
                            {
                                "doc_id": doc.id,
                                "actor": actor,
                                "strategy": debug.get("dice_strategy"),
                                "rng_verified": debug.get("rng_verified"),
                                "source": "action_resolution.mechanics.rolls",
                                "roll": r,
                            }
                        )
                for ae in mech.get("audit_events", []) or []:
                    if isinstance(ae, dict):
                        audit_events.append({"doc_id": doc.id, "audit": ae})

        # Legacy rolls path
        for r in sd.get("dice_rolls", []) or []:
            if isinstance(r, dict):
                raw_rolls.append(
                    {
                        "doc_id": doc.id,
                        "actor": actor,
                        "strategy": debug.get("dice_strategy"),
                        "rng_verified": debug.get("rng_verified"),
                        "source": "dice_rolls (legacy)",
                        "roll": r,
                    }
                )

        # Notation mentions in prose (NOT for stats — context only)
        text = sd.get("text", "") or ""
        for m in re.finditer(r"\b(\d*)d(\d+)([+\-]\d+)?\b", text):
            text_dice.append({"doc_id": doc.id, "actor": actor, "notation": m.group(0)})

    parsed = [n for r in raw_rolls if (n := normalize_roll(r, title, cid)) is not None]

    return {
        "uid": uid,
        "cid": cid,
        "campaigns": [{"cid": cid, "title": title, "story_count": actor_counter.total()}],
        "campaign_meta": {
            "title": title,
            "created_at": str(camp_d.get("created_at")),
            "last_played": str(camp_d.get("last_played")),
        },
        "actor_counts": dict(actor_counter),
        "strategy_counts": dict(strategy_counter),
        "rng_verified_counts": dict(rng_verified_counter),
        "rolls_normalized": parsed,
        "audit_events": audit_events[:50],
        "text_dice_count": len(text_dice),
    }


def normalize_roll(r: dict, campaign_name: str, cid: str) -> dict | None:
    """Normalize one roll dict. Returns None if notation is unparseable.

    Always emits `campaign` (required by chi_squared_audit.py's
    test_actor_by_campaign test) and `rng_verified` (used by
    Step 6's provenance split).
    """
    roll = r["roll"]
    notation = roll.get("notation") or roll.get("roll") or ""
    m = re.match(r"(\d*)d(\d+)", notation)
    if not m:
        return None
    n_dice = int(m.group(1) or "1")
    die_size = int(m.group(2))

    raw = (
        roll.get("rolls")
        or roll.get("faces")
        or roll.get("raw_faces")
        or roll.get("result")
        or roll.get("roll")
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
        "rng_verified": r.get("rng_verified"),  # critical for Step 6 split
        "notation": notation,
        "n_dice": n_dice,
        "die_size": die_size,
        "faces": faces,
        "total": int(total) if total is not None else None,
        "dc": roll.get("dc"),
        "success": roll.get("success"),
        "purpose": roll.get("purpose") or roll.get("type") or roll.get("label"),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--email", help="User email (resolves to UID via Firebase Auth)")
    ap.add_argument("--uid", help="Or pass UID directly")
    ap.add_argument("--cid", required=True, help="Campaign ID")
    ap.add_argument("--project", default="worldarchitecture-ai")
    ap.add_argument("--output", default=None, help="Output JSON path")
    args = ap.parse_args()

    if not args.email and not args.uid:
        ap.error("Must supply --email or --uid")

    db = ensure_firebase(args.project)
    uid = resolve_uid(db, args.email) if args.email else args.uid

    data = extract_one_campaign(db, uid, args.cid)
    print(f"UID={uid}  CID={args.cid}", file=sys.stderr)
    print(f"  campaigns    : {len(data['campaigns'])}", file=sys.stderr)
    print(f"  parsed rolls : {len(data['rolls_normalized'])}", file=sys.stderr)
    print(f"  actor split  : {data['actor_counts']}", file=sys.stderr)
    print(f"  rng_verified : {data['rng_verified_counts']}", file=sys.stderr)

    out_path = args.output or f"/tmp/{uid}_{args.cid}_dice.json"
    with open(out_path, "w") as f:
        json.dump(data, f, indent=2, default=str)
    print(f"Wrote {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())