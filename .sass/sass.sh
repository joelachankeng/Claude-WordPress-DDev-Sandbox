#!/usr/bin/env bash
# sass.sh — compile or watch SCSS using .sass/SASS.settings.json.
#
# Works in two contexts:
#   * From the host (WSL shell): spins up the `sass` compose service (defined
#     in .local/docker-compose.yml) and runs the node runner inside it.
#   * From inside the claude container (e.g. when Claude calls this script):
#     runs the node runner directly — sass/postcss/autoprefixer are already
#     baked into the image, so no docker call is needed.
#
# Usage:
#   ./.sass/sass.sh compile      # compile every entry once, exit
#   ./.sass/sass.sh watch        # initial compile + watch for .scss changes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$PROJECT_ROOT/.local"

MODE="${1:-}"
case "$MODE" in
  compile|watch) ;;
  ""|-h|--help|help)
    cat <<EOF
sass.sh — compile or watch SCSS using .sass/SASS.settings.json

Usage:
  $(basename "$0") compile     Compile every entry once, exit non-zero on any failure.
  $(basename "$0") watch       Compile once, then watch input paths for changes.

Settings:
  .sass/SASS.settings.json (gitignored; copy .sass/SASS.settings.example.json to start)
EOF
    exit 0
    ;;
  *)
    echo "[sass.sh] Unknown mode: $MODE (expected 'compile' or 'watch')" >&2
    exit 2
    ;;
esac

# In-container shortcut: if we're already inside a docker container that has
# node + sass available, just run the node runner directly.
if [[ -f /.dockerenv ]] && command -v node >/dev/null 2>&1 && [[ -d /workspace/.sass ]]; then
  exec node /workspace/.sass/sass-runner.js "$MODE"
fi

# Otherwise we're on the host: use docker compose to run the sass service.
if ! command -v docker >/dev/null 2>&1; then
  echo "[sass.sh] docker not found. Install Docker Desktop or run this from inside the claude container." >&2
  exit 2
fi

# Per-project COMPOSE_PROJECT_NAME — must match the start scripts & compose.sh.
export COMPOSE_PROJECT_NAME="$(printf '%s' "${PROJECT_ROOT##*/}" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]_-' '-')-claude"

# Make sure the shared image exists before docker compose tries to use it.
if ! docker image inspect claude-dangerous:latest >/dev/null 2>&1; then
  echo "[sass.sh] Image claude-dangerous:latest not found — building..."
  ( cd "$COMPOSE_DIR" && docker compose --profile sass build sass )
fi

exec docker compose -f "$COMPOSE_DIR/docker-compose.yml" --profile sass run --rm sass \
  node /workspace/.sass/sass-runner.js "$MODE"
