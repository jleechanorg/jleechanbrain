---
name: apple-network-diag
version: 0.2.0
description: "macOS WiFi + LAN diag, no sudo. CoreWLAN, OUI, gateway FP. Probe-before-refuse Step 0 hardens the lesson from the 2026-08-14 Rowan Trollope incident."
tags: ["apple", "macos", "wifi", "network", "corewlan", "lan", "diagnostics"]
category: apple
triggers:
  - check my wifi
  - scan my wifi
  - wifi survey
  - rssi
  - snr
  - what AP am I on
  - who's on my network
  - identify my router
  - home wifi audit
  - jitter
  - ping latency
changelog:
  - "0.2.0 (2026-08-14): Hardened probe-before-refuse into Step 0 (was a paragraph). Added scripts/wifi-jitter-baseline.sh (re-runnable before/after logging). Added references/rowan-trollope-wifi-thread-2026-08-14.md (full incident context + multi-vantage recipe + bead-creation pattern). Fixed KVC crash on `security` key in wifi_survey.swift (now guarded with responds(to:) + safeKvc helper)."
  - "0.1.0 (2026-08-14): Initial authoring from Rowan-Trollope-WiFi thread (Slack ${SLACK_CHANNEL_ID}/p1786619681). CoreWLAN via Swift+KVC recipe + LAN fingerprinting via gateway HTTP redirects (Frontier NVG468MQ: /cgi-bin/home.ha; OpenWrt/Araknis: /cgi-bin/luci)."
---

# apple-network-diag — WiFi + LAN diagnostics on macOS, no sudo

Every fact this skill produces is **measured**, not inferred. RSSI from `CoreWLAN`,
BSSID from `ipconfig getsummary en0`, manufacturers from MAC OUI lookup, router/AP
model from gateway HTTP redirect signatures.

This skill exists because of a 2026-08-14 Slack thread where the agent fabricated a
structural blocker ("I'm a Slack bot, no shell access") while sitting on full
terminal. The probe-before-refuse lesson is captured in `harness-postmortem`'s
working failure class table (`claimed-no-access-while-having-access`) — if you find
yourself about to claim you can't do WiFi work from a MacBook session, **stop and
probe first**. The full transcript context is in
`references/rowan-trollope-wifi-thread-2026-08-14.md`.

## When to load

- "Check my WiFi", "scan my network", "what channel am I on"
- "Why is my Mac slow on WiFi", "is the signal weak here", "jitter is bad today"
- "Who's connected to my router", "discover LAN devices"
- "Identify my router/AP model", "what firmware"
- "Open the router admin page" (LAN fingerprinting tells you what UI to drive)
- "Baseline my WiFi before I change settings" → use `scripts/wifi-jitter-baseline.sh`

## When NOT to load

- User wants to *change* settings on an AP (this skill only *reads*; for write-side use
  Playwright/Aside against the admin page after fingerprinting, or have the user paste creds).
- Linux/Windows hosts (Linux uses `nmcli`/`iwlist`; Windows uses `netsh wlan show`).
- Single-vantage readings CANNOT map whole-house coverage. The user walks the laptop;
  the agent diffs the outputs. See the multi-vantage recipe in
  `references/rowan-trollope-wifi-thread-2026-08-14.md`.

## Procedure (single-vantage WiFi + LAN survey)

Run in order. Each step feeds the next. **Do not skip Step 0.**

### Step 0 — Probe before you refuse (HARD GATE)

Before claiming any structural blocker ("no shell", "no admin access",
"can't read your network"), run the actual probe. The 2026-08-14 incident:
the agent refused 4 times in a row citing "no shell access" while having
`terminal` available the entire session.

Minimum probe:

```bash
uname -a; whoami; pwd
which airport swift networksetup 2>&1 | head -10
ls /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport 2>&1
```

If `terminal` is available, you have shell. The skill's later steps assume
you ran this and it printed something. If `terminal` is *not* available
(truly missing from your tool list), the response shape changes: report
exactly which tools are missing, do not invent a "Slack session" framing
that deflects responsibility.

**This is Step 0, not Step 1.** A refusal that skips Step 0 is the failure
class this skill exists to prevent.

### Step 1 — Identity + WiFi interface

Already covered by Step 0. Re-run only if the tool surface changed mid-task.

### Step 2 — Current WiFi association (RSSI / noise / SNR / BSSID)

The `airport` command is deprecated and returns empty data without sudo.
`system_profiler SPAirportDataType` returns nothing useful. **The Swift+KVC recipe
below is the only reliable way without sudo.**

