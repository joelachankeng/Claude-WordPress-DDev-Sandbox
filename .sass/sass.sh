#!/usr/bin/env bash
# sass.sh — compile or watch SCSS using .sass/SASS.settings.json.
#
# The compile itself always happens in the DDEV web container, which is where
# the pinned toolchain lives (sass/postcss/autoprefixer, installed by
# .ddev/web-build/Dockerfile and found through NODE_PATH). The script works from
# either side of the container boundary:
#
#   * From the host: hands off with `ddev exec`.
#   * From inside the web container (`ddev ssh`): runs the node runner directly.
#
# Usage:
#   ./.sass/sass.sh compile      # compile every entry once, exit
#   ./.sass/sass.sh watch        # initial compile + watch for .scss changes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# --- Already inside the DDEV web container: run the runner directly. ---------
# NODE_PATH is baked into the image by .ddev/web-build/Dockerfile, but set it
# explicitly as a fallback so this still works if the environment is stripped
# (cron, a bare `docker exec`, etc).
if [[ "${IS_DDEV_PROJECT:-}" == "true" ]]; then
  export NODE_PATH="${NODE_PATH:-/usr/local/lib/sandbox-sass/node_modules}"
  exec node "$PROJECT_ROOT/.sass/sass-runner.js" "$MODE"
fi

# --- On the host: hand off to the web container. -----------------------------
if ! command -v ddev >/dev/null 2>&1; then
  echo "[sass.sh] ddev not found on PATH." >&2
  echo "          Install DDEV, or run this from inside the web container (ddev ssh)." >&2
  exit 2
fi

cd "$PROJECT_ROOT"

if [[ ! -f .ddev/config.yaml ]]; then
  echo "[sass.sh] No .ddev/config.yaml in $PROJECT_ROOT." >&2
  echo "          Configure the project first: .local/site-control.sh option 1." >&2
  exit 2
fi

# `ddev exec` fails fast on a stopped project rather than starting one, so say
# something useful instead of leaking its error.
if ! ddev exec true >/dev/null 2>&1; then
  echo "[sass.sh] The DDEV site isn't running. Start it with 'ddev start'" >&2
  echo "          (or .local/site-control.sh option 1) and try again." >&2
  exit 2
fi

# In watch mode Ctrl+C has to reach node inside the container. `ddev exec`
# forwards SIGINT to the process it started, so watch mode stops cleanly.
#
# $MODE is interpolated into the command string rather than passed as a positional
# argument: `ddev exec` joins everything it is given into a single shell string,
# so a trailing `-- "$MODE"` never arrives as $1 inside the container. This is
# safe because the case statement at the top has already narrowed $MODE to the
# literal "compile" or "watch". NODE_PATH and DDEV_APPROOT are escaped so they
# expand in the container, not here.
exec ddev exec bash -c \
  "export NODE_PATH=\"\${NODE_PATH:-/usr/local/lib/sandbox-sass/node_modules}\"; exec node \"\$DDEV_APPROOT/.sass/sass-runner.js\" $MODE"
