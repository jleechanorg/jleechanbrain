#!/usr/bin/env python3
"""Refresh the git_provenance.git_head field on an evidence gist metadata.json via direct REST PATCH.

`gh gist edit` is broken in non-interactive shells: fails with
`TERM environment variable not set` if $TERM unset, and with `TERM=xterm` it
tries to spawn `emacs` which is not installed. The fallback is direct REST
PATCH via urllib.request.

Verified 2026-08-18, jleechanorg/worldarchitect.ai PR #9046, gist
9b7c0bbc8131611ee9dce07366759c09.

Usage:
  python3 scripts/refresh_gist_metadata.py <gist-id> <new-git-head-sha> [metadata-filename]

Env:
  GH_TOKEN  — must be set (use `gh auth token` to grab from shell env)

After running this script, push a docs-only commit on top of HEAD so
HEAD <= the new git_head field is true (prerequisite for Evidence Gate Check 7).
"""
import json
import os
import sys
import urllib.request


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2

    gist_id = sys.argv[1]
    new_head = sys.argv[2]
    metadata_filename = sys.argv[3] if len(sys.argv) > 3 else "metadata.json"

    token = os.environ.get("GH_TOKEN", "").strip()
    if not token:
        # Fallback to gh CLI token if shell has it
        out = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True)
        token = out.stdout.strip()
    if not token:
        print("FATAL: GH_TOKEN not set and `gh auth token` returned empty", file=sys.stderr)
        return 1

    api = f"https://api.github.com/gists/{gist_id}"
    headers_get = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}
    headers_patch = {**headers_get, "Content-Type": "application/json"}

    # 1. Read current gist metadata.
    with urllib.request.urlopen(urllib.request.Request(api, headers=headers_get)) as r:
        gist_data = json.loads(r.read())

    files = gist_data.get("files", {})
    if metadata_filename not in files:
        print(
            f"FATAL: {metadata_filename!r} not in gist files (have: {list(files.keys())})",
            file=sys.stderr,
        )
        return 1

    metadata = json.loads(files[metadata_filename]["content"])
    old_head = metadata.get("git_provenance", {}).get("git_head", "<unset>")

    # 2. Update the field.
    metadata.setdefault("git_provenance", {})
    metadata["git_provenance"]["git_head"] = new_head
    import time
    metadata["git_provenance"]["capture_timestamp_unix"] = int(time.time())
    metadata["git_provenance"]["capture_timestamp_iso"] = time.strftime(
        "%Y-%m-%dT%H:%M:%SZ", time.gmtime()
    )

    # 3. PATCH via REST.
    payload = {"files": {metadata_filename: {"content": json.dumps(metadata, indent=2)}}}
    req = urllib.request.Request(
        api,
        data=json.dumps(payload).encode(),
        headers={**headers_patch, "X-HTTP-Method-Override": "PATCH"},
        method="POST",  # GitHub accepts POST + X-HTTP-Method-Override: PATCH on /gists/<id>
    )
    with urllib.request.urlopen(req) as r:
        result = json.loads(r.read())

    # 4. Read back to verify.
    with urllib.request.urlopen(urllib.request.Request(api, headers=headers_get)) as r:
        verify = json.loads(r.read())
    new_meta = json.loads(verify["files"][metadata_filename]["content"])
    verified_head = new_meta.get("git_provenance", {}).get("git_head")

    print(f"OK: gist {gist_id} {metadata_filename} git_head: {old_head[:10]} -> {verified_head[:10]}")
    return 0 if verified_head == new_head else 3


if __name__ == "__main__":
    sys.exit(main())
