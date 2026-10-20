---
title: Nostr keypair generation (bip340 nsec/npub)
verified: 2026-08-20
status: works without internet or signup
---

# Nostr Keypair Generation

**No signup, no email, no password.** Nostr identity = a secp256k1
keypair. The `nsec` is the secret key; the `npub` is derived from the
public key. **Whoever holds the `nsec` owns the identity forever —
there is no recovery path.**

## Verified recipe (2026-08-20, hermes session `${SLACK_CHANNEL_ID}/p1787248634.248549`)

```python
import os, secp256k1

# CHARSET for bech32 (BIP-173)
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

def bech32_polymod(values):
    GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    chk = 1
    for v in values:
        b = chk >> 25
        chk = (chk & 0x1ffffff) << 5 ^ v
        for i in range(5):
            chk ^= GEN[i] if ((b >> i) & 1) else 0
    return chk

def bech32_hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]

def bech32_create_checksum(hrp, data):
    pm = bech32_polymod(bech32_hrp_expand(hrp) + data + [0,0,0,0,0,0])
    return [(pm >> 5 * (5 - i)) & 31 for i in range(6)]

def bech32_encode(hrp, data):
    combined = data + bech32_create_checksum(hrp, data)
    return hrp + "1" + "".join([CHARSET[d] for d in combined])

def convertbits(data, frombits, tobits, pad=True):
    acc = 0
    bits = 0
    ret = []
    maxv = (1 << tobits) - 1
    for value in data:
        acc = (acc << frombits) | value
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad and bits:
        ret.append((acc << (tobits - bits)) & maxv)
    return ret

# Generate keypair
sk_bytes = os.urandom(32)
priv = secp256k1.PrivateKey(sk_bytes)
pub = priv.pubkey.serialize(compressed=True)  # 33 bytes
xonly_pub = pub[1:]  # strip parity byte → 32 bytes x-only pubkey for npub

# Encode nsec (5-bit groups of secret key)
nsec_data = convertbits(list(sk_bytes), 8, 5, True)
nsec = bech32_encode("nsec", nsec_data)

# Encode npub (5-bit groups of x-only pubkey)
npub_data = convertbits(list(xonly_pub), 8, 5, True)
npub = bech32_encode("npub", npub_data)
```

## Required dependency

`pip3 install secp256k1` (Python wheel — works on macOS arm64 via
homebrew openssl). For npub derivation specifically, you need the actual
EC math (not just `os.urandom`), so `coincurve` or `secp256k1` is
required. `bech32` is a pure-Python helper that you can inline (see
above) — it's not strictly required.

## Verified example output (jleechan, 2026-08-20)

```
npub10552ul0egapyh6fvm6xmumluhh29hm0gjy9qagf62ud3l4s0xg9qdky5ve
nsec102qc2tnltwy4kp25lseq47ppjrjmulwvr6gna50m8s64qyw3zhrs93esrl
```

## Storage pattern

Save to `~/.config/fediverse/nostr.json` with `chmod 600`:

```python
import json, time, os
path = os.path.expanduser("~/.config/fediverse/nostr.json")
with open(path, "w") as f:
    json.dump({
        "npub": npub,
        "nsec": nsec,
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "note": "IDENTITY-CRITICAL — chmod 600. Treat as irrecoverable."
    }, f, indent=2)
os.chmod(path, 0o600)
```

Also expose via the bashrc-sourced env-file pattern:

```bash
export FEDIVERSE_NOSTR_NPUB="npub10552ul0egapyh6fvm6xmumluhh29hm0gjy9qagf62ud3l4s0xg9qdky5ve"
```

The nsec stays in `nostr.json` only — do NOT export it to bashrc / env,
since `nsec` in shell history leaks the identity permanently.

## Print-once rule

Print the npub and nsec to the user EXACTLY ONCE in the Slack reply,
and tell them to back them up to a password manager immediately.
**Never re-print.** After the user has copied them, if they ask again,
point them at `~/.config/fediverse/nostr.json`.

## Where to publish

To make the npub reachable on the network, the user needs to publish at
least one event to one or more relays. Options:

- **Iris / Damus / Amethyst / Coracle** (mobile/web clients) — paste the
  nsec into the app, the client signs events and publishes to its
  default relays.
- **nak CLI** (`nak event publish` after `nak key import <nsec>`) — for
  headless workflows.
- **nos2x / Alby / KeyChat** browser extension — for web posting.

This is a USER step, not an agent step. The agent's job ends at "you
have a keypair and a npub; here's how to publish your first event."

## Anti-patterns (BANNED)

- ❌ Logging the nsec to console output beyond the print-once step
- ❌ Putting nsec in shell history (`$HISTFILE`) — always use `unset
  HISTFILE` before running ad-hoc scripts that touch it
- ❌ Committing nsec to ANY repo — even ephemeral / private ones
- ❌ Pasting nsec into a screenshot
- ❌ Echoing the JSON file via `cat` in shared terminals