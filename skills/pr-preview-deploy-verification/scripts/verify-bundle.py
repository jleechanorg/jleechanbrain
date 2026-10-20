#!/usr/bin/env python3
"""
verify-bundle.py — Verify a PR preview Cloud Run deploy actually contains expected strings.

Exits 0 if all expected strings are found in some bundle referenced by the preview's index.html.
Exits 1 if any string is missing (stale bundle detected).
Exits 2 if the served bundle byte-count disagrees with the source byte-count.

Usage:
    python3 verify-bundle.py <preview_url> <needle1> [needle2 ...]
                              [--source-check <repo> <path> <sha>]
                              [--bundle-glob <glob>]

Example:
    python3 verify-bundle.py \\
      https://mvp-site-app-s8-i6xf2p72ka-uc.a.run.app \\
      signup.complete signin.success game.open first_turn.begin first_turn.outcome \\
      --source-check jleechanorg/worldarchitect.ai mvp_site/frontend_v1/auth.js 0a9d234ab
"""

import argparse
import fnmatch
import json
import re
import subprocess
import sys
import urllib.request


def list_bundle_urls(preview_url: str) -> list[str]:
    """Fetch preview index.html and return all .js script URLs (absolute)."""
    base = preview_url.rstrip("/")
    try:
        req = urllib.request.Request(
            base + "/", headers={"Cache-Control": "no-cache", "Pragma": "no-cache"}
        )
        idx = urllib.request.urlopen(req, timeout=15).read().decode("utf-8", errors="replace")
    except Exception as e:
        print(f"WARN: failed to fetch {base}/: {e}", file=sys.stderr)
        return []

    scripts = re.findall(r'src="([^"]*\.js)"', idx)
    out = []
    for s in scripts:
        if s.startswith("http://") or s.startswith("https://"):
            out.append(s)
        elif s.startswith("/"):
            out.append(base + s)
        else:
            out.append(base + "/" + s)
    return out


def grep_bundles(urls: list[str], needles: list[str]) -> dict[str, list[str]]:
    """Return mapping of needle -> list of URLs where it was found."""
    hits = {n: [] for n in needles}
    for url in urls:
        try:
            req = urllib.request.Request(
                url, headers={"Cache-Control": "no-cache", "Pragma": "no-cache"}
            )
            body = urllib.request.urlopen(req, timeout=15).read()
        except Exception as e:
            print(f"WARN: {url} failed: {e}", file=sys.stderr)
            continue
        for n in needles:
            if n.encode() in body:
                hits[n].append(url)
    return hits


def get_gh_source_size(repo: str, path: str, sha: str) -> int | None:
    """Return source file size from GitHub API contents endpoint."""
    out = subprocess.run(
        ["gh", "api", f"repos/{repo}/contents/{path}?ref={sha}", "--jq", ".size"],
        capture_output=True, text=True, timeout=30,
    )
    if out.returncode != 0 or not out.stdout.strip():
        return None
    try:
        return int(out.stdout.strip())
    except ValueError:
        return None


def get_served_size(url: str) -> int | None:
    """Return Content-Length for a served URL (HEAD)."""
    try:
        req = urllib.request.Request(
            url, method="HEAD", headers={"Cache-Control": "no-cache"}
        )
        resp = urllib.request.urlopen(req, timeout=15)
        cl = resp.headers.get("Content-Length")
        return int(cl) if cl else None
    except Exception:
        return None


def main() -> int:
    p = argparse.ArgumentParser(
        description="Verify PR preview bundle contains expected strings."
    )
    p.add_argument("preview_url", help="Base URL of the preview (e.g. https://mvp-site-app-s8-...run.app)")
    p.add_argument("needles", nargs="+", help="Strings that must appear in some served bundle")
    p.add_argument(
        "--source-check",
        nargs=3,
        metavar=("REPO", "PATH", "SHA"),
        help="Compare served bundle size against gh source size",
    )
    p.add_argument(
        "--bundle-glob",
        default=None,
        help="Only consider bundles whose URL matches this glob (e.g. '*/auth.*.js')",
    )
    p.add_argument("--json", action="store_true", help="Emit JSON result on stdout")
    args = p.parse_args()

    urls = list_bundle_urls(args.preview_url)
    if args.bundle_glob:
        urls = [u for u in urls if fnmatch.fnmatch(u, args.bundle_glob)]
    print(f"Found {len(urls)} bundle(s) at {args.preview_url}")
    for u in urls:
        print(f"  {u}")

    hits = grep_bundles(urls, args.needles)

    missing = [n for n, fs in hits.items() if not fs]
    print("\nGrep results:")
    for n, fs in hits.items():
        if fs:
            print(f"  FOUND  {n}  in  {fs[0]}")
        else:
            print(f"  MISS   {n}")

    result = {
        "preview_url": args.preview_url,
        "bundle_count": len(urls),
        "needles_total": len(args.needles),
        "needles_found": len(args.needles) - len(missing),
        "needles_missing": missing,
        "hits_per_needle": {n: fs for n, fs in hits.items()},
        "verdict": "PASS" if not missing else "FAIL",
    }

    exit_code = 0
    if missing:
        print(f"\nFAIL: {len(missing)} expected string(s) missing from bundle: {missing}")
        exit_code = 1

    if args.source_check and urls:
        repo, path, sha = args.source_check
        src_size = get_gh_source_size(repo, path, sha)
        served_size = get_served_size(urls[0])
        print(f"\nSource size (gh, {repo}/{path}@{sha[:8]}): {src_size}")
        print(f"Served size ({urls[0]}):                        {served_size}")
        if src_size and served_size and src_size != served_size:
            print(
                f"WARN: size mismatch — bundle may be stale "
                f"(source={src_size}, served={served_size}, delta={served_size - src_size})"
            )
            result["source_size"] = src_size
            result["served_size"] = served_size
            result["size_delta"] = served_size - src_size
            if exit_code == 0:
                exit_code = 2

    if args.json:
        print("\n" + json.dumps(result, indent=2))

    if exit_code == 0:
        print("\nPASS: all expected strings found in served bundle")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
