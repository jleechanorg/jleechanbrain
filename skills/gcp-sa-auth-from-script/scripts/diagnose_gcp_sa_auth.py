#!/usr/bin/env python3
"""diagnose_gcp_sa_auth.py — 30-second GCP SA auth diagnostic for Python scripts.

Run this when ANY GCP-API script fails to auth. It bypasses urllib3 and
calls google.auth directly so the real OAuth error surfaces, not the
chained SSLError / MaxRetryError / 403 noise.

Usage:
    python3 diagnose_gcp_sa_auth.py \
        --sa ${HOME}/serviceAccountKey.json \
        --scope https://www.googleapis.com/auth/cloud-platform \
        --test-api https://bigquery.googleapis.com/bigquery/v2/projects/worldarchitecture-ai/queries

Exits 0 if auth + API call succeed. Non-zero otherwise, with the actual
OAuth error (not the chained SSL layer) in the output.

Companion to: ~/.smartclaw/skills/gcp-sa-auth-from-script/SKILL.md
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from typing import Optional


def diagnose(sa_path: str, scope: str, test_api: Optional[str]) -> int:
    """Run the 4-step diagnostic; print findings; return exit code."""
    print("=" * 72)
    print("GCP SA Auth Diagnostic (gcp-sa-auth-from-script skill)")
    print("=" * 72)
    print()

    # Step 0 — Verify the SA file exists and parses
    try:
        with open(sa_path) as f:
            sa = json.load(f)
        print(f"[Step 0] SA file: {sa_path}")
        print(f"          type={sa.get('type')}  email={sa.get('client_email')}")
        print(f"          project_id={sa.get('project_id')}")
        print(f"          scopes_in_file={'yes' if sa.get('scope') else 'no (must pass scopes= explicitly)'}")
    except (FileNotFoundError, json.JSONDecodeError, KeyError) as exc:
        print(f"[Step 0] FAIL: cannot load SA file: {exc}")
        return 2

    # Step 1 — Mint a token via google.auth.default() with scopes=
    print()
    print(f"[Step 1] google.auth.default(scopes=['{scope}']) ...")
    import google.auth
    from google.auth.transport.requests import Request as GARequest

    try:
        creds, project = google.auth.default(scopes=(scope,))
        print(f"          OK: creds={type(creds).__module__}.{type(creds).__name__}  project={project}")
    except Exception as exc:
        print(f"          FAIL: {type(exc).__name__}: {exc}")
        root = exc.__cause__ or exc.__context__
        if root and root is not exc:
            print(f"                chained: {type(root).__name__}: {root}")
        return 3

    # Step 2 — Refresh the token (this is where the JWT grant happens)
    print()
    print(f"[Step 2] creds.refresh(Request()) ...")
    try:
        creds.refresh(GARequest())
        token_len = len(creds.token) if creds.token else 0
        print(f"          OK: token_len={token_len}")
        if not creds.valid:
            print(f"          WARN: creds.valid=False even after refresh")
    except Exception as exc:
        print(f"          FAIL: {type(exc).__name__}: {exc}")
        root = exc.__cause__ or exc.__context__
        if root and root is not exc:
            print(f"                chained: {type(root).__name__}: {root}")
        print()
        print("DIAGNOSIS HINTS:")
        msg = str(exc)
        if "invalid_scope" in msg:
            print("  - The SA JWT was minted WITHOUT a `scope` claim.")
            print("    This means scopes= was not passed to google.auth.default(),")
            print("    OR the JWT was constructed without scopes. Fix: pass scopes=(<scope>,).")
        if "invalid_grant" in msg:
            print("  - The SA's private key is invalid, or the SA was deleted in GCP.")
            print("    Verify the SA still exists: gcloud iam service-accounts describe <email>")
        return 4

    # Step 3 — Optional: hit a real API to verify the IAM role is intact
    if test_api:
        print()
        print(f"[Step 3] GET {test_api} ...")
        try:
            req = urllib.request.Request(
                test_api,
                headers={"Authorization": f"Bearer {creds.token}"},
                method="GET",
            )
            with urllib.request.urlopen(req, timeout=30) as resp:
                print(f"          OK: HTTP {resp.status}")
        except urllib.error.HTTPError as exc:
            print(f"          FAIL: HTTP {exc.code}")
            try:
                body = exc.read().decode("utf-8")[:500]
                print(f"                body: {body}")
            except Exception:
                pass
            if exc.code == 401:
                print("                Token was rejected as invalid. SA may have been deleted.")
            elif exc.code == 403:
                print("                SA authenticated successfully but lacks the IAM role for this API.")
                print("                Fix: gcloud projects add-iam-policy-binding <project> \\")
                print("                      --member='serviceAccount:<email>' --role='roles/<role>'")
            return 5
        except Exception as exc:
            print(f"          FAIL: {type(exc).__name__}: {exc}")
            return 5

    print()
    print("=" * 72)
    print("All steps passed. The script's auth path is healthy.")
    print("=" * 72)
    return 0


def main() -> int:
    p = argparse.ArgumentParser(
        description="30-second diagnostic for GCP SA auth failures in Python scripts."
    )
    p.add_argument(
        "--sa",
        required=True,
        help="Path to service-account JSON key file (e.g. ~/serviceAccountKey.json)",
    )
    p.add_argument(
        "--scope",
        default="https://www.googleapis.com/auth/cloud-platform",
        help="OAuth scope URL to request (default: cloud-platform, works for BQ/GCS/Logging/etc.)",
    )
    p.add_argument(
        "--test-api",
        default=None,
        help="Optional: GET against this URL with the minted token to verify IAM role (e.g. BQ queries URL)",
    )
    args = p.parse_args()
    return diagnose(args.sa, args.scope, args.test_api)


if __name__ == "__main__":
    sys.exit(main())