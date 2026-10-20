#!/usr/bin/env python3
"""
Extract every dice roll from a user's campaigns in WorldArchitect.AI prod Firestore.

Pulls BOTH structured (`action_resolution.mechanics.rolls`) AND legacy
(`dice_rolls`) fields across all of the user's campaigns. Returns a list
of normalized dicts the chi-squared audit can consume directly.

Verified 2026-08-13 against UID oPISN50TvEcH21uVYKzlZX1kKNv2 (Hanji Stevens):
    111 structured rolls across 3 campaigns, all on actor=gemini docs.
    Zero user-actor docs with any dice data — known schema gap.

Usage:
    cd ~/worldarchitect.ai
    WORLDAI_DEV_MODE=true .venv/bin/python \\
        ~/.smartclaw/skills/wa-dice-integrity-audit/scripts/extract_user_dice.py \\
        --email hanjistevens@gmail.com \\
        --output /tmp/hanji_dice.json

Stdout: progress notes
Stderr: (none — keep stdout clean for piping)

--output defaults to /tmp/<uid>_dice.json
--campaigns-only / --story-only / --raw  flags control what gets emitted
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter

# ---- Firebase init (copy of the canonical pattern from wa-prod-data-query) ----
WA_REPO = "${HOME}/worldarchitect.ai"


def ensure_wa_imports() -> None:
    """Idempotent: add WA paths, set dev-mode + creds env, init firebase-admin once."""
    sys.path.insert(0, os.path.join(WA_REPO, "mvp_site"))
    sys.path.insert(0, WA_REPO)
    os.environ.setdefault("WORLDAI_DEV_MODE", "true")
    if "GOOGLE_APPLICATION_CREDENTIALS" not in os.environ:
        cred_path = os.path.expanduser("~/serviceAccountKey.json")
        if os.path.exists(cred_path):
            os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = cred_path

    import firebase_admin  # type: ignore
    from firebase_admin import credentials  # type: ignore

    if not firebase_admin._apps:
        try:
            from clock_skew_credentials import apply_clock_skew_patch  # type: ignore

            apply_clock_skew_patch()
        except ImportError:
            pass  # clock-skew patch is optional
        cred = credentials.Certificate(os.environ["GOOGLE_APPLICATION_CREDENTIALS"])
        firebase_admin.initialize_app(cred)


def resolve_uid_by_email(email: str) -> str:
    """Resolve email -> UID via Firebase Auth (NOT via users collection)."""
    ensure_wa_imports()
    from firebase_admin import auth  # type: ignore

    return auth.get_user_by_email(email).uid


def extract_user_dice(uid: str) -> dict:
    """Pull all dice rolls for one user across all their campaigns.

    Returns a dict with keys: campaigns (list of metadata), rolls (list of
    normalized roll dicts), text_dice (notation found in prose), strategy_counts,
    actor_counts.
    """
    ensure_wa_imports()
    from google.cloud import firestore  # type: ignore

    db = firestore.client()

    # Pull all campaigns with metadata
    campaigns = []
    raw_rolls = []
    text_dice = []
    audit_events = []
    strategy_counter = Counter()
    actor_counter = Counter()

    camp_iter = db.collection("users").document(uid).collection("campaigns").stream()
    for c in camp_iter:
        d = c.to_dict()
        cid = c.id
        title = d.get("title", "?")
        created = str(d.get("created_at", "?"))
        last_played = str(d.get("last_played", "?"))
        story_count = len(list(c.reference.collection("story").stream()))
        campaigns.append(
            {
                "cid": cid,
                "title": title,
                "created": created,
                "last_played": last_played,
                "story_count": story_count,
            }
        )

        # Walk every story doc
        for doc in c.reference.collection("story").stream():
            sd = doc.to_dict()
            actor = sd.get("actor", "?")
            actor_counter[actor] += 1
            debug = sd.get("debug_info") or {}
            strategy_counter[debug.get("dice_strategy", "?")] += 1

            # Path 1: structured action_resolution.mechanics.rolls
            ar = sd.get("action_resolution")
            if isinstance(ar, dict):
                mech = ar.get("mechanics", {})
                if isinstance(mech, dict):
                    for r in mech.get("rolls", []) or []:
                        if isinstance(r, dict):
                            raw_rolls.append(
                                {
                                    "campaign": title,
                                    "cid": cid,
                                    "doc_id": doc.id,
                                    "actor": actor,
                                    "strategy": debug.get("dice_strategy"),
                                    "source": "action_resolution.mechanics.rolls",
                                    "roll": r,
                                }
                            )
                    for ae in mech.get("audit_events", []) or []:
                        if isinstance(ae, dict):
                            audit_events.append(
                                {
                                    "campaign": title,
                                    "cid": cid,
                                    "doc_id": doc.id,
                                    "audit": ae,
                                }
                            )

            # Path 2: legacy dice_rolls[]
            for r in sd.get("dice_rolls", []) or []:
                if isinstance(r, dict):
                    raw_rolls.append(
                        {
                            "campaign": title,
                            "cid": cid,
                            "doc_id": doc.id,
                            "actor": actor,
                            "strategy": debug.get("dice_strategy"),
                            "source": "dice_rolls (legacy)",
                            "roll": r,
                        }
                    )

            # Path 3: dice notation found in prose (for context, NOT for stats)
            text = sd.get("text", "") or ""
            for m in re.finditer(r"\b(\d*)d(\d+)([+\-]\d+)?\b", text):
                text_dice.append(
                    {
                        "campaign": title,
                        "doc_id": doc.id,
                        "actor": actor,
                        "notation": m.group(0),
                    }
                )

    return {
        "uid": uid,
        "campaigns": campaigns,
        "rolls": raw_rolls,
        "audit_events": audit_events,
        "text_dice": text_dice,
        "strategy_counts": dict(strategy_counter),
        "actor_counts": dict(actor_counter),
    }


def normalize_roll(r: dict) -> dict | None:
    """Normalize one roll dict into a (campaign, actor, notation, die_size, faces,
    total, dc, success, purpose) tuple for chi-squared consumption.

    Returns None if the notation can't be parsed (e.g. compound dice that don't
    fit `\\d*d\\d+`). The `faces` field is a list of raw die faces (length 1 for
    d20 single-die rolls, which is what χ² tests need).
    """
    roll = r["roll"]
    notation = roll.get("notation") or roll.get("roll") or ""
    m = re.match(r"(\d*)d(\d+)", notation)
    if not m:
        return None
    n_dice = int(m.group(1) or "1")
    die_size = int(m.group(2))

    # Extract raw face(s) — try multiple field names for backward compatibility
    raw = roll.get("rolls") or roll.get("faces") or roll.get("raw_faces") or roll.get("result") or roll.get("roll")
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
        "campaign": r["campaign"],
        "cid": r["cid"],
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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--email", help="User email (Firebase Auth lookup)")
    ap.add_argument("--uid", help="Or pass UID directly")
    ap.add_argument(
        "--output",
        default=None,
        help="Output JSON path (default: /tmp/<uid>_dice.json)",
    )
    ap.add_argument(
        "--include-raw",
        action="store_true",
        help="Include raw roll dicts in output (large)",
    )
    args = ap.parse_args()

    if not args.email and not args.uid:
        ap.error("Must supply --email or --uid")

    if args.email:
        uid = resolve_uid_by_email(args.email)
    else:
        uid = args.uid

    print(f"Extracting dice for UID={uid}", file=sys.stderr)
    data = extract_user_dice(uid)

    print(f"  campaigns: {len(data['campaigns'])}", file=sys.stderr)
    print(f"  rolls (raw): {len(data['rolls'])}", file=sys.stderr)
    print(f"  audit_events: {len(data['audit_events'])}", file=sys.stderr)
    print(f"  text dice notations: {len(data['text_dice'])}", file=sys.stderr)
    print(f"  actor split: {data['actor_counts']}", file=sys.stderr)
    print(f"  strategy split: {data['strategy_counts']}", file=sys.stderr)

    # Normalize and include in output
    parsed = [n for r in data["rolls"] if (n := normalize_roll(r)) is not None]
    print(f"  parsed rolls: {len(parsed)}", file=sys.stderr)

    output_path = args.output or f"/tmp/{uid}_dice.json"
    out = {
        "uid": uid,
        "campaigns": data["campaigns"],
        "actor_counts": data["actor_counts"],
        "strategy_counts": data["strategy_counts"],
        "rolls_normalized": parsed,
        "text_dice_count": len(data["text_dice"]),
    }
    if args.include_raw:
        out["rolls_raw"] = data["rolls"]

    with open(output_path, "w") as f:
        json.dump(out, f, indent=2, default=str)
    print(f"\nWrote {output_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())