#!/usr/bin/env python3
"""Subset chi-squared on d20 rolls split by rng_verified provenance.

Use after extract_one_campaign.py to surface the structural root cause of dice
bias — when the audit looks broken, the answer is usually that the model in
question isn't running the dice tool at all (rng_verified=unset bucket). See
references/2026-08-15-noctune-warcraft-3-gemini-3-7-fabrication.md for the
canonical case study.

Usage:
    cd ~/projects/worldarchitect.ai
    WORLDAI_DEV_MODE=true .venv/bin/python \\
        ~/.smartclaw/skills/wa-dice-integrity-audit/scripts/audit_subsets.py \\
        --dice-json /tmp/<uid>_dice.json \\
        --uid <uid> --cid <cid>
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter

WA_REPO = "${HOME}/worldarchitect.ai"


def init_firestore():
    sys.path.insert(0, os.path.join(WA_REPO, "mvp_site"))
    sys.path.insert(0, WA_REPO)
    os.environ.setdefault("WORLDAI_DEV_MODE", "true")
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
            {"projectId": "worldarchitecture-ai"},
        )
    from google.cloud.firestore import Client
    return Client(project="worldarchitecture-ai")


def collect_d20_by_provenance(db, uid, cid):
    """For each d20 single-die roll in the campaign, classify by debug_info.rng_verified.

    Returns three lists (rng_true, rng_false, rng_unset) of single face values.
    """
    camp_ref = db.collection("users").document(uid).collection("campaigns").document(cid)
    rng_true, rng_false, rng_unset = [], [], []

    for doc in camp_ref.collection("story").stream():
        sd = doc.to_dict() or {}
        debug = sd.get("debug_info") or {}
        rv = debug.get("rng_verified")
        ar = sd.get("action_resolution") or {}
        mech = ar.get("mechanics") if isinstance(ar, dict) else {}
        if not isinstance(mech, dict):
            continue

        for r in mech.get("rolls", []) or []:
            if not isinstance(r, dict):
                continue
            m = re.match(r"(\d*)d(\d+)", r.get("notation", ""))
            if not m or int(m.group(2)) != 20:
                continue
            raw = (
                r.get("rolls") or r.get("faces") or r.get("raw_faces")
                or r.get("result") or r.get("roll")
            )
            if isinstance(raw, list):
                face = raw[0] if raw else None
            elif isinstance(raw, (int, float)):
                face = int(raw)
            elif isinstance(raw, str):
                try:
                    face = int(raw.split(",")[0])
                except ValueError:
                    face = None
            else:
                face = None
            if face is None or not (1 <= face <= 20):
                continue

            if rv is True:
                rng_true.append(face)
            elif rv is False:
                rng_false.append(face)
            else:
                rng_unset.append(face)

    return rng_true, rng_false, rng_unset


def report(name, faces):
    sys.path.insert(0, "${HOME}/.smartclaw/skills/wa-dice-integrity-audit/scripts")
    from chi_squared_audit import test_uniformity_d20

    print("=" * 72)
    print(name)
    print("=" * 72)
    if not faces:
        print("  (no rolls in this subset)")
        return
    t = test_uniformity_d20(faces)
    print(f"  n = {t['n']}")
    print(f"  counts = {dict(sorted(Counter(faces).items()))}")
    print(f"  chi2 = {t['chi2']:.3f}, df = {t['df']}")
    print(f"  mean = {t['mean']:.2f}, median = {t['median']}, stdev = {t['stdev']:.2f}")
    print(f"  Critical(0.05) = {t['critical_05']:.3f}  -> {'PASS' if t['pass_05'] else 'FAIL'}")
    print(f"  Critical(0.01) = {t['critical_01']:.3f}  -> {'PASS' if t['pass_01'] else 'FAIL'}")
    print()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dice-json", required=True, help="Output JSON from extract_one_campaign.py")
    ap.add_argument("--uid", required=True, help="Firestore UID (owner of the campaign)")
    ap.add_argument("--cid", required=True, help="Campaign ID")
    args = ap.parse_args()

    db = init_firestore()
    rng_true, rng_false, rng_unset = collect_d20_by_provenance(db, args.uid, args.cid)

    report("SUBSET A: rng_verified=True  (server-RNG path)", rng_true)
    report("SUBSET B: rng_verified=False (caught fabrication)", rng_false)
    report("SUBSET C: rng_verified=unset (no telemetry — model did NOT call dice tool)", rng_unset)
    report("ALL d20 single-die rolls combined", rng_true + rng_false + rng_unset)


if __name__ == "__main__":
    main()