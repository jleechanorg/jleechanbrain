"""extract_reddit_session.py — extract the Reddit session JWT from the
local macOS Chrome/Comet cookie store.

Used by the reddit-competitor-complaints launchd job so we don't need
OAuth credentials or PullPush.  The session JWT comes straight from
your existing logged-in browser, decrypted via the macOS Keychain
Safe Storage password + Chromium's cookie encryption scheme.

Verification (2026-06-23, MacBook Pro M-series):
  - Comet (Default profile) holds Reddit cookies in v10 encrypted form
  - 32-byte binary prefix + 722-byte JWT = the reddit_session cookie
  - JWT lasts ~365 days, exp field shows ~late-2026 for fresh sessions
  - reddit_session alone is sufficient for /.json endpoints; no need for
    csrf_token, loid, etc. — Reddit trusts the session cookie alone for
    read-only endpoints.  For POST we'd need csrf_token.

If your Reddit session expires or Comet rotates the cookie format, the
scraper will see the API return the "Blocked" page and fall back to
PullPush (the historical source).
"""

import json
import os
import re
import sqlite3
import subprocess
import sys
from pathlib import Path

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes

# --- Config ---

# Comet is the Chromium-based browser where Jeffrey's Reddit session lives
# (verified 2026-06-23).  Chrome's Default profile had no Reddit cookies.
COOKIE_DBS = [
    ("Comet Safe Storage",
     "${HOME}/Library/Application Support/Comet/Default/Cookies"),
    ("Chrome Safe Storage",
     "${HOME}/Library/Application Support/Google/Chrome/Default/Cookies"),
    ("Brave Safe Storage",
     "${HOME}/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies"),
]

# --- Keychain ---

def get_keychain_password(service: str) -> str:
    r = subprocess.run(
        ["security", "find-generic-password", "-s", service, "-w"],
        capture_output=True, text=True, timeout=10,
    )
    if r.returncode != 0:
        raise KeyError(f"keychain item '{service}' not found: {r.stderr.strip()}")
    return r.stdout.strip()

def derive_key(password: str, keylen: int) -> bytes:
    return PBKDF2HMAC(
        algorithm=hashes.SHA1(),
        length=keylen,
        salt=b"saltysalt",
        iterations=1003,
    ).derive(password.encode("utf-8"))

# --- Decrypt ---

def decrypt_v10(encrypted: bytes, key: bytes) -> bytes:
    """v10 = 'v10' || ciphertext, AES-128-CBC, IV = 16 spaces, PKCS7."""
    if len(encrypted) < 3 or encrypted[:3] != b"v10":
        raise ValueError(f"not a v10 cookie (prefix={encrypted[:3]!r})")
    cipher = Cipher(algorithms.AES(key), modes.CBC(b" " * 16))
    decryptor = cipher.decryptor()
    plain = decryptor.update(encrypted[3:]) + decryptor.finalize()
    pad_count = plain[-1]
    if 1 <= pad_count <= 16 and all(b == pad_count for b in plain[-pad_count:]):
        return plain[:-pad_count]
    return plain  # best-effort

# --- JWT extraction ---

# Match a real JWT (header.payload.signature, all base64url chars).
# reddit_session is ~700-900 chars; this regex won't match anything else.
_JWT_RE = re.compile(rb"(eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)")

def extract_jwt_from_plaintext(plain: bytes) -> str | None:
    """Find the first JWT-shaped blob inside a decrypted cookie value.
    Comet/Chromium store the JWT after a 32-byte binary tag."""
    m = _JWT_RE.search(plain)
    if not m:
        return None
    return m.group(1).decode("ascii", errors="replace")

# --- Main ---

def find_reddit_session() -> str | None:
    """Try every configured browser profile for a Reddit session JWT."""
    for service, db_path in COOKIE_DBS:
        if not Path(db_path).exists():
            continue
        try:
            password = get_keychain_password(service)
        except KeyError:
            continue
        key = derive_key(password, 16)
        try:
            conn = sqlite3.connect(db_path)
        except sqlite3.OperationalError:
            continue
        try:
            conn.row_factory = sqlite3.Row
            for row in conn.execute(
                "SELECT encrypted_value FROM cookies "
                "WHERE host_key LIKE '%reddit.com' AND name = 'reddit_session'"
            ):
                raw = row["encrypted_value"]
                if not raw:
                    continue
                enc = raw if isinstance(raw, (bytes, bytearray)) else bytes(raw, "latin-1")
                try:
                    plain = decrypt_v10(enc, key)
                except Exception:
                    continue
                jwt = extract_jwt_from_plaintext(plain)
                if jwt:
                    return jwt
        finally:
            conn.close()
    return None

def main():
    jwt = find_reddit_session()
    if not jwt:
        print("NO_SESSION: no reddit_session cookie found in any local browser", file=sys.stderr)
        sys.exit(1)
    print(jwt)

if __name__ == "__main__":
    main()