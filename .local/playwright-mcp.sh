#!/usr/bin/env bash
# playwright-mcp.sh — launch the Playwright MCP server for this project.
#
# Referenced by the project-root .mcp.json. Under the old Docker sandbox the MCP
# server was passed to Claude with `--mcp-config` by a start script; there are no
# start scripts any more (Claude runs natively on this VM), so .mcp.json in the
# project root is what gets auto-discovered instead.
#
# What this wrapper adds over calling @playwright/mcp directly:
#
#   1. A HEADED browser on the shared virtual display, so you can watch it and
#      take over — log in, solve a captcha, type credentials — and then hand it
#      back. Connect over RDP (see .local/bootstrap-vm.sh) and the browser is
#      right there. It is the SAME browser being automated, not a copy, so a
#      login you perform by hand is immediately available to automation.
#
#   2. A PER-PROJECT profile directory. This is the one thing that must never be
#      shared between sandboxes: Chromium refuses to open a second instance
#      against the same user-data-dir ("Browser is already in use ... use
#      --isolated"), which was a recurring annoyance in the old setup. Because
#      the profile lives inside the project, cloning this scaffolding gives each
#      site its own and they can all have a browser open at once.
#
#   3. A headless fallback. If the display cannot start, the server still comes
#      up headless rather than failing outright.
#
# IMPORTANT: MCP speaks JSON-RPC over stdin/stdout. Anything printed to stdout
# here corrupts that stream and the server appears to hang or fail to connect.
# Every diagnostic in this file therefore goes to stderr.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROFILE_DIR="$SCRIPT_DIR/.playwright-profile"
OUTPUT_DIR="$PROJECT_ROOT/.playwright-mcp"
SECRETS_FILE="$SCRIPT_DIR/.playwright-secrets"
DISPLAY_SCRIPT="$SCRIPT_DIR/display.sh"
DISPLAY_NUM="${SANDBOX_DISPLAY_NUM:-99}"

log() { printf '[playwright-mcp] %s\n' "$*" >&2; }

mkdir -p "$PROFILE_DIR" "$OUTPUT_DIR"

# Housekeeping for the screenshot directory, as the old start scripts did.
[[ -x "$SCRIPT_DIR/prune-playwright-mcp.sh" ]] && "$SCRIPT_DIR/prune-playwright-mcp.sh" >&2 2>/dev/null

ARGS=(
  --user-data-dir "$PROFILE_DIR"
  --output-dir "$OUTPUT_DIR"
  # devtools gives access to the DevTools protocol alongside the normal tools;
  # vision adds coordinate-based interaction for canvas-style UIs that have no
  # accessible elements to target.
  --caps vision,pdf,devtools
  # Report warnings and errors from the page console, which is most of what is
  # worth seeing while debugging a theme or plugin.
  --console-level warning
)

# A dotenv file of credentials the browser may use WITHOUT them passing through
# the conversation. Create it yourself; it is git-ignored, and .claude/settings.json
# denies Claude from reading it the same way it denies .env.
if [[ -f "$SECRETS_FILE" ]]; then
  ARGS+=(--secrets "$SECRETS_FILE")
  log "using secrets from .local/.playwright-secrets"
fi

# --- headed on the shared display, or headless if that is impossible ---------
want_headless=0
if [[ "${SANDBOX_PLAYWRIGHT_HEADLESS:-0}" == "1" ]]; then
  want_headless=1
  log "SANDBOX_PLAYWRIGHT_HEADLESS=1 — starting headless"
fi

if (( ! want_headless )); then
  # Bring the display up if it is not already. Redirect to stderr: this prints.
  if [[ -x "$DISPLAY_SCRIPT" ]] && "$DISPLAY_SCRIPT" ensure >&2 2>&1; then
    export DISPLAY=":${DISPLAY_NUM}"
    log "headed on display ${DISPLAY} — connect over RDP to watch or take over"
  else
    want_headless=1
    log "could not start the virtual display; falling back to headless."
    log "run .local/bootstrap-vm.sh if Xvfb/x11vnc/openbox are not installed yet."
  fi
fi

(( want_headless )) && ARGS+=(--headless)

# Chromium's own sandbox is left ENABLED (no --no-sandbox). The old setup needed
# to disable it to run as root inside a container; here the browser runs as an
# ordinary user on the VM and the sandbox works, so there is no reason to give
# that protection up.

exec npx -y @playwright/mcp "${ARGS[@]}"
