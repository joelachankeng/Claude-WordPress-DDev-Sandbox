#!/usr/bin/env bash
# display.sh — manage the persistent virtual display the headed browser lives on.
#
# The display stack is three unprivileged processes:
#
#   Xvfb :99      a virtual framebuffer — a screen with no physical monitor
#   openbox       a minimal window manager, so windows can be moved, focused
#                 and alt-tabbed when you connect
#   x11vnc        exports :99 over VNC on 127.0.0.1:5900, which is what xrdp
#                 forwards your RDP session to
#
# Why a persistent display rather than the browser living in your RDP session:
# the browser survives your disconnect. You can RDP in, log into a site or solve
# a captcha by hand, disconnect, and automation keeps driving that same browser
# with the session intact. An RDP-session-owned browser dies when the session
# ends, and its DISPLAY number changes on every connect.
#
# Why this is also why the old blank-page bug cannot come back: that failure was
# headed Chrome painting to an *occludable* X window on the Windows desktop —
# when Windows stopped driving paints, Chrome produced zero frames and
# screenshots hung. An Xvfb framebuffer is always mapped and always painting,
# and there is no window manager on the far side to occlude it.
#
# EVERYTHING HERE IS IDEMPOTENT AND SHARED. Several sandboxes can be cloned from
# this scaffolding and all of them use the same :99 — a display is a screen, not
# a browser slot, so their browsers appear as separate windows on one virtual
# desktop and you see all of them in one RDP session. What must NOT be shared is
# the browser *profile*; each project keeps its own (see playwright-mcp.sh), or
# Chromium refuses to start with "Browser is already in use".
#
# Usage:
#   ./.local/display.sh up       # start anything not already running (safe to re-run)
#   ./.local/display.sh down     # stop the stack
#   ./.local/display.sh status   # report what is running
#   ./.local/display.sh ensure   # like `up`, but silent when already healthy
set -uo pipefail

DISPLAY_NUM="${SANDBOX_DISPLAY_NUM:-99}"
DISPLAY_NAME=":${DISPLAY_NUM}"
VNC_PORT="${SANDBOX_VNC_PORT:-5900}"
SCREEN_GEOMETRY="${SANDBOX_SCREEN_GEOMETRY:-1920x1080x24}"

RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}/sandbox-display-${DISPLAY_NUM}"
LOG_DIR="$RUN_DIR/logs"
mkdir -p "$LOG_DIR"

# X marks a display as taken with a lock file, so this is the authoritative check
# rather than pgrep (which would also match a dying process).
xvfb_running()   { [[ -e "/tmp/.X${DISPLAY_NUM}-lock" ]] && pgrep -f "Xvfb ${DISPLAY_NAME}" >/dev/null 2>&1; }
openbox_running(){ pgrep -f "openbox.*--config-file ${RUN_DIR}/openbox-rc.xml" >/dev/null 2>&1; }
x11vnc_running() { pgrep -f "x11vnc.*-rfbport ${VNC_PORT}" >/dev/null 2>&1; }

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[display.sh] Missing '$1'. Run .local/bootstrap-vm.sh first." >&2
    return 1
  fi
}

write_openbox_config() {
  # A deliberately bare openbox: no desktop, no panel, no menu clutter. Just
  # enough of a window manager that browser windows are movable and focusable.
  cat > "$RUN_DIR/openbox-rc.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <theme>
    <name>Clearlooks</name>
    <titleLayout>NLIMC</titleLayout>
  </theme>
  <desktops>
    <number>1</number>
  </desktops>
  <applications>
    <!-- Browser windows open maximised; with several projects sharing this
         screen, alt-tab is easier than tiling them by hand. -->
    <application class="*">
      <maximized>yes</maximized>
    </application>
  </applications>
</openbox_config>
XML
}

