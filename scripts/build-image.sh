#!/bin/bash
# Build and push all OpenClaw container images to ACR.
# Usage: build-image.sh <acr-name>
set -euo pipefail

ACR_NAME="${1:?Usage: build-image.sh <acr-name>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Building openclaw-agent image ==="
az acr build --registry "$ACR_NAME" --image openclaw-agent:latest "$ROOT_DIR/docker/"

echo "=== Building persist-sync sidecar image ==="
az acr build --registry "$ACR_NAME" --image persist-sync:latest "$ROOT_DIR/docker/persist-sync/"

echo "=== Building openclaw-admin image ==="
az acr build --registry "$ACR_NAME" --image openclaw-admin:latest "$ROOT_DIR/admin/"

echo "=== Done ==="
az acr repository list --name "$ACR_NAME" -o table
