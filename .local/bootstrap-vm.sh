#!/usr/bin/env bash
# bootstrap-vm.sh — one-time setup of the VM-level pieces the sandbox needs.
#
# Run this ONCE per machine, not once per project. Everything it installs is
# shared: the browser, the virtual display packages, the certificate trust and
# the RDP service all serve every sandbox cloned from this scaffolding. Re-running
# it is safe — every step checks before acting.
#
#   ./.local/bootstrap-vm.sh
#
# Some steps need root and will prompt for your sudo password. Nothing is
# installed silently; each section says what it is about to do.
#
# What this does NOT do is the Windows side. See .local/windows/ for that, and
# the "Reaching the site from Windows" section of the README.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Do NOT run this whole script with sudo. It calls sudo itself for the few steps
# that need root, and deliberately does the rest as you: Playwright's browsers go
# to ~/.cache/ms-playwright and the certificate goes into ~/.pki/nssdb. Run as
# root and both land in /root, where your own browser will never look for them —
# so Chromium would still fail with ERR_CERT_AUTHORITY_INVALID and Playwright
# would report a missing browser, with nothing obviously wrong.
if [[ "${EUID}" -eq 0 ]]; then
  cat >&2 <<'ROOTMSG'
[bootstrap-vm.sh] Do not run this with sudo.

  Run it as your normal user:

      ./.local/bootstrap-vm.sh

  It will ask for your sudo password only for the steps that genuinely need root
  (installing packages, configuring xrdp). The other steps must run as you, or
  the browser and the certificate end up in /root and your user cannot use them.
ROOTMSG
  exit 1
fi

STEP=0
step() { STEP=$((STEP + 1)); printf '\n\033[1m[%d] %s\033[0m\n' "$STEP" "$*"; }
ok()   { printf '    \033[32mOK\033[0m  %s\n' "$*"; }
info() { printf '        %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m   %s\n' "$*"; }
fail() { printf '    \033[31mX\033[0m   %s\n' "$*"; }

need_sudo() {
  if sudo -n true 2>/dev/null; then return 0; fi
  info "The next step needs root. You will be asked for your sudo password."
  sudo -v || return 1
}

# ---------------------------------------------------------------------------
step "Virtual display and RDP packages"
# ---------------------------------------------------------------------------
# xvfb        the virtual framebuffer the headed browser draws into
# openbox     a minimal window manager so windows can be moved and alt-tabbed
# x11vnc      exports the framebuffer over VNC for xrdp to forward
# x11-utils   xdpyinfo, used to wait for the display to accept connections
# wmctrl      lets `display.sh status` list the windows currently open
# libnss3-tools  certutil, needed to trust the local CA in Chromium (see below)
# xrdp        the RDP server itself
# jq          required by .claude/hooks/deny-env-reads.sh. settings.json only
#             runs that hook when jq is present, so WITHOUT jq the hook layer
#             of the .env protection is silently inert.
PACKAGES=(xvfb openbox x11vnc x11-utils wmctrl libnss3-tools xrdp jq)
MISSING=()
for p in "${PACKAGES[@]}"; do
  dpkg -l "$p" 2>/dev/null | grep -q '^ii' || MISSING+=("$p")
done

# Remember the system window manager before installing anything. Debian's
# alternatives system picks the highest-priority candidate while the link is in
# "auto" mode, and OPENBOX REGISTERS AT PRIORITY 90 against xfwm4's 60 — so
# installing openbox silently makes it the system window manager for every
# desktop session on the machine. That is not what we want: openbox is here only
# to manage windows on the headless :99 display, and display.sh invokes it by
# name, so the alternative is irrelevant to us. Captured here, restored below.
WM_BEFORE=""
if command -v update-alternatives >/dev/null 2>&1; then
  WM_BEFORE="$(update-alternatives --query x-window-manager 2>/dev/null \
                | sed -n 's/^Value: //p' | head -1)"
fi