start_up() {
  local quiet="${1:-0}"
  need Xvfb || return 1
  need openbox || return 1
  need x11vnc || return 1

  if xvfb_running; then
    (( quiet )) || echo "Xvfb already running on $DISPLAY_NAME"
  else
    echo "Starting Xvfb on $DISPLAY_NAME ($SCREEN_GEOMETRY)..."
    # -nolisten tcp: the display is reached through x11vnc, never raw X over TCP.
    nohup Xvfb "$DISPLAY_NAME" -screen 0 "$SCREEN_GEOMETRY" -nolisten tcp \
      >"$LOG_DIR/xvfb.log" 2>&1 &
    # Wait for the display to actually accept connections before starting
    # anything that needs it; a race here shows up as openbox exiting instantly.
    local i
    for i in $(seq 1 50); do
      xvfb_running && DISPLAY="$DISPLAY_NAME" xdpyinfo >/dev/null 2>&1 && break
      sleep 0.2
    done
    if ! DISPLAY="$DISPLAY_NAME" xdpyinfo >/dev/null 2>&1; then
      echo "[display.sh] Xvfb did not come up. See $LOG_DIR/xvfb.log" >&2
      return 1
    fi
  fi

  write_openbox_config
  if openbox_running; then
    (( quiet )) || echo "openbox already running"
  else
    echo "Starting openbox..."
    DISPLAY="$DISPLAY_NAME" nohup openbox --config-file "$RUN_DIR/openbox-rc.xml" \
      >"$LOG_DIR/openbox.log" 2>&1 &
    sleep 0.5
  fi

  if x11vnc_running; then
    (( quiet )) || echo "x11vnc already running on 127.0.0.1:$VNC_PORT"
  else
    echo "Starting x11vnc on 127.0.0.1:$VNC_PORT..."
    # -localhost: only xrdp (same machine) may connect, so the desktop is never
    #   exposed to the network directly.
    # -forever / -shared: survive a disconnect and allow reconnecting, which is
    #   the entire point of a persistent display.
    # -nopw is safe only in combination with -localhost.
    nohup x11vnc -display "$DISPLAY_NAME" -rfbport "$VNC_PORT" \
      -localhost -forever -shared -nopw -quiet \
      >"$LOG_DIR/x11vnc.log" 2>&1 &
    sleep 0.5
  fi

  if ! x11vnc_running; then
    echo "[display.sh] x11vnc did not start. See $LOG_DIR/x11vnc.log" >&2
    return 1
  fi

  (( quiet )) || {
    echo
    echo "Display $DISPLAY_NAME is ready."
    echo "Connect with an RDP client to this VM (see .local/bootstrap-vm.sh for the"
    echo "xrdp session name), or a VNC client to 127.0.0.1:$VNC_PORT over an SSH tunnel."
  }
}

start_down() {
  local stopped=0
  if x11vnc_running; then pkill -f "x11vnc.*-rfbport ${VNC_PORT}" && { echo "Stopped x11vnc"; stopped=1; }; fi
  if openbox_running; then pkill -f "openbox.*--config-file ${RUN_DIR}/openbox-rc.xml" && { echo "Stopped openbox"; stopped=1; }; fi
  if xvfb_running; then
    pkill -f "Xvfb ${DISPLAY_NAME}" && { echo "Stopped Xvfb"; stopped=1; }
    # Xvfb does not always clean this up when killed, and a stale lock makes the
    # next start fail with "Server is already active for display 99".
    sleep 0.5
    if ! pgrep -f "Xvfb ${DISPLAY_NAME}" >/dev/null 2>&1; then
      rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}" 2>/dev/null || true
    fi
  fi
  (( stopped )) || echo "Nothing was running."
  echo
  echo "Note: this display is shared by every sandbox cloned from this"
  echo "scaffolding. Stopping it closes any browser window on it, including"
  echo "other projects'."
}

print_status() {
  printf 'display      %s\n' "$DISPLAY_NAME"
  printf '  Xvfb       %s\n' "$(xvfb_running    && echo running || echo stopped)"
  printf '  openbox    %s\n' "$(openbox_running && echo running || echo stopped)"
  printf '  x11vnc     %s (127.0.0.1:%s)\n' "$(x11vnc_running && echo running || echo stopped)" "$VNC_PORT"
  printf '  geometry   %s\n' "$SCREEN_GEOMETRY"
  printf '  logs       %s\n' "$LOG_DIR"
  if xvfb_running; then
    echo "  windows currently on the display:"
    DISPLAY="$DISPLAY_NAME" wmctrl -l 2>/dev/null | sed 's/^/    /' \
      || echo "    (install wmctrl to list them)"
  fi
}

case "${1:-}" in
  up)     start_up 0 ;;
  ensure) start_up 1 ;;
  down)   start_down ;;
  status) print_status ;;
  *)
    cat <<EOF
Usage: $(basename "$0") {up|ensure|down|status}

  up       Start the virtual display stack (safe to re-run).
  ensure   Same, but quiet when it is already healthy. Used by playwright-mcp.sh.
  down     Stop it. Closes every browser window on the display, including other
           projects' — the display is shared.
  status   Show what is running and which windows are open.

Override the defaults with SANDBOX_DISPLAY_NUM, SANDBOX_VNC_PORT and
SANDBOX_SCREEN_GEOMETRY if you ever want a project on its own screen.
EOF
    exit 2
    ;;
esac
