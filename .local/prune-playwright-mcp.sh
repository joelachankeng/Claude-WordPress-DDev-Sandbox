#!/usr/bin/env bash
# Prune <project-root>/.playwright-mcp/: delete files older than 7 days,
# then cap the total at MAX_FILES by deleting the oldest first.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="$PROJECT_ROOT/.playwright-mcp"
MAX_FILES=100
MAX_AGE_DAYS=7

[[ -d "$TARGET_DIR" ]] || exit 0

find "$TARGET_DIR" -type f -mtime +"$MAX_AGE_DAYS" -delete

file_count=$(find "$TARGET_DIR" -type f | wc -l)
if (( file_count > MAX_FILES )); then
  excess=$(( file_count - MAX_FILES ))
  mapfile -t oldest < <(
    find "$TARGET_DIR" -type f -printf '%T@\t%p\n' \
      | sort -n \
      | head -n "$excess" \
      | cut -f2-
  )
  (( ${#oldest[@]} > 0 )) && rm -f -- "${oldest[@]}"
fi
