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
    sudo systemctl restart xrdp && ok "restarted xrdp"
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

cat <<EOF

================================================================
 Bootstrap complete.
================================================================

 Connect to the browser from Windows
 -----------------------------------
   Open Remote Desktop Connection and connect to:

       ${VM_IP:-<this-vm-ip>}:3389      (or: $(hostname).mshome.net:3389)

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
