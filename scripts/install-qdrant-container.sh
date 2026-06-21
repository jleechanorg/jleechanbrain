#!/usr/bin/env bash
# Create or verify the hermes-mem0-qdrant Docker container.
# Idempotent: skips creation if container already exists.
# Storage is persisted at ~/.smartclaw/qdrant_storage/
set -euo pipefail

CONTAINER="hermes-mem0-qdrant"
IMAGE="qdrant/qdrant:latest"
STORAGE_DIR="${HOME}/.smartclaw/qdrant_storage"
HOST_PORT=6333
DOCKER_BIN="${DOCKER_BIN:-docker}"

docker_cmd() {
  if [[ -n "${HERMES_QDRANT_DOCKER_CONTEXT:-}" ]]; then
    "$DOCKER_BIN" --context "$HERMES_QDRANT_DOCKER_CONTEXT" "$@"
  else
    "$DOCKER_BIN" "$@"
  fi
}

if docker_cmd ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "  ✓ container '${CONTAINER}' already exists (skipping create)"
  # A container created without --restart stays dead after exit 255 / Docker
  # restart / reboot, taking mem0 offline. Apply the policy to the existing
  # container too so previously-created containers also auto-restart.
  if docker_cmd update --restart unless-stopped "$CONTAINER" >/dev/null 2>&1; then
    echo "  ✓ applied --restart unless-stopped to existing '${CONTAINER}'"
  else
    echo "  ⚠ failed to apply --restart unless-stopped to existing '${CONTAINER}' (continuing)" >&2
  fi
else
  mkdir -p "$STORAGE_DIR"
  docker_cmd pull "$IMAGE"
  # --restart unless-stopped: a container created without a restart policy stays
  # dead after exit 255 / Docker restart / reboot, taking mem0 offline.
  docker_cmd create \
    --name "$CONTAINER" \
    --restart unless-stopped \
    -p "${HOST_PORT}:6333" \
    -v "${STORAGE_DIR}:/qdrant/storage" \
    "$IMAGE"
  echo "  ✓ container '${CONTAINER}' created with storage at ${STORAGE_DIR}"
fi

# Start it now
docker_cmd start "$CONTAINER" >/dev/null
echo "  ✓ ${CONTAINER} running on port ${HOST_PORT}"
