#!/usr/bin/env python3
"""
auth_bridge.py — Credentials Recovery Bridge & Cookie Decryptor.
Extracts and decrypts cookies and saved logins from Chromium/Chrome profiles
via browserclaw, HAR network captures, or direct macOS Keychain Safe Storage PBKDF2 derivation.
"""

import json
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
from pathlib import Path
from typing import Any


class CredentialStore:
    """Secure in-memory credential storage with zero-plaintext logging and sanitization filters."""

    def __init__(self):
        self._store: dict[str, Any] = {}

    def set(self, key: str, value: Any) -> None:
        self._store[key] = value

    def get(self, key: str, default: Any = None) -> Any:
        return self._store.get(key, default)

    def has(self, key: str) -> bool:
        return key in self._store

    def get_sanitized(self) -> dict[str, str]:
        """Return masked version of credentials safe for logs."""
        sanitized = {}
        for k, v in self._store.items():
            if isinstance(v, str):
                if len(v) <= 6:
                    sanitized[k] = "***"
                else:
                    sanitized[k] = f"{v[:3]}...{v[-3:]}"
            elif isinstance(v, dict):
                sanitized[k] = {
                    sub_k: (
                        f"{sub_v[:3]}...{sub_v[-3:]}"
                        if isinstance(sub_v, str) and len(sub_v) > 6
                        else "***"
                    )
                    for sub_k, sub_v in v.items()
                }
            elif isinstance(v, list):
                sanitized[k] = f"[{len(v)} items]"
            else:
                sanitized[k] = "***"
        return sanitized

    def clear(self) -> None:
        self._store.clear()


class ChromiumCookieDecryptor:
    """Direct PBKDF2 key derivation and decryption for macOS Chromium Cookie and Login databases."""

    @staticmethod
    def derive_key(
        password: str,
        salt: bytes = b"saltysalt",
        iterations: int = 1003,
        key_length: int = 16,
    ) -> bytes:
        from cryptography.hazmat.backends import default_backend
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

        kdf = PBKDF2HMAC(
            algorithm=hashes.SHA1(),
            length=key_length,
            salt=salt,
            iterations=iterations,
            backend=default_backend(),
        )
        return kdf.derive(password.encode("utf8"))

    @staticmethod
    def decrypt_value(
        encrypted_blob: bytes, key: bytes, iv: bytes = b" " * 16
    ) -> str | None:
        """Decrypts Chrome v10 encrypted blob using AES-128-CBC."""
        if not encrypted_blob or not encrypted_blob.startswith(b"v10"):
            return None
        from cryptography.hazmat.backends import default_backend
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

        raw_enc = encrypted_blob[3:]
        cipher = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend())
        decryptor = cipher.decryptor()
        decrypted = decryptor.update(raw_enc) + decryptor.finalize()

        # Validate PKCS7 padding
        pad_len = decrypted[-1]
        if 1 <= pad_len <= 16:
            padding = decrypted[-pad_len:]
            if padding == bytes([pad_len] * pad_len):
                decrypted = decrypted[:-pad_len]
                return decrypted.decode("utf8", errors="ignore")
        return None

    @staticmethod
    def decrypt_cookies_db(
        db_path: str | Path,
        key: bytes,
        domain_filter: str = "%",
    ) -> list[dict[str, Any]]:
        """Decrypt SQLite Cookies database directly."""
        db_p = Path(db_path)
        if not db_p.exists():
            return []

        cookies = []
        with tempfile.NamedTemporaryFile(suffix=".db") as tmp:
            shutil.copyfile(db_p, tmp.name)
            conn = sqlite3.connect(tmp.name)
            cursor = conn.cursor()
            cursor.execute(
                "SELECT host_key, name, path, encrypted_value, is_secure, is_httponly FROM cookies WHERE host_key LIKE ?",
                (domain_filter,),
            )
            rows = cursor.fetchall()
            conn.close()

        for host_key, name, path, enc_val, is_sec, is_http in rows:
            val = ChromiumCookieDecryptor.decrypt_value(enc_val, key)
            if val is not None:
                cookies.append({
                    "name": name,
                    "value": val,
                    "domain": host_key,
                    "path": path,
                    "secure": bool(is_sec),
                    "httpOnly": bool(is_http),
                })
        return cookies