if (( ${#MISSING[@]} == 0 )); then
  ok "all present: ${PACKAGES[*]}"
else
  info "missing: ${MISSING[*]}"
  if need_sudo; then
    sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends "${MISSING[@]}" \
      && ok "installed ${MISSING[*]}" \
      || { fail "apt install failed"; exit 1; }
  else
    fail "cannot continue without root for apt"
    exit 1
  fi
fi

# Put the system window manager back if openbox took it. --set also switches the
# link to manual mode, so a future openbox upgrade cannot quietly reclaim it.
if [[ -n "$WM_BEFORE" ]]; then
  WM_NOW="$(update-alternatives --query x-window-manager 2>/dev/null | sed -n 's/^Value: //p' | head -1)"
  if [[ "$WM_NOW" != "$WM_BEFORE" ]]; then
    info "installing openbox changed the system window manager:"
    info "  $WM_BEFORE -> $WM_NOW"
    if need_sudo && sudo update-alternatives --set x-window-manager "$WM_BEFORE" >/dev/null 2>&1; then
      ok "restored the system window manager to $WM_BEFORE (pinned)"
    else
      warn "could not restore it. Do this by hand or your desktop session will"
      warn "use openbox: sudo update-alternatives --set x-window-manager $WM_BEFORE"
    fi
  else
    ok "system window manager unchanged ($WM_NOW)"
  fi
fi

# ---------------------------------------------------------------------------
step "Trust the local HTTPS certificate authority in Chromium"
# ---------------------------------------------------------------------------
# DDEV serves every project over HTTPS with a certificate from mkcert's local CA.
# curl and the system trust the CA via /usr/local/share/ca-certificates, but
# CHROMIUM DOES NOT READ THAT STORE — it uses its own NSS database at
# ~/.pki/nssdb. If that database does not exist, `mkcert -install` silently skips
# it, and Playwright then fails every navigation with ERR_CERT_AUTHORITY_INVALID
# even though curl is perfectly happy. Creating the database and adding the CA
# fixes it properly, which is much better than launching the browser with
# --ignore-certificate-errors and turning TLS validation off everywhere.
if ! command -v mkcert >/dev/null 2>&1; then
  warn "mkcert not found — skipping. DDEV installs it; run 'ddev start' once, then re-run this."
else
  CAROOT="$(mkcert -CAROOT)"
  if [[ ! -f "$CAROOT/rootCA.pem" ]]; then
    info "no local CA yet — creating one"
    mkcert -install || warn "mkcert -install reported a problem"
    CAROOT="$(mkcert -CAROOT)"
  fi

  NSSDB="$HOME/.pki/nssdb"
  mkdir -p "$NSSDB"
  if ! certutil -d "sql:$NSSDB" -L >/dev/null 2>&1; then
    certutil -d "sql:$NSSDB" -N --empty-password && info "created the NSS database at $NSSDB"
  fi

  if certutil -d "sql:$NSSDB" -L 2>/dev/null | grep -q 'mkcert development CA'; then
    ok "mkcert CA already trusted by Chromium"
  else
    certutil -d "sql:$NSSDB" -A -t "C,," -n "mkcert development CA" -i "$CAROOT/rootCA.pem" \
      && ok "added the mkcert CA to Chromium's trust store" \
      || fail "certutil could not add the CA"
  fi
fi

# ---------------------------------------------------------------------------
step "Playwright and Chromium"
# ---------------------------------------------------------------------------
# Installed for your user, not system-wide: npm's prefix is under $HOME here, so
# no root is needed, and the browsers land in ~/.cache/ms-playwright.
if ! command -v npm >/dev/null 2>&1; then
  fail "npm not found — install Node.js first"
  exit 1
fi

for pkg in @playwright/mcp playwright; do
  if npm ls -g --depth=0 2>/dev/null | grep -q " $pkg@"; then
    ok "$pkg already installed"
  else
    info "installing $pkg"
    npm install -g "$pkg" >/dev/null 2>&1 && ok "installed $pkg" || { fail "npm install $pkg failed"; exit 1; }
  fi
done

if [[ -d "$HOME/.cache/ms-playwright" ]] && ls "$HOME/.cache/ms-playwright" | grep -q '^chromium-'; then
  ok "Chromium already downloaded"
else
  info "downloading Chromium (about 115 MB)"
  npx playwright install chromium >/dev/null 2>&1 && ok "Chromium installed" || { fail "playwright install chromium failed"; exit 1; }
fi

# The libraries Chromium needs (gtk3, nss, alsa, gbm) usually arrive with xrdp
# and the X packages above. Check rather than blindly running
# `playwright install --with-deps`, which pulls a long apt list.
MISSING_LIBS=()
for l in libgtk-3-0t64 libnss3 libasound2t64 libgbm1; do
  dpkg -l "$l" 2>/dev/null | grep -q '^ii' || MISSING_LIBS+=("$l")
done
if (( ${#MISSING_LIBS[@]} )); then
  warn "Chromium may be missing shared libraries: ${MISSING_LIBS[*]}"
  info "if the browser fails to launch, run: sudo npx playwright install-deps chromium"
else
  ok "Chromium's shared libraries are present"
fi

# ---------------------------------------------------------------------------
step "Point xrdp at the persistent display"
# ---------------------------------------------------------------------------
# xrdp normally spawns a NEW X session per connection. We want the opposite: to
# attach to the long-lived :99 display that the browser already lives on, so the
# browser survives your disconnect and keeps the same DISPLAY for automation.
# xrdp can do this with its VNC backend, connecting to the x11vnc that
# .local/display.sh puts in front of :99.
XRDP_INI=/etc/xrdp/xrdp.ini
SECTION='sandbox-browser'
VNC_PORT="${SANDBOX_VNC_PORT:-5900}"

if [[ ! -f "$XRDP_INI" ]]; then
  fail "$XRDP_INI not found — is xrdp installed?"
else
  if grep -q "^\[${SECTION}\]" "$XRDP_INI"; then
    ok "xrdp already has a [${SECTION}] session"
  elif need_sudo; then
    sudo cp "$XRDP_INI" "${XRDP_INI}.bak.$(date +%Y%m%d%H%M%S)"
    info "backed up $XRDP_INI"
    # Appended, so xrdp's own [Xorg] session stays available as a fallback. With
    # x11vnc running -nopw behind -localhost, the credentials here are ignored.
    sudo tee -a "$XRDP_INI" >/dev/null <<EOF

[${SECTION}]
name=Sandbox Browser (persistent display :${SANDBOX_DISPLAY_NUM:-99})
lib=libvnc.so
username=na
password=na
ip=127.0.0.1
port=${VNC_PORT}
EOF
    ok "added the [${SECTION}] session to $XRDP_INI"

    # Restarting xrdp kills every live RDP session, and — worse — ORPHANS the X
    # server, xfce4-session and xrdp-chansrv belonging to it (their parent
    # xrdp-sesman dies, so they reparent to init and keep holding the display).
    # A stale xfce4-session then refuses to let the same user start a new one, so
    # every subsequent RDP login connects and immediately disconnects. If you are
    # reading this because that happened: see "RDP logins disconnect immediately"
    # in the README.
    #
    # So: never restart xrdp out from under a live session. Say what is needed
    # and let the user do it from SSH or after disconnecting.
    if pgrep -f 'Xorg.*xrdp/xorg.conf' >/dev/null 2>&1 || pgrep -x xrdp-chansrv >/dev/null 2>&1; then
      warn "an RDP session is active right now — NOT restarting xrdp."
      info "You are most likely connected through it. Restarting would disconnect"
      info "you and orphan the session, which breaks later logins."
      info ""
      info "Finish this script, then either:"
      info "  * disconnect your RDP session and run: sudo systemctl restart xrdp"
      info "  * or run that over SSH instead"
      info ""
      info "The [${SECTION}] session only appears after that restart."
    elif sudo systemctl restart xrdp; then
      ok "restarted xrdp"
    else
      warn "could not restart xrdp — run 'sudo systemctl restart xrdp' yourself"
    fi
  else
    warn "skipped — no root"
  fi

  if systemctl is-enabled xrdp >/dev/null 2>&1; then
    ok "xrdp is enabled at boot"
  elif need_sudo; then
    sudo systemctl enable --now xrdp && ok "enabled and started xrdp"
  fi
fi

# ---------------------------------------------------------------------------
step "Start the virtual display and report"
# ---------------------------------------------------------------------------
if [[ -x "$SCRIPT_DIR/display.sh" ]]; then
  "$SCRIPT_DIR/display.sh" up || warn "the display did not start; see the log path above"
else
  warn "$SCRIPT_DIR/display.sh missing or not executable"
fi

VM_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{sub(/\/.*/,"",$4); print $4}')"

# How xrdp is reachable depends entirely on its [Globals] port setting, and the
# Debian default on a Hyper-V guest is NOT a TCP port:
#
#   port=vsock://-1:3389
#
# That is a Hyper-V VSOCK, used by Enhanced Session Mode — you connect through
# Hyper-V Manager / vmconnect, and nothing is listening on TCP 3389 at all.
# `ss -ltn` shows nothing for it either (you need `ss --vsock -l`), which makes it
# easy to conclude xrdp is broken when it is working perfectly. So report the
# truth for this machine rather than assuming.
XRDP_PORT_LINE="$(sed -n 's/^[[:space:]]*port=\(.*\)$/\1/p' /etc/xrdp/xrdp.ini 2>/dev/null | head -1)"

echo
echo "================================================================"
echo " Bootstrap complete."
echo "================================================================"
echo
echo " Connect to the browser"
echo " ----------------------"
case "$XRDP_PORT_LINE" in
  vsock*)
    cat <<EOF
   This xrdp listens on a Hyper-V VSOCK (${XRDP_PORT_LINE}), not a TCP port —
   that is Enhanced Session Mode, and it is the Debian default on a Hyper-V guest.

   So connect through **Hyper-V Manager -> Connect** (vmconnect), NOT to an IP
   address. Nothing is listening on TCP 3389, and \`ss -ltn\` will show nothing
   for xrdp; use \`ss --vsock -l\` to see the real listener.

   If you would rather reach it with a normal RDP client over the network, set
   this in the [Globals] section of /etc/xrdp/xrdp.ini:

       port=3389

   then \`sudo systemctl restart xrdp\` (while NOT connected — see below) and
   connect to ${VM_IP:-<this-vm-ip>}:3389 or $(hostname).mshome.net:3389.
EOF
    ;;
  *)
    cat <<EOF
   Open Remote Desktop Connection and connect to:

       ${VM_IP:-<this-vm-ip>}:3389      (or: $(hostname).mshome.net:3389)
EOF
    ;;
esac

cat <<EOF

   Choose the "Sandbox Browser" session when xrdp asks. You will see the
   virtual desktop holding the browser windows. Anything you do there — logging
   in, solving a captcha, typing a password — is immediately visible to the
   automation, because it is the same browser.

   The display is SHARED by every sandbox on this VM. Each project's browser is
   a separate window on the one desktop; use alt-tab. What is per-project is the
   browser profile, so their logins stay separate.

 Reach the DDEV sites from Windows
 ---------------------------------
   Run this once, in an ADMINISTRATOR PowerShell on Windows:

       .local\\windows\\Setup-DdevPortProxy.ps1

   It needs to be re-run if this VM's IP changes. See the README for what it
   does and why it is only two rules for any number of projects.

 Handy commands
 --------------
   .local/display.sh status      what is running on the virtual display
   .local/display.sh down        stop it (closes every project's browser)
   .local/site-control.sh        the sandbox menu

EOF