```bash
swift ${HOME}/.smartclaw/skills/apple/apple-network-diag/scripts/wifi_survey.swift
```

The script outputs RSSI, noise, SNR (computed), Tx rate, country code, and a scan
table sorted by signal strength. Guard against the KVC crash on `security` (the
script's `safeKvc` helper handles it).

**How to read it:** RSSI > -60 = excellent, -60 to -75 = usable, -75 to -85 = marginal,
< -85 = unreliable. SNR > 25 dB = pristine, 15-25 = usable, < 15 = interference-limited.
Tx rate of 1200 Mbps with 80 MHz = Wi-Fi 6 max; 600 Mbps = Wi-Fi 5 80 MHz; lower =
narrower channel or weaker modulation.

### Step 2 — Current WiFi association (RSSI / noise / SNR / BSSID)

The `airport` command is deprecated and returns empty data without sudo.
`system_profiler SPAirportDataType` returns nothing useful. **The Swift+KVC recipe
below is the only reliable way without sudo.**

```bash
swift ${HOME}/.smartclaw/skills/apple-network-diag/scripts/wifi_survey.swift
```

The script outputs RSSI, noise, SNR (computed), Tx rate, country code, and a scan
table sorted by signal strength.

**How to read it:** RSSI > -60 = excellent, -60 to -75 = usable, -75 to -85 = marginal,
< -85 = unreliable. SNR > 25 dB = pristine, 15-25 = usable, < 15 = interference-limited.
Tx rate of 1200 Mbps with 80 MHz = Wi-Fi 6 max; 600 Mbps = Wi-Fi 5 80 MHz; lower =
narrower channel or weaker modulation.

### Step 2.5 — Jitter / latency baseline (when "feels slow today" is the symptom)

For before/after diffing around a config change, use:

```bash
bash ${HOME}/.smartclaw/skills/apple/apple-network-diag/scripts/wifi-jitter-baseline.sh <label>
```

Output: timestamped log file at `~/wifi-jitter/<ts>-<label>.log` containing:
20 ping samples to gateway + 20 to 1.1.1.1, single WiFi survey sample, 5× DNS
lookups. Always run *before* and *after* any AP config change; diff σ/avg/max.

The user can run this from the laptop — they do the physical walking, the
script handles the logging. See `references/rowan-trollope-wifi-thread-2026-08-14.md`
for the multi-vantage recipe that goes with it.

### Step 3 — Network layer (gateway, DNS, DHCP, WAN)

```bash
networksetup -getinfo Wi-Fi      # IP, mask, router, DNS, IPv6
ipconfig getpacket en0           # raw DHCP lease (vendor class ID, lease time)
netstat -rn | grep -E "default"  # default routes (incl. VPN tunnels)
ping -c 20 -i 0.2 <gateway-ip>   # latency + jitter; report min/avg/max/σ
nslookup google.com              # DNS latency (cache miss vs hit)
```

The DHCP packet's option 125 (vendor-specific) often contains the ISP modem serial —
useful for ISP support tickets. The vendor-class-identifier (option 60) tells you
"Frontier NVG468MQ" or similar.

### Step 4 — LAN host discovery

```bash
arp -an | grep -v "<your-ip>"    # ARP cache: every host you've talked to recently
```

For a full subnet sweep:

```bash
for i in $(seq 1 254); do
  (ping -c 1 -W 1 192.168.254.$i | grep "bytes from" &)
done
wait
arp -an | grep "192.168.254"
```

### Step 5 — Identify each device (OUI lookup)

The first 3 bytes of a MAC are the OUI. Free lookup: `https://api.macvendors.com/<mac>`
(no key needed). Batch:

```bash
arp -an | awk '{print $4}' | tr -d '()' | sort -u | while read mac; do
  vendor=$(curl -sm 3 "https://api.macvendors.com/$mac" 2>/dev/null)
  printf "%-20s %s\n" "$mac" "$vendor"
done
```

Common OUIs you'll see on a home LAN:
- `40:2b:50` → Arris (Frontier NVG-series ONTs)
- `f0:f6:c1` → Netgear (Araknis APs are rebranded Netgear)
- `14:3f:c3` → Actiontec (older Araknis/Actiontec gear)
- `48:a6:b8` → Sonos
- `54:e0:19` → Ring (cameras)
- `64:16:66` / `18:b4:30` → Nest

### Step 6 — Router/AP fingerprinting via gateway HTTP

```bash
GW=$(netstat -rn | awk '/^default/ {print $2; exit}')

for p in 80 443 8080 8443 1900 5555 8008 8888; do
  timeout 2 bash -c "echo > /dev/tcp/$GW/$p" 2>/dev/null && echo "  $p OPEN"
done

curl -sk -m 5 "http://$GW/" 2>&1 | head -5
curl -sk -m 5 "https://$GW/" 2>&1 | head -5
```

**Signature → vendor mapping** (curated from real probes):

| Root redirect | Vendor | Admin path |
|---|---|---|
| `<meta http-equiv=Refresh content=0;url=/cgi-bin/home.ha>` | Frontier NVG468MQ (Actiontec ONT) | `https://<gw>/cgi-bin/home.ha` |
| `<meta http-equiv=Refresh content=0;url=/cgi-bin/luci>` | OpenWrt / LuCI (Araknis 820, generic) | `https://<ap>/cgi-bin/luci` |
| `/admin/` redirect or Ubiquiti title | UniFi (UDM, UDM-Pro) | `https://<gw>/manage/account/login` |
| Title `eero` | eero | cookie-auth API, no easy CLI |
| 401 with `WWW-Authenticate: Basic` | Generic OpenWrt | `http://<gw>/cgi-bin/luci` |
| Title contains `ARRIS` / `SURFboard` | Arris SURFboard | `https://<gw>/` |

### Step 7 — Per-AP scan (only if APs are on different IPs)

```bash
for ip in <ap1> <ap2> <ap3>; do
  echo "--- $ip ---"
  curl -sk -m 4 "https://$ip/cgi-bin/luci" 2>&1 | grep -iE "(title|version)" | head -3
done
```

**Do NOT log in without creds.** Probing the redirect signature is fine;
`curl -X POST` with guessed passwords is not.

## Pitfalls

1. **`airport -s` returns empty without sudo** (and emits a deprecation warning).
   Don't use it for neighbor scan.
2. **KVC keys collide with NSObject properties.** `iface.rssiValue()` doesn't compile
   in Swift — use `iface.value(forKey: "rssiValue")`. The reference script has it right.
3. **Single-vantage ≠ whole-house survey.** This skill measures ONE position. To map
   coverage, the user walks the laptop and re-runs the script; the agent diffs output.
   Don't claim whole-house coverage from one seat.
4. **macOS Location Services can block scan** (`scanForNetworks` returns nil with err
   "Location Services denied"). One ask to the user: enable Location for Terminal in
   System Settings → Privacy & Security. Don't loop.
5. **Swift compile is slow first time** (~6s). Amortize with `swiftc -o /tmp/wifi`
   if speed matters.
6. **Channel 165 is DFS.** Stick to UNII-1 (36-48), UNII-3 (149-165), or UNII-4
   (169-177). DFS channels (52-144) cause APs to vacate on radar hits.
7. **macOS private MAC is default.** `networksetup -getmacaddress Wi-Fi` returns the
   rotating private MAC. For hardware MAC: `networksetup -gethardwareportinfo en0`
   or `ifconfig en0 | grep ether`.
8. **Don't try to log into admin UI without creds.** Probe redirect signature, wait
   for user.

## Test recipe

```bash
swift ${HOME}/.smartclaw/skills/apple-network-diag/scripts/wifi_survey.swift
# Expected: RSSI/Noise/SNR/Tx lines + a scan block with ≥1 network
```

If `swift` is missing: `xcode-select --install` (Command Line Tools, not full Xcode).

## Related skills / files

- **`harness-postmortem`** — if you find yourself claiming "no shell access", STOP
  and load this first. The 2026-08-14 incident in this skill is failure class
  FC1 (`claimed-no-access-while-having-access`).
- **`references/rowan-trollope-wifi-thread-2026-08-14.md`** — full transcript
  context, multi-vantage survey recipe, bead-creation pattern, Me/You owner
  matrix. Read this before filing WiFi beads.
- **`scripts/wifi-jitter-baseline.sh`** — re-runnable before/after logging for
  jitter/latency/RSSI. Logs to `~/wifi-jitter/<ts>-<label>.log`.
- **`scripts/wifi_survey.swift`** — single-vantage survey script (CoreWLAN, no sudo).
- **`aside-browser-default`** — for driving the router admin UI after fingerprinting.
- **`macos-computer-use`** — only when the admin UI can't be reached from terminal.

## Changelog

See YAML frontmatter. Latest: 0.1.0 (2026-08-14).