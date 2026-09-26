#!/usr/bin/env bash
# Delete this project's container/volumes/image and rebuild the image from scratch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

# Per-project compose/volume prefix — must match the start scripts.
export COMPOSE_PROJECT_NAME="$(printf '%s' "${PROJECT_ROOT##*/}" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]_-' '-')-claude"

confirm() {
  local prompt="${1:-Proceed}"
  local reply
  while true; do
    read -rp "$prompt (y/n): " reply
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     echo "Please answer y or n." ;;
    esac
  done
}

pause() {
  read -rp "Press Enter to continue..." _
}

cancelled() {
  echo "Cancelled."
  pause
  exit 0
}

cat <<EOF
============================================================
 This will DELETE for this project ($COMPOSE_PROJECT_NAME):
   - the container
   - the image claude-dangerous:$COMPOSE_PROJECT_NAME
 then rebuild the image from scratch with --no-cache.

 The volumes (${COMPOSE_PROJECT_NAME}_claude-config / _claude-cache —
 Claude login/onboarding state and the browser cache) are OPTIONAL;
 you'll be asked separately whether to delete them.

 Note: the image and volumes are both per-project (tagged/prefixed with
 $COMPOSE_PROJECT_NAME), so this only affects this project.
============================================================
EOF
echo

confirm "Proceed" || cancelled

# --- Decide volume fate up front -----------------------------------------
echo
if confirm "Also DELETE the volumes (login/onboarding state + browser cache)?"; then
  DOWN_FLAGS=(-v)
  echo "Volumes WILL be deleted — you'll need to log in again after rebuild."
else
  DOWN_FLAGS=()
  echo "Volumes will be KEPT — login/onboarding state preserved across the rebuild."
fi

# --- Ensure Docker is running --------------------------------------------
if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running. Starting Docker Desktop..."
  DOCKER_DESKTOP="/mnt/c/Program Files/Docker/Docker/Docker Desktop.exe"
  if [[ ! -x "$DOCKER_DESKTOP" ]]; then
    echo "[ERROR] Docker Desktop not found at $DOCKER_DESKTOP. Start it manually and re-run."
    pause
    exit 1
  fi
  "$DOCKER_DESKTOP" >/dev/null 2>&1 &
  echo "Waiting for Docker to be ready..."
  until docker info >/dev/null 2>&1; do
    sleep 3
  done
fi

# --- Optional session backup ---------------------------------------------
echo
if confirm "Keep your sessions (back them up to .claude-sessions before deleting)"; then
  echo "Backing up sessions to .claude-sessions ..."
  docker compose run --rm claude bash -lc \
    'mkdir -p /workspace/.local/.claude-sessions; cd /home/node/.claude 2>/dev/null && for s in projects sessions session-env history.jsonl; do [ -e "$s" ] && cp -r "$s" /workspace/.local/.claude-sessions/; done; echo "Sessions backed up."'
  echo
  echo "Your sessions were copied to the .claude-sessions folder, now opening it."
  if command -v explorer.exe >/dev/null 2>&1; then
    explorer.exe "$(wslpath -w "$SCRIPT_DIR/.claude-sessions")" >/dev/null 2>&1 || true
  else
    echo "(explorer.exe not available — open $SCRIPT_DIR/.claude-sessions manually)"
  fi
  echo "Check that folder and confirm your sessions are actually there."
  echo "If it looks empty or wrong, choose No below — nothing has been deleted yet."
  echo
  confirm "Sessions verified — continue with the rebuild" || cancelled
fi

# --- Tear down + rebuild --------------------------------------------------
echo
if (( ${#DOWN_FLAGS[@]} > 0 )); then
  echo "[1/3] Removing containers and volumes..."
else
  echo "[1/3] Removing containers (keeping volumes)..."
fi
docker compose down "${DOWN_FLAGS[@]}"

echo "[2/3] Removing image claude-dangerous:$COMPOSE_PROJECT_NAME..."
docker rmi "claude-dangerous:$COMPOSE_PROJECT_NAME" >/dev/null 2>&1 || true

echo "[3/3] Rebuilding with --no-cache. This takes several minutes..."
if ! docker compose build --no-cache; then
  echo "[ERROR] Build failed."
  pause
  exit 1
fi

echo
echo "Done. Run ./start-claude-dangerously.sh or ./start-claude-normal.sh to launch Claude."
pause
