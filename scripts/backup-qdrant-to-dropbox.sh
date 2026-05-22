#!/usr/bin/env bash
# Backup qdrant_storage/ to Dropbox so it survives WAL corruption or Docker loss.
# Run nightly via cron or launchd. Keeps last 7 daily backups.
#
# Source: ~/.smartclaw/scripts/backup-qdrant-to-dropbox.sh
# Dest:   ~/Dropbox/local/qdrant-backups/YYYY-MM-DD/

set -euo pipefail

CONTAINER="${QDRANT_CONTAINER:-openclaw-mem0-qdrant}"
CONTAINER_SRC="/qdrant/storage"
STAGING="${HOME}/.smartclaw/qdrant_storage_staging"
DEST_ROOT="${HOME}/Dropbox/local/qdrant-backups"
DATE=$(date +%Y-%m-%d)
DEST="${DEST_ROOT}/${DATE}"
KEEP_DAYS=7

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "ERROR: container $CONTAINER not found or not running" >&2
  exit 1
fi

mkdir -p "$DEST_ROOT"

# Clear staging before extracting — docker cp only overlays files,
# it does not remove stale entries from prior runs (deleted WAL segments etc.)
rm -rf "$STAGING"
mkdir -p "$STAGING"

# Extract from container into staging dir, then rsync to Dropbox
docker cp "${CONTAINER}:${CONTAINER_SRC}/." "$STAGING/"

# Incremental copy using rsync (fast if little changed)
rsync -a --delete "$STAGING/" "$DEST/"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) backed up ${CONTAINER}:${CONTAINER_SRC} → $DEST"

# Prune backups older than KEEP_DAYS (macOS-compatible)
mapfile -t ALL_BACKUPS < <(find "$DEST_ROOT" -maxdepth 1 -type d -name "????-??-??" | sort)
TOTAL=${#ALL_BACKUPS[@]}
if (( TOTAL > KEEP_DAYS )); then
  REMOVE=$(( TOTAL - KEEP_DAYS ))
  for ((i=0; i<REMOVE; i++)); do
    rm -rf "${ALL_BACKUPS[$i]}"
  done
fi

echo "Kept last ${KEEP_DAYS} backups in ${DEST_ROOT}:"
ls "$DEST_ROOT"
