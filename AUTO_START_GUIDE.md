# Hermes Auto-Start Configuration Guide

**Last Updated:** 2026-02-13
**Hermes Version:** v2026.2.12
**macOS Configuration:** Complete ✅

---

## 🚧 Scheduling Guardrail

- **Forbidden:** system `crontab` edits for Hermes reminder/scheduling jobs.
- **Required:** Hermes gateway cron workflow only (`hermes cron ...`).

---

## ✅ What's Configured

### 1. **Primary Auto-Start: LaunchAgent**
- **File:** `~/Library/LaunchAgents/ai.smartclaw.prod.plist`
- **RunAtLoad:** `true` ← Starts automatically on macOS boot
- **KeepAlive:** `true` ← Automatically restarts if crashes
- **Current Status:** Loaded and running (PID: XXXXX)

### 2. **Startup Verification: LaunchAgent**
- **File:** `~/Library/LaunchAgents/ai.smartclaw.startup-check.plist`
- **Purpose:** Sends WhatsApp confirmation after each login/restart
- **Sends message to:** `HERMES_WHATSAPP_TARGET`
- **Logs:** `~/.smartclaw/logs/startup-check.log`

### 3. **Health Monitoring: Hermes Gateway Cron**
- **Schedule:** Every 5 minutes
- **Script:** `~/.smartclaw/health-check.sh`
- **Purpose:** Monitors gateway health and auto-recovery if needed via Hermes gateway cron jobs
- **Logs:** `~/.smartclaw/logs/health-check.log`

---

## 🔍 How to Verify After Restart

### Test 1: Check LaunchAgent Status
```bash
launchctl list | grep hermes
```
**Expected Output:**
```text
[PID]  0  ai.smartclaw.prod
[PID]  0  ai.smartclaw.startup-check
```

### Test 2: Check Gateway Status
```bash
hermes gateway status
```
**Expected Output:**
```text
Runtime: running (pid XXXXX)
RPC probe: ok
```

### Test 3: Check WhatsApp Connection
```bash
hermes channels list
```
**Expected Output:**
```text
WhatsApp default: linked, enabled
```

### Test 4: Check WhatsApp (You'll Receive a Message!)
After each restart/login, you should receive confirmation if `HERMES_WHATSAPP_TARGET` is set:
> 🚀 Hermes auto-started successfully (PID: XXXXX) ✅

---

## 📊 Monitoring & Logs

### View Real-Time Gateway Logs
```bash
hermes logs --follow
```

### View Health Check Results
```bash
tail -f ~/.smartclaw/logs/health-check.log
```

### View Startup Check Results
```bash
tail -f ~/.smartclaw/logs/startup-check.log
```

### Check Gateway Cron Configuration
```bash
hermes cron status
hermes cron list
```

---

## 🔧 Manual Controls

### Start Gateway
```bash
hermes gateway start
# OR
hermes gateway install
```

### Stop Gateway
```bash
hermes gateway stop
```

### Restart Gateway
```bash
hermes gateway stop && sleep 2 && hermes gateway install
```

### Force Reload LaunchAgent
```bash
launchctl unload ~/Library/LaunchAgents/ai.smartclaw.prod.plist
launchctl load ~/Library/LaunchAgents/ai.smartclaw.prod.plist
```

### Run Health Check Manually
```bash
~/.smartclaw/health-check.sh
```

---

## 🚨 Troubleshooting

### Gateway Not Starting After Restart

1. **Check if LaunchAgent is loaded:**
   ```bash
   launchctl list | grep hermes
   ```

2. **If not loaded, load manually:**
   ```bash
   launchctl load ~/Library/LaunchAgents/ai.smartclaw.prod.plist
   ```

3. **Check for errors:**
   ```bash
   tail -50 ~/.smartclaw/logs/gateway.err.log
   ```

### WhatsApp Disconnected

1. **Check status:**
   ```bash
   hermes channels list
   ```

2. **Relink if needed:**
   ```bash
   hermes channels login --channel whatsapp --account default
   ```
   Scan QR code within 60 seconds.

### Health Check Not Running

1. **Verify gateway cron jobs:**
   ```bash
   hermes cron status
   hermes cron list
   ```

2. **Test health check manually:**
   ```bash
   ~/.smartclaw/health-check.sh && echo "Exit code: $?"
   ```

3. **Inspect gateway logs for cron execution details:**
   ```bash
   hermes logs --follow
   ```

---

## 📁 File Locations

| Component | Location |
|-----------|----------|
| **Main Gateway LaunchAgent** | `~/Library/LaunchAgents/ai.smartclaw.prod.plist` |
| **Startup Check LaunchAgent** | `~/Library/LaunchAgents/ai.smartclaw.startup-check.plist` |
| **Health Check Script** | `~/.smartclaw/health-check.sh` |
| **Startup Check Script** | `~/.smartclaw/startup-check.sh` |
| **Gateway Logs** | `~/.smartclaw/logs/gateway.log` |
| **Gateway Error Logs** | `~/.smartclaw/logs/gateway.err.log` |
| **Health Check Logs** | `~/.smartclaw/logs/health-check.log` |
| **Startup Check Logs** | `~/.smartclaw/logs/startup-check.log` |
| **Configuration** | `~/.smartclaw/config.yaml` |

---

## 🎯 Quick Health Status

Run this one-liner for a complete health check:
```bash
echo "=== Hermes Health Status ===" && \
launchctl list | grep hermes && \
echo "" && hermes gateway status && \
echo "" && hermes channels list
```

---

## ✅ Configuration Summary

✅ **LaunchAgent installed** with RunAtLoad=true, KeepAlive=true
✅ **Startup verification** configured (sends WhatsApp confirmation)
✅ **Health monitoring** via Hermes gateway cron (every 5 minutes)
✅ **WhatsApp notification** configured via `HERMES_WHATSAPP_TARGET`
✅ **Auto-recovery** enabled (restarts on crash)
✅ **Version:** v2026.2.12 (latest)

**Next Restart:** You will receive a WhatsApp message confirming Hermes started successfully if `HERMES_WHATSAPP_TARGET` is set. 🚀

---

*Generated by Hermes Auto-Configuration System*
