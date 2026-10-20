#!/usr/bin/env python3
"""Health-probe a Gemini API key. Returns the count of models accessible.

Usage:
    python3 gemini_key_health.py --key AIzaSy...
    python3 gemini_key_health.py --key-file ~/.gemini_api_key_secret --key-name GEMINI_API_KEY

Output (stdout, single line):
    KEY_HEALTHY: <N> models accessible
    KEY_LEAKED: HTTP <code> — <body>
"""
import argparse
import json
import re
import sys
import urllib.request
import urllib.error


def load_key(args) -> str:
    if args.key:
        return args.key.strip()
    if not args.key_file or not args.key_name:
        sys.exit("Provide --key or both --key-file and --key-name")
    with open(args.key_file) as f:
        for line in f:
            m = re.match(r'(?:export\s+)?([A-Z_]+)=["\']?([^"\']\s]+)', line.strip())
            if m and m.group(1) == args.key_name:
                return m.group(2)
    sys.exit(f"Key {args.key_name} not found in {args.key_file}")


def probe(key: str) -> int:
    url = f"https://generativelanguage.googleapis.com/v1beta/models?key={key}"
    try:
        with urllib.request.urlopen(url, timeout=15) as resp:
            data = json.loads(resp.read())
            return len(data.get("models", []))
    except urllib.error.HTTPError as e:
        body = e.read().decode()[:200]
        print(f"KEY_LEAKED: HTTP {e.code} — {body}")
        sys.exit(2)
    except Exception as e:
        print(f"KEY_ERROR: {type(e).__name__}: {e}")
        sys.exit(3)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--key", help="API key value (overrides --key-file)")
    p.add_argument("--key-file", help="Path to a shell-sourceable key file")
    p.add_argument("--key-name", help="Env var name inside --key-file (e.g. GEMINI_API_KEY)")
    args = p.parse_args()

    key = load_key(args)
    n = probe(key)
    print(f"KEY_HEALTHY: {n} models accessible")
    sys.exit(0)


if __name__ == "__main__":
    main()