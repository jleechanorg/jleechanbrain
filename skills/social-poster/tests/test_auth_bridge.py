#!/usr/bin/env python3
"""
Unit & Integration Tests for AuthBridge, ChromiumCookieDecryptor, and BrowserclawAuthBridge.
"""

import json
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

from auth_bridge import (
    AuthBridge,
    BrowserclawAuthBridge,
    ChromiumCookieDecryptor,
    CredentialStore,
)


class TestAuthBridge(unittest.TestCase):
    def test_credential_store_masking(self):
        store = CredentialStore()
        store.set("api_key", "secret123456")
        store.set("short", "abc")
        store.set("nested", {"token": "verylongsecrettoken123"})
        store.set("items", [1, 2, 3])

        sanitized = store.get_sanitized()
        self.assertEqual(sanitized["api_key"], "sec...456")
        self.assertEqual(sanitized["short"], "***")
        self.assertEqual(sanitized["nested"]["token"], "ver...123")
        self.assertEqual(sanitized["items"], "[3 items]")

    def test_pbkdf2_key_derivation_and_roundtrip(self):
        password = "test_password_keychain"
        salt = b"saltysalt"
        key = ChromiumCookieDecryptor.derive_key(password, salt=salt, iterations=1003, key_length=16)
        self.assertEqual(len(key), 16)

        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.backends import default_backend

        plaintext = b"session_token_12345_abcde"
        pad_len = 16 - (len(plaintext) % 16)
        padded = plaintext + bytes([pad_len] * pad_len)
        iv = b" " * 16

        cipher = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend())
        encryptor = cipher.encryptor()
        ciphertext = encryptor.update(padded) + encryptor.finalize()

        encrypted_blob = b"v10" + ciphertext
        decrypted = ChromiumCookieDecryptor.decrypt_value(encrypted_blob, key, iv)
        self.assertEqual(decrypted, "session_token_12345_abcde")

    def test_har_parsing_and_token_extraction(self):
        sample_har = {
            "log": {
                "entries": [
                    {
                        "request": {
                            "cookies": [
                                {"name": "reddit_session", "value": "xyz789", "domain": "reddit.com"},
                                {"name": "_mastodon_session", "value": "masto123", "domain": "mastodon.social"},
                            ],
                            "headers": [
                                {"name": "Authorization", "value": "Bearer test_bearer_token_abc"},
                                {"name": "X-Modhash", "value": "modhash_xyz"},
                            ],
                        },
                        "response": {
                            "cookies": []
                        }
                    }
                ]
            }
        }

        extracted = BrowserclawAuthBridge.extract_from_har(sample_har)
        self.assertEqual(len(extracted["cookies"]), 2)
        self.assertEqual(extracted["headers"]["authorization"], "Bearer test_bearer_token_abc")
        self.assertEqual(extracted["tokens"]["bearer_token"], "test_bearer_token_abc")
        self.assertEqual(extracted["tokens"]["x-modhash"], "modhash_xyz")


if __name__ == "__main__":
    unittest.main()
