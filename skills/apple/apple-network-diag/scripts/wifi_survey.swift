// apple-network-diag — WiFi survey via CoreWLAN
// Usage: swift ${HOME}/.smartclaw/skills/apple/apple-network-diag/scripts/wifi_survey.swift
// No sudo required. macOS 13+ recommended (Location Services prompt on first scan).
//
// IMPORTANT: this file MUST be on disk before invoking `swift` — `swift` requires
// a file path, not stdin. Also note the KVC pitfalls:
//   - `iface.rssiValue()` does NOT compile in Swift (collides with NSObject's `value`)
//   - Use `iface.value(forKey: "rssiValue")` for rssi/noise/ssid/bssid/wlanChannel
//   - **`security` is NOT a valid KVC key** — accessing it throws
//     `NSUnknownKeyException` and aborts the whole script. Use try/catch via the
//     `respondsToSelector`+`perform(_:)` pattern, or just omit it (verified 2026-08-14).
//   - The `wlanChannel` is an NSObject too; `channelNumber` is accessed via KVC

import Foundation
import CoreWLAN

let client = CWWiFiClient.shared()
guard let iface = client.interface() else {
    print("no interface")
    exit(1)
}

// Helper for safe KVC: returns nil instead of throwing on missing keys.
// We need this because `value(forKey:)` throws NSUnknownKeyException for
// keys that the framework declares but does not implement (e.g. "security").
func safeKvc(_ obj: NSObject, _ key: String) -> Any? {
    if obj.responds(to: NSSelectorFromString(key)) {
        return obj.value(forKey: key)
    }
    return nil
}

// --- Current association ---
let ifaceSsid = safeKvc(iface, "ssid") as? String ?? "nil"
let ifaceBssid = safeKvc(iface, "bssid") as? String ?? "nil"
let ifaceRssi = safeKvc(iface, "rssiValue") as? Int ?? 0
let ifaceNoise = safeKvc(iface, "noise") as? Int ?? 0
let ifaceTx = iface.transmitRate()
let ifaceCountry = iface.countryCode() ?? "nil"
// Security — guarded separately so a framework bug never kills the script.
let ifaceSec: String = {
    if iface.responds(to: NSSelectorFromString("security")) {
        // CWInterface exposes `security` as a property (CWSecurity type); not KVC.
        // Use perform(_:) to retrieve without compile-time dependence on the type.
        let result = iface.perform(NSSelectorFromString("security"))
        return (result?.takeUnretainedValue() as? String) ?? "?"
    }
    return "?"
}()

print("SSID:        \(ifaceSsid)")
print("BSSID:       \(ifaceBssid)")
print("RSSI:        \(ifaceRssi) dBm")
print("Noise:       \(ifaceNoise) dBm")
if ifaceNoise != 0 { print("SNR:         \(ifaceRssi - ifaceNoise) dB") }
print("Tx Rate:     \(ifaceTx) Mbps")
print("Country:     \(ifaceCountry)")
print("Security:    \(ifaceSec)")

// --- Neighbor scan ---
do {
    let networks: Set<CWNetwork> = try iface.scanForNetworks(withSSID: nil)
    let arr = Array(networks).sorted { (a: CWNetwork, b: CWNetwork) -> Bool in
        let ar = safeKvc(a, "rssiValue") as? Int ?? 0
        let br = safeKvc(b, "rssiValue") as? Int ?? 0
        return ar > br
    }
    print("\n=== Scan: \(arr.count) networks ===")
    for n in arr.prefix(40) {
        let ssidStr = (safeKvc(n, "ssid") as? String) ?? "<hidden>"
        let bssidStr = (safeKvc(n, "bssid") as? String) ?? "?"
        let rssi = safeKvc(n, "rssiValue") as? Int ?? 0
        var chanNum = 0
        if let ch = safeKvc(n, "wlanChannel") as? NSObject,
           ch.responds(to: NSSelectorFromString("channelNumber")) {
            chanNum = ch.value(forKey: "channelNumber") as? Int ?? 0
        }
        let padCount = max(0, 30 - ssidStr.count)
        let padded = ssidStr + String(repeating: " ", count: padCount)
        print("  \(rssi) dBm  ch=\(chanNum)  \(padded)  BSSID=\(bssidStr)")
    }
} catch {
    print("scan err: \(error)")
    print("(if Location Services are denied for Terminal/iTerm, the scan will fail")
    print(" but current-association data above is still valid. Fix: System Settings")
    print(" → Privacy & Security → Location Services → enable for Terminal.)")
}

// --- AirPort info (deprecated + needs sudo; informational only) ---
let airportPath = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
if FileManager.default.isExecutableFile(atPath: airportPath) {
    print("\n--- airport -I hint ---")
    print("Run: sudo \(airportPath) -I    # current association + agrCtlRSSI/RATE/NOISE")
    print("     sudo \(airportPath) -s    # neighbor scan (full, requires sudo)")
}