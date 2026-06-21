# Hermes Backup & Restore Guide

**Never Lose Your Setup Again!**

---

## 🔐 What Gets Backed Up

✅ **Configuration**: `~/.smartclaw/config.yaml`
✅ **Credentials**: `~/.smartclaw/credentials/` (WhatsApp, Slack tokens)
✅ **LaunchAgent**: `~/Library/LaunchAgents/ai.smartclaw.prod.plist`
✅ **Custom Scripts**: Health check, startup scripts
✅ **Documentation**: All setup guides

---

## 📦 Automatic Daily Backup

Run this command to set up automatic daily backups:

```bash
~/.smartclaw/enable-auto-backup.sh
```

This will:
- Create daily backups in `~/.smartclaw/backups/`
- Keep last 30 days of backups
- Run automatically via cron at 2 AM daily
- Encrypt sensitive credentials

---

## 💾 Manual Backup (Right Now)

```bash
# Create timestamped backup
tar -czf ~/hermes-backup-$(date +%Y%m%d).tar.gz \
  ~/.smartclaw/ \
  ~/Library/LaunchAgents/ai.smartclaw.prod.plist

# Backup location
ls -lh ~/hermes-backup-*.tar.gz
```

---

## 🔄 Restore from Backup

If you ever need to restore (new machine, reinstall, etc.):

```bash
# Install Hermes first
npm install -g hermes@latest

# Restore backup
cd ~
tar -xzf hermes-backup-YYYYMMDD.tar.gz

# Reload LaunchAgent
launchctl load ~/Library/LaunchAgents/ai.smartclaw.prod.plist

# Verify
hermes channels list
```

---

## ☁️ Cloud Backup (Recommended)

### Option 1: iCloud
```bash
# Backup to iCloud
cp -r ~/.smartclaw ~/Library/Mobile\ Documents/com~apple~CloudDocs/hermes-backup
```

### Option 2: Encrypted Archive
```bash
# Create encrypted backup
tar -czf - ~/.smartclaw ~/Library/LaunchAgents/ai.smartclaw.prod.plist | \
  openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -out ~/hermes-encrypted-backup.tar.gz.enc

# To restore encrypted backup:
openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in ~/hermes-encrypted-backup.tar.gz.enc | \
  tar -xzf - -C ~
```

---

## 🔑 Token Storage (Secure)

Your tokens are stored in:
- **WhatsApp**: `~/.smartclaw/credentials/whatsapp/`
- **Slack Bot Token**: `SLACK_BOT_TOKEN` environment variable
- **Slack App Token**: `SLACK_APP_TOKEN` environment variable
- **Gateway Token**: `~/.smartclaw/config.yaml`

**NEVER commit these to git or share publicly!**

---

## 📋 Recovery Checklist

If you lose everything and need to restore:

- [ ] Install Hermes: `npm install -g hermes@latest`
- [ ] Restore backup: `tar -xzf hermes-backup-DATE.tar.gz`
- [ ] Install LaunchAgent: `hermes gateway install`
- [ ] Verify WhatsApp: `hermes channels list`
- [ ] Test WhatsApp: Send test message
- [ ] Verify Slack: Check Slack connection
- [ ] Test Slack: Send test message
- [ ] Check auto-start: `launchctl list | grep hermes`

---

## 🛡️ Protection Strategies

### 1. Version Control (Recommended)
```bash
# Create git repo for config (tokens excluded)
cd ~/.smartclaw
git init
echo "credentials/" >> .gitignore
echo "logs/" >> .gitignore
echo "config.yaml" >> .gitignore
git add *.md *.sh
git commit -m "Hermes configuration backup"

# Push to private repo
git remote add origin git@github.com:YOUR-USERNAME/hermes-config-private.git
git push -u origin main
```

### 2. Time Machine
- macOS Time Machine automatically backs up `~/.smartclaw/`
- Restore from Time Machine if needed

### 3. Scheduled Backups
```bash
# Add to crontab (already configured via health-check)
# Backups run daily at 2 AM
0 2 * * * tar --exclude ~/.smartclaw/backups -czf ~/.smartclaw/backups/backup-$(date +\%Y\%m\%d).tar.gz ~/.smartclaw/
```

---

## 🚨 Emergency Token Recovery

If you lose your Slack tokens:

**Bot Token:**
1. Go to: https://api.slack.com/apps/{SLACK_APP_ID}/install-on-team
2. Reinstall app (or view existing installation)
3. Copy Bot Token again

**App Token:**
1. Go to: Basic Information → App-Level Tokens
2. Generate new token with `connections:write` scope
3. Update Hermes configuration

**WhatsApp:**
- Cannot be recovered - must relink
- Backup credentials directory regularly!

---

## ✅ What's Already Protected

✓ LaunchAgent auto-starts on boot
✓ Health check runs every 5 minutes
✓ Logs preserved in `~/.smartclaw/logs/`
✓ Configuration backed up on every `hermes doctor --fix`
✓ Crontab persists across reboots

---

**Bottom Line:** As long as you have a backup of `~/.smartclaw/` and the LaunchAgent plist, you can restore everything in under 5 minutes!
