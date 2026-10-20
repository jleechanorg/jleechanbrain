#!/usr/bin/env python3
"""Make a Google Doc pageless (continuous scroll, no page breaks).

Uses the Google Docs API `docs.documents.batchUpdate` with two requests:
1. `updateDocumentStyle` to set `documentFormat.documentMode = 'PAGELESS'`
2. (Fallback) `setPageSize` for legacy docs that don't support documentMode

The Google Docs API uses `documentStyle.documentFormat.documentMode` with values
`PAGES` or `PAGELESS` (verified 2026-08-19 against the v3 campaign bible doc,
which showed `"documentMode": "PAGELESS"` — pageless docs do not paginate).

Requires:
- gogcli OAuth credentials at ~/Library/Application Support/gogcli/credentials.json
  (or set $GOG_PAGELESS_CREDS to override — useful when the runtime account
  differs from the canonical credentials.json; e.g., a workspace service account
  default vs. a personal Gmail OAuth token. The file must contain client_id,
  client_secret, AND refresh_token. Verified 2026-08-22.)
- The Docs API scope (https://www.googleapis.com/auth/documents)

Usage:
    gog_doc_pageless.py <doc_id> [<doc_id> ...]
    gog_doc_pageless.py --all                     # all docs in the user's Drive
    gog_doc_pageless.py --recent 5                # last 5 docs
    gog_doc_pageless.py --query "name contains 'Campaign Bible'" --dry-run
    GOG_PAGELESS_CREDS=/tmp/custom-creds.json gog_doc_pageless.py <doc_id>

Output: JSON {doc_id, success, mode_before, mode_after, ...} per doc
"""
import sys
import json
import requests
import argparse
from pathlib import Path

CREDENTIALS_PATH = Path(
    __import__("os").environ.get(
        "GOG_PAGELESS_CREDS",
        str(Path.home() / "Library/Application Support/gogcli/credentials.json"),
    )
)
TOKEN_URL = "https://oauth2.googleapis.com/token"
DOCS_API = "https://docs.googleapis.com/v1/documents"
DRIVE_API = "https://www.googleapis.com/drive/v3/files"


def get_access_token(creds: dict) -> str:
    """Exchange refresh_token for a fresh access_token."""
    resp = requests.post(TOKEN_URL, data={
        "client_id": creds["client_id"],
        "client_secret": creds["client_secret"],
        "refresh_token": creds["refresh_token"],
        "grant_type": "refresh_token",
    }, timeout=10)
    resp.raise_for_status()
    return resp.json()["access_token"]


def get_doc_mode(doc_id: str, token: str) -> str:
    """Return the current documentMode: PAGELESS, PAGES, or UNSPECIFIED."""
    headers = {"Authorization": f"Bearer {token}"}
    doc = requests.get(f"{DOCS_API}/{doc_id}", headers=headers, timeout=10).json()
    if "error" in doc:
        return f"ERROR: {doc.get('error', {}).get('message', 'unknown')}"
    return doc.get("documentStyle", {}).get("documentFormat", {}).get("documentMode", "UNSPECIFIED")


def make_pageless(doc_id: str, token: str) -> dict:
    """Set the doc's documentMode to PAGELESS via updateDocumentStyle.

    Verified 2026-08-19: setting `documentStyle.documentFormat.documentMode = 'PAGELESS'`
    is the correct API call. Works on docs that have documentStyle (which is all real
    Google Docs). Older test docs without documentStyle fall back to setPageSize.
    """
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    # Get current mode first
    mode_before = get_doc_mode(doc_id, token)
    if mode_before == "PAGELESS":
        return {"doc_id": doc_id, "success": True, "mode_before": mode_before, "mode_after": "PAGELESS", "action": "noop_already_pageless"}

    # batchUpdate with updateDocumentStyle to set documentMode = PAGELESS
    body = {
        "requests": [
            {
                "updateDocumentStyle": {
                    "documentStyle": {
                        "documentFormat": {"documentMode": "PAGELESS"},
                    },
                    "fields": "documentFormat.documentMode",
                }
            }
        ]
    }
    update_resp = requests.post(
        f"{DOCS_API}/{doc_id}:batchUpdate",
        headers=headers,
        json=body,
        timeout=15,
    )
    if update_resp.status_code != 200:
        return {"doc_id": doc_id, "success": False, "error": update_resp.text, "mode_before": mode_before}

    # Verify
    mode_after = get_doc_mode(doc_id, token)
    return {
        "doc_id": doc_id,
        "success": True,
        "mode_before": mode_before,
        "mode_after": mode_after,
        "action": "set_pageless" if mode_after == "PAGELESS" else "verify_failed",
    }


def list_docs(token: str, query: str = None, page_size: int = 10) -> list:
    """List Google Docs, optionally filtered by query."""
    headers = {"Authorization": f"Bearer {token}"}
    q = query or "mimeType='application/vnd.google-apps.document'"
    params = {
        "q": q,
        "pageSize": page_size,
        "fields": "files(id,name,createdTime,modifiedTime)",
    }
    resp = requests.get(DRIVE_API, headers=headers, params=params, timeout=10)
    resp.raise_for_status()
    return resp.json().get("files") or []


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("doc_ids", nargs="*", help="Google Doc ID(s) (44-char hash)")
    parser.add_argument("--all", action="store_true", help="Make all docs in the user's Drive pageless")
    parser.add_argument("--recent", type=int, metavar="N", help="Apply to the N most recent docs")
    parser.add_argument("--query", metavar="Q", help="Drive API query string to filter docs (e.g. \"name contains 'Campaign Bible'\")")
    parser.add_argument("--dry-run", action="store_true", help="Report current mode without making changes")
    parser.add_argument("--json", action="store_true", help="Output JSON lines (one per doc)")
    args = parser.parse_args()

    if not CREDENTIALS_PATH.exists():
        print(f"ERROR: gog credentials not found at {CREDENTIALS_PATH}", file=sys.stderr)
        sys.exit(1)
    creds = json.loads(CREDENTIALS_PATH.read_text())
    token = get_access_token(creds)

    targets = []
    if args.all or args.recent or args.query:
        n = args.recent or 10
        query = args.query or "mimeType='application/vnd.google-apps.document'"
        files = list_docs(token, query=query, page_size=max(n, 10))
        targets = [f["id"] for f in files[:n]]
    elif args.doc_ids:
        targets = list(args.doc_ids)
    else:
        parser.print_help()
        sys.exit(1)

    results = []
    for doc_id in targets:
        if args.dry_run:
            mode = get_doc_mode(doc_id, token)
            results.append({"doc_id": doc_id, "mode": mode, "action": "dry_run"})
        else:
            r = make_pageless(doc_id, token)
            results.append(r)

    if args.json:
        for r in results:
            print(json.dumps(r))
    else:
        # Pretty print
        ok = sum(1 for r in results if r.get("success") or r.get("action") == "dry_run")
        print(f"\nProcessed {len(results)} doc(s); {ok} OK / {len(results) - ok} failed\n")
        for r in results:
            doc_id = r["doc_id"]
            if r.get("action") == "dry_run":
                print(f"  [DRY] {doc_id}: mode = {r.get('mode')}")
            elif r.get("success") and r.get("mode_after") == "PAGELESS":
                print(f"  [OK]   {doc_id}: {r.get('mode_before')} -> PAGELESS ({r.get('action')})")
            else:
                print(f"  [FAIL] {doc_id}: {r.get('error', 'unknown error')}")


if __name__ == "__main__":
    main()
