#!/usr/bin/env bash
# docker compose wrapper that pins COMPOSE_PROJECT_NAME to the same per-project
# slug used by the start-claude-*.sh scripts.
# Use this for any compose op (up/down/logs/ps) so everything shares one network.
#
# Examples:
#   ./.local/compose.sh up -d db wordpress
#   ./.local/compose.sh logs -f wordpress
#   ./.local/compose.sh ps
#   ./.local/compose.sh down
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export COMPOSE_PROJECT_NAME="$(printf '%s' "${PROJECT_ROOT##*/}" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]_-' '-')-claude"

# Host identity for the wordpress container's www-data remap (so Apache can
# write bind-mounted files without changing host ownership).
export HOST_UID="$(id -u)"
export HOST_GID="$(id -g)"

exec docker compose -f "$SCRIPT_DIR/docker-compose.yml" "$@"
