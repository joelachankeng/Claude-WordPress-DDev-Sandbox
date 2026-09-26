#!/usr/bin/env bash
# Launch Claude Code inside the sandbox container with permission prompts active.
# Uses `docker compose run` so the container joins the project network and can
# reach the db / wordpress services by hostname.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

# Per-project compose/volume prefix derived from the parent dir name.
export COMPOSE_PROJECT_NAME="$(printf '%s' "${PROJECT_ROOT##*/}" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]_-' '-')-claude"

"$SCRIPT_DIR/prune-playwright-mcp.sh" || true

# Build this project's own image if it's missing, or if the Dockerfile has been
# edited since the image was built (so Dockerfile changes never silently no-op).
IMAGE="claude-dangerous:${COMPOSE_PROJECT_NAME}"
needs_build=0
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Image $IMAGE not found — building..."
  needs_build=1
else
  img_epoch="$(date -d "$(docker image inspect -f '{{.Created}}' "$IMAGE")" +%s 2>/dev/null || echo 0)"
  dockerfile_epoch="$(stat -c %Y Dockerfile 2>/dev/null || echo 0)"
  if (( dockerfile_epoch > img_epoch )); then
    echo "Dockerfile is newer than $IMAGE — rebuilding..."
    needs_build=1
  fi
fi
if (( needs_build )); then
  docker compose build claude
fi

exec docker compose run --rm claude \
  claude --mcp-config /workspace/.local/.mcp.json
