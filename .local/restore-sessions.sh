#!/usr/bin/env bash
# Copy backed-up sessions from .local/.claude-sessions into the container volume.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

# Per-project compose/volume prefix — must match the start scripts.
export COMPOSE_PROJECT_NAME="$(printf '%s' "${PROJECT_ROOT##*/}" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]_-' '-')-claude"

pause() { read -rp "Press Enter to continue..." _; }

if [[ ! -d "$SCRIPT_DIR/.claude-sessions" ]]; then
  echo "[ERROR] No .claude-sessions folder found in $SCRIPT_DIR"
  echo "Run rebuild-claude.sh and choose to keep your sessions to create one."
  pause
  exit 1
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

echo "Copying sessions into the container volume..."
docker compose run --rm claude bash -lc \
  'cp -r /workspace/.local/.claude-sessions/. /home/node/.claude/ && echo "Sessions copied into the container."'

RESUME_PROMPT="Look in /home/node/.claude/projects/ for the most recent .jsonl transcript, read it, and continue our previous session from where we left off."

if command -v clip.exe >/dev/null 2>&1; then
  printf '%s' "$RESUME_PROMPT" | clip.exe
  CLIPBOARD_NOTE="a resume prompt has been copied to your Windows clipboard."
else
  CLIPBOARD_NOTE="copy the prompt below manually (clip.exe not available)."
fi

cat <<EOF

============================================================
 Sessions copied into the container.

 Claude's built-in --resume may not list a restored session,
 so $CLIPBOARD_NOTE

 Next steps:
   1. Run ./start-claude-dangerously.sh or ./start-claude-normal.sh.
   2. When Claude is ready, paste the prompt with Ctrl+V and send it.

 The prompt:
 $RESUME_PROMPT
============================================================
EOF
pause