class BrowserclawAuthBridge:
    """Extracts tokens, session cookies, and auth headers from browserclaw HAR captures."""

    @staticmethod
    def extract_from_har(har_data: dict[str, Any] | str) -> dict[str, Any]:
        """Extract cookies, bearer tokens, CSRF tokens from a HAR data structure."""
        if isinstance(har_data, str):
            try:
                har_data = json.loads(har_data)
            except Exception:
                return {"cookies": [], "headers": {}, "tokens": {}}

        log = har_data.get("log", {})
        entries = log.get("entries", [])
        cookies_dict: dict[str, dict[str, Any]] = {}
        auth_headers: dict[str, str] = {}
        csrf_tokens: dict[str, str] = {}

        for entry in entries:
            req = entry.get("request", {})
            for c in req.get("cookies", []):
                name = c.get("name")
                if name:
                    cookies_dict[name] = {
                        "name": name,
                        "value": c.get("value"),
                        "domain": c.get("domain", ""),
                        "path": c.get("path", "/"),
                    }

            for h in req.get("headers", []):
                h_name = h.get("name", "").lower()
                h_val = h.get("value", "")
                if h_name == "authorization":
                    auth_headers["authorization"] = h_val
                    if h_val.startswith("Bearer "):
                        csrf_tokens["bearer_token"] = h_val[7:]
                elif "csrf" in h_name or "modhash" in h_name or "x-modhash" in h_name:
                    csrf_tokens[h_name] = h_val

            res = entry.get("response", {})
            for c in res.get("cookies", []):
                name = c.get("name")
                if name:
                    cookies_dict[name] = {
                        "name": name,
                        "value": c.get("value"),
                        "domain": c.get("domain", ""),
                        "path": c.get("path", "/"),
                    }

        return {
            "cookies": list(cookies_dict.values()),
            "headers": auth_headers,
            "tokens": csrf_tokens,
        }


class AuthBridge:
    def __init__(self, chrome_user_data_dir: str | None = None):
        self.chrome_dir = Path(
            chrome_user_data_dir
            or os.path.expanduser("~/Library/Application Support/Google/Chrome")
        )
        self.cred_store = CredentialStore()

    def decrypt_cookies_via_browserclaw(
        self, profile: str = "Default", domain_filter: str = "%"
    ) -> list[dict[str, Any]]:
        """Decrypt cookies using browserclaw CLI with variable timeout."""
        cookies_db = self.chrome_dir / profile / "Cookies"
        if not cookies_db.exists():
            candidates = [
                self.chrome_dir / p / "Cookies"
                for p in ["Default", "Profile 1", "Profile 2", "Profile 3"]
            ]
            found = [c for c in candidates if c.exists()]
            if not found:
                return []
            cookies_db = found[0]

        with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tmp:
            tmp_path = tmp.name

        try:
            cmd = [
                "/opt/homebrew/bin/browserclaw",
                "cookies",
                "decrypt",
                "--db",
                str(cookies_db),
                "--output",
                tmp_path,
                "--domain-filter",
                domain_filter,
            ]
            subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=600)
            with open(tmp_path, encoding="utf-8") as f:
                data = json.load(f)
                cookies = data.get("cookies", []) if isinstance(data, dict) else data
                self.cred_store.set(f"cookies_{domain_filter}", cookies)
                return cookies
        except Exception as e:
            print(f"[AuthBridge] browserclaw decrypt error: {e}")
            return []
        finally:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)

    def decrypt_saved_login(
        self, domain_query: str, profile: str = "Default"
    ) -> dict[str, str] | None:
        """Decrypt saved credentials from Chrome Login Data via macOS Keychain Safe Storage."""
        login_db = self.chrome_dir / profile / "Login Data"
        if not login_db.exists():
            candidates = [
                self.chrome_dir / p / "Login Data"
                for p in ["Default", "Profile 1", "Profile 2", "Profile 3"]
            ]
            found = [c for c in candidates if c.exists()]
            if not found:
                return None
            login_db = found[0]

        # 1. Fetch Keychain password
        try:
            cmd = [
                "security",
                "find-generic-password",
                "-w",
                "-s",
                "Chrome Safe Storage",
                "-a",
                "Chrome",
            ]
            proc = subprocess.run(
                cmd, capture_output=True, text=True, check=True, timeout=600
            )
            my_pass = proc.stdout.strip()
        except Exception as e:
            print(f"[AuthBridge] Keychain read error: {e}")
            return None

        # 2. Derive key via PBKDF2
        try:
            key = ChromiumCookieDecryptor.derive_key(my_pass)
            iv = b" " * 16
        except Exception as e:
            print(f"[AuthBridge] Key derivation error: {e}")
            return None

        # 3. Read SQLite copy safely
        with tempfile.NamedTemporaryFile(suffix=".db") as tmp:
            shutil.copyfile(login_db, tmp.name)
            conn = sqlite3.connect(tmp.name)
            cursor = conn.cursor()
            cursor.execute(
                "SELECT origin_url, username_value, password_value FROM logins WHERE origin_url LIKE ?",
                (f"%{domain_query}%",),
            )
            rows = cursor.fetchall()
            conn.close()

        for origin, user, enc_pass in rows:
            if enc_pass:
                decrypted_pass = ChromiumCookieDecryptor.decrypt_value(enc_pass, key, iv)
                if decrypted_pass is not None:
                    creds = {
                        "user": user,
                        "password": decrypted_pass,
                        "origin": origin,
                    }
                    self.cred_store.set(f"login_{domain_query}", creds)
                    return creds

        return None
