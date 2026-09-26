#!/usr/bin/env bash
# Interactive control panel for the WordPress sandbox.
# - Start / stop docker services
# - Generate wp-config.local.php
# - Import a SQL dump (sql / sql.gz / gz / zip) from project root
# - Search-replace site URLs via wp-cli (single site, or network/multisite)
# - Create or refresh a sandbox admin user (wp-cli, with direct-SQL fallback)
# - Compile / watch SASS
# - Update the Claude CLI baked into the sandbox image
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE="$SCRIPT_DIR/compose.sh"

# Per-project compose slug — must match the one compose.sh and the start scripts
# derive, since it names the containers, volumes, and the claude image tag.
PROJECT_SLUG="$(printf '%s' "${PROJECT_ROOT##*/}" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]_-' '-')-claude"
CLAUDE_IMAGE="claude-dangerous:$PROJECT_SLUG"

if [[ ! -x "$COMPOSE" ]]; then
  echo "[ERROR] $COMPOSE not found or not executable." >&2
  exit 1
fi

# Defaults that match .local/docker-compose.yml.
DB_HOST="db"
DB_NAME="db"
DB_USER="db"
DB_PASSWORD="db"
DB_ROOT_PASSWORD="root"
DEFAULT_SITE_URL="http://localhost:8080"
WP_CONFIG_LOCAL="$PROJECT_ROOT/wp-config.local.php"
WP_CONFIG_TEMPLATE="$SCRIPT_DIR/wp-config.local.php"

# -------------------- helpers --------------------
confirm() {
  local prompt="${1:-Continue}"
  local default="${2:-N}"
  local hint reply
  case "${default^^}" in
    Y) hint="(Y/n)"; default="Y" ;;
    *) hint="(y/N)"; default="N" ;;
  esac
  read -rp "$prompt $hint: " reply
  reply="${reply:-$default}"
  [[ "${reply,,}" =~ ^(y|yes)$ ]]
}

pause() { read -rp "Press Enter to return to the menu..." _; }

wp_cli() {
  # --skip-plugins / --skip-themes: site-control only does core DB / user /
  # option / search-replace work, none of which needs plugins or themes loaded.
  # Skipping them avoids the full plugin bootstrap — heavy plugins (event-tickets,
  # gravityforms, etc.) can exhaust PHP memory and make wp exit 255 — and is also
  # the recommended way to run search-replace.
  "$COMPOSE" --profile cli run --rm -T wp-cli wp --skip-plugins --skip-themes "$@"
}

db_exec_sql() {
  # $1 = one or more SQL statements.
  # Stdin redirected from /dev/null because `docker compose exec` forwards the
  # caller's stdin into the container even with -T. mariadb -e doesn't read
  # stdin, but it still drains the parent shell's stdin — which silently eats
  # menu input when site-control.sh is driven from a pipe.
  "$COMPOSE" exec -T db mariadb -u root -p"$DB_ROOT_PASSWORD" "$DB_NAME" -e "$1" </dev/null
}

db_pipe() {
  # stdin → mariadb client (for importing dumps or multi-statement scripts)
  "$COMPOSE" exec -T db mariadb -u root -p"$DB_ROOT_PASSWORD" "$DB_NAME"
}

db_pipe_root() {
  # like db_pipe but without a default database selected (for CREATE DATABASE)
  "$COMPOSE" exec -T db mariadb -u root -p"$DB_ROOT_PASSWORD"
}

test_wp_connection() {
  # Run wp db check; capture stdout+stderr so we can show *why* on failure.
  local out rc
  out=$(wp_cli db check 2>&1)
  rc=$?
  if (( rc != 0 )); then
    LAST_WP_ERROR="$out"
  else
    LAST_WP_ERROR=""
  fi
  return $rc
}

# -------------------- actions --------------------
# Detects whether host TCP port $1 is already bound. Prints a useful diagnostic
# naming the offending docker container if it can find one, falling back to a
# generic "non-docker process" message. Returns 0 when a conflict is found.
check_port_conflict() {
  local port="$1"

  local docker_offenders
  docker_offenders=$(docker ps --format '{{.Names}}	{{.Ports}}' 2>/dev/null \
    | awk -F'\t' -v p=":$port->" '$2 ~ p')

  if [[ -n "$docker_offenders" ]]; then
    echo
    echo "Cannot start: host port $port is already bound by another docker container:"
    echo "$docker_offenders" | awk -F'\t' '{ printf "    %-50s  %s\n", $1, $2 }'
    echo "Stop that container (e.g., 'docker stop <name>') and try again."
    return 0
  fi

  # Fall back to a generic TCP probe via bash's /dev/tcp pseudo-device. Catches
  # non-docker processes (a host dev server, etc.) that bash's docker ps misses.
  if (echo > "/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    echo
    echo "Cannot start: host port $port is in use by a non-docker process."
    echo "Find it with 'ss -ltnp \"sport = :$port\"' or 'lsof -iTCP:$port -sTCP:LISTEN', stop it, and try again."
    return 0
  fi

  return 1
}

power_on() {
  # If wordpress is already up, nothing to start — and "port in use" would be us.
  local wp_already
  wp_already=$("$COMPOSE" ps --services --filter status=running 2>/dev/null | grep -cx wordpress || true)
  if (( wp_already == 0 )); then
    if check_port_conflict 8080; then
      return 1
    fi
  fi

  # Same check for mailpit's UI port. wordpress depends_on mailpit, so starting
  # wordpress starts the mail catcher too — and a bound 8025 fails the whole
  # power-on, not just mailpit.
  local mailpit_already mailpit_port
  mailpit_port="${MAILPIT_PORT:-8025}"
  mailpit_already=$("$COMPOSE" ps --services --filter status=running 2>/dev/null | grep -cx mailpit || true)
  if (( mailpit_already == 0 )); then
    if check_port_conflict "$mailpit_port"; then
      echo "(Mailpit's UI port. Re-run with MAILPIT_PORT=<free port> to move it.)"
      return 1
    fi
  fi

  echo "Powering on: db + wordpress + mailpit..."
  "$COMPOSE" up -d db wordpress
}

power_off() {
  echo "Powering off all services..."
  "$COMPOSE" down
}

generate_wp_config_local() {
  if [[ ! -f "$WP_CONFIG_TEMPLATE" ]]; then
    echo "[ERROR] Template not found: $WP_CONFIG_TEMPLATE"
    return 1
  fi

  if [[ -f "$WP_CONFIG_LOCAL" ]]; then
    # Heads-up if a user-edited file (no managed marker) is about to be clobbered.
    if ! grep -q '#\.local-generated' "$WP_CONFIG_LOCAL"; then
      echo "Note: existing wp-config.local.php has no '#.local-generated' marker — looks hand-edited."
    fi
    if ! confirm "wp-config.local.php exists. Overwrite?" N; then
      echo "Cancelled."
      return
    fi
  fi

  cp "$WP_CONFIG_TEMPLATE" "$WP_CONFIG_LOCAL"

  echo "Wrote $WP_CONFIG_LOCAL (copied from $WP_CONFIG_TEMPLATE)"
}

import_database() {
  local files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$PROJECT_ROOT" -maxdepth 1 -type f \
            \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.gz' -o -name '*.zip' \) \
            -print0 | sort -z)

  if (( ${#files[@]} == 0 )); then
    echo "No .sql / .sql.gz / .gz / .zip files found in $PROJECT_ROOT"
    return
  fi

  echo
  echo "Available dumps in $PROJECT_ROOT:"
  local i=1
  for f in "${files[@]}"; do
    printf "  %d) %s\n" "$i" "$(basename "$f")"
    ((i++))
  done
  echo

  local choice
  read -rp "Choose a file by number (blank to cancel): " choice
  [[ -z "$choice" ]] && { echo "Cancelled."; return; }
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#files[@]} )); then
    echo "Invalid choice."
    return
  fi
  local selected="${files[$((choice-1))]}"
  echo "Selected: $(basename "$selected")"

  if ! confirm "Overwrite database '$DB_NAME' with this dump?" N; then
    echo "Cancelled."
    return
  fi

  echo "Dropping and recreating database '$DB_NAME'..."
  db_pipe_root <<SQL
DROP DATABASE IF EXISTS \`$DB_NAME\`;
CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';
FLUSH PRIVILEGES;
SQL

  echo "Importing $(basename "$selected")..."
  case "$selected" in
    *.sql.gz|*.gz) gunzip -c "$selected" | db_pipe ;;
    *.zip)         unzip -p "$selected" | db_pipe ;;
    *.sql)         db_pipe < "$selected" ;;
    *)             echo "Unsupported file type."; return ;;
  esac
  echo "Import complete."
}

search_replace_urls() {
  while true; do
    echo "Testing wp-cli database connection..."
    if test_wp_connection; then
      echo "Connection OK."
      break
    fi
    echo
    echo "wp-cli can't connect to the database."
    if [[ -n "${LAST_WP_ERROR:-}" ]]; then
      echo "--- wp-cli output ---"
      echo "$LAST_WP_ERROR"
      echo "---------------------"
    fi
    echo "Likely causes: services down, wp-config.php / wp-config.local.php misconfigured,"
    echo "or the db container isn't ready yet."
    if confirm "Fix it and retry connection?" Y; then
      continue
    else
      echo "Aborting."
      return
    fi
  done

  local old_url
  old_url=$(wp_cli option get siteurl 2>/dev/null | tr -d '\r' || true)
  if [[ -z "$old_url" ]]; then
    echo "Couldn't detect current site URL from the database."
    read -rp "Enter the OLD URL to replace (blank to cancel): " old_url
    [[ -z "$old_url" ]] && { echo "Cancelled."; return; }
  else
    echo "Detected current site URL: $old_url"
  fi

  local new_url="$DEFAULT_SITE_URL"
  read -rp "New site URL [default: $new_url]: " input
  new_url="${input:-$new_url}"

  if [[ "$old_url" == "$new_url" ]]; then
    echo "Old and new URLs are the same — nothing to do."
    return
  fi

  echo
  echo "Replacing across all tables:"
  echo "  $old_url"
  echo "→ $new_url"
  if ! confirm "Proceed?" Y; then
    echo "Cancelled."
    return
  fi

  wp_cli search-replace "$old_url" "$new_url" --all-tables --skip-columns=guid
}

search_replace_multisite() {
  # The plain action above is wrong for a WordPress *network*: it can't bootstrap
  # wp-cli after a fresh import (the sandbox DOMAIN_CURRENT_SITE doesn't yet match
  # any wp_blogs row) and it misses the protocol-less domain columns in wp_blogs /
  # wp_site / wp_sitemeta. Delegate to the dedicated multisite script, which boots
  # against the OLD host still in the DB and does the extra bare-domain pass.
  local mss="$SCRIPT_DIR/search-replace-multisite.sh"
  if [[ ! -x "$mss" ]]; then
    echo "[ERROR] $mss not found or not executable."
    return 1
  fi
  "$mss"
}

create_admin_user() {
  local email="admin@admin.com"
  local password="admin"
  local username="admin"

  if test_wp_connection; then
    echo "wp-cli connection OK — using wp user commands."
    local existing_id
    existing_id=$(wp_cli user get "$email" --field=ID 2>/dev/null | tr -d '\r[:space:]' || true)
    if [[ -n "$existing_id" && "$existing_id" =~ ^[0-9]+$ ]]; then
      echo "User $email exists (ID $existing_id). Updating password and ensuring administrator role."
      wp_cli user update "$existing_id" --user_pass="$password" --role=administrator
    else
      echo "Creating user $username / $email / password '$password' (administrator)."
      wp_cli user create "$username" "$email" --user_pass="$password" --role=administrator --display_name=Admin
    fi
    return
  fi

  echo "wp-cli unavailable — falling back to direct SQL."

  # Best-effort table-prefix detection from wp-config files.
  local prefix="wp_"
  for f in "$PROJECT_ROOT/wp-config.local.php" "$PROJECT_ROOT/wp-config.php"; do
    if [[ -f "$f" ]]; then
      local found
      found=$(grep -oP "table_prefix\s*=\s*['\"]\K[^'\"]+" "$f" 2>/dev/null | head -1 || true)
      if [[ -n "$found" ]]; then
        prefix="$found"
        break
      fi
    fi
  done
  echo "Using table prefix: $prefix"

  local users_table="${prefix}users"
  local usermeta_table="${prefix}usermeta"

  # Look up existing user.
  local existing_id
  existing_id=$(db_exec_sql "SELECT ID FROM \`$users_table\` WHERE user_email='$email' LIMIT 1;" 2>/dev/null \
                | tail -n +2 | tr -d '[:space:]' || true)

  if [[ -n "$existing_id" && "$existing_id" =~ ^[0-9]+$ ]]; then
    echo "User $email exists (ID $existing_id). Resetting password to '$password' (legacy MD5; WP rehashes on next login)."
    db_exec_sql "UPDATE \`$users_table\` SET user_pass = MD5('$password') WHERE ID = $existing_id;"
  else
    echo "Inserting new admin user via SQL."
    db_pipe <<SQL
INSERT INTO \`$users_table\` (user_login, user_pass, user_nicename, user_email, user_registered, display_name)
VALUES ('$username', MD5('$password'), '$username', '$email', NOW(), 'Admin');
SET @uid = LAST_INSERT_ID();
INSERT INTO \`$usermeta_table\` (user_id, meta_key, meta_value)
VALUES (@uid, '${prefix}capabilities', 'a:1:{s:13:"administrator";b:1;}');
INSERT INTO \`$usermeta_table\` (user_id, meta_key, meta_value)
VALUES (@uid, '${prefix}user_level', '10');
SQL
    echo "Admin user inserted."
  fi
}

# -------------------- sass --------------------
SASS_SCRIPT="$PROJECT_ROOT/.sass/sass.sh"

sandbox_is_up() {
  # True when both db and wordpress show as running. Mirrors print_status logic.
  local running
  running=$("$COMPOSE" ps --services --filter status=running 2>/dev/null || true)
  grep -qx db        <<<"$running" || return 1
  grep -qx wordpress <<<"$running" || return 1
  return 0
}

run_sass() {
  local mode="$1"  # compile | watch

  if [[ ! -x "$SASS_SCRIPT" ]]; then
    echo "[ERROR] $SASS_SCRIPT not found or not executable."
    return 1
  fi

  if ! sandbox_is_up; then
    echo
    echo "The sandbox container isn't running."
    echo "Power it on first with menu option 1, then come back."
    return 0
  fi

  echo "Running SASS $mode inside the sandbox..."
  "$SASS_SCRIPT" "$mode"
}

compile_sass() { run_sass compile; }
watch_sass()   { run_sass watch; }

# -------------------- claude cli --------------------
# The CLI is baked into the image (npm -g inside the container), not stored in a
# volume, so "updating" it means rebuilding the image. The Dockerfile isolates
# @anthropic-ai/claude-code in the final layer and takes the version as a build
# arg, so pinning a resolved version number rebuilds that layer alone — the apt
# and Chrome layers stay cached and the rebuild takes seconds, not minutes.
claude_installed_version() {
  # Read the version out of the built image without starting the whole stack.
  local img="$CLAUDE_IMAGE"
  docker image inspect "$img" >/dev/null 2>&1 || return 1
  docker run --rm --entrypoint node "$img" \
    -e 'console.log(require("/home/node/.npm-global/lib/node_modules/@anthropic-ai/claude-code/package.json").version)' \
    2>/dev/null | tr -d '\r[:space:]'
}

claude_latest_version() {
  # Ask the npm registry directly; jq is not guaranteed on the host.
  curl -fsSL https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null \
    | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 \
    | sed 's/.*"\([^"]*\)"$/\1/'
}

update_claude_cli() {
  local img="$CLAUDE_IMAGE" current latest target

  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "Image $img doesn't exist yet — nothing to update."
    echo "Build it first with ./.local/start-claude-dangerously.sh (or rebuild-claude.sh)."
    return 1
  fi

  current="$(claude_installed_version || true)"
  echo "Installed in $img: ${current:-unknown}"

  echo "Checking the npm registry for the latest release..."
  latest="$(claude_latest_version || true)"
  if [[ -z "$latest" ]]; then
    echo "Couldn't reach the npm registry to resolve the latest version."
    read -rp "Enter a version to install manually (blank to cancel): " target
    [[ -z "$target" ]] && { echo "Cancelled."; return; }
  else
    echo "Latest on npm:              $latest"
    if [[ -n "$current" && "$current" == "$latest" ]]; then
      echo
      echo "Already up to date."
      if ! confirm "Rebuild anyway?" N; then
        echo "Nothing to do."
        return
      fi
    fi
    read -rp "Version to install [default: $latest]: " target
    target="${target:-$latest}"
  fi

  echo
  echo "Rebuilding $img with @anthropic-ai/claude-code@$target."
  echo "Only the final image layer is rebuilt — apt and Chrome stay cached."
  if ! confirm "Proceed?" Y; then
    echo "Cancelled."
    return
  fi

  if ! "$COMPOSE" build --build-arg "CLAUDE_CODE_VERSION=$target" claude; then
    echo "[ERROR] Build failed — the previous image is untouched."
    return 1
  fi

  echo
  echo "Now installed: $(claude_installed_version || echo unknown)"
  echo "Restart Claude (./.local/start-claude-dangerously.sh) to pick up the new version;"
  echo "a session already running keeps the old one until it exits."
}

# -------------------- status --------------------
print_status() {
  local running db_status="stopped" wp_status="stopped"
  running=$("$COMPOSE" ps --services --filter status=running 2>/dev/null || true)
  grep -qx db         <<<"$running" && db_status="running"
  grep -qx wordpress  <<<"$running" && wp_status="running"

  local cfg_status="missing"
  [[ -f "$WP_CONFIG_LOCAL" ]] && cfg_status="present"

  local siteurl="-"
  if [[ "$db_status" == "running" ]]; then
    siteurl=$(db_exec_sql "SELECT option_value FROM wp_options WHERE option_name='siteurl' LIMIT 1;" 2>/dev/null \
              | tail -n 1 | tr -d '[:space:]' || true)
    [[ -z "$siteurl" ]] && siteurl="(no wp_options row — db empty?)"
  fi

  cat <<EOF
------------------------------------------
 Status   (project: $PROJECT_SLUG)
------------------------------------------
  db:         $db_status
  wordpress:  $wp_status
  wp-config:  $cfg_status  ($WP_CONFIG_LOCAL)
  siteurl:    $siteurl
EOF
}

# -------------------- main menu --------------------
run_action() {
  # Wrap each action so a failure returns to the menu instead of killing the script.
  local fn="$1"
  set +e
  ( "$fn" )
  local rc=$?
  set -e 2>/dev/null || true
  if (( rc != 0 )); then
    echo "[action exited with status $rc]"
  fi
}

main_menu() {
  while true; do
    print_status
    cat <<'EOF'
==========================================
   Sandbox site control
==========================================
  1) Power on  (start db + wordpress)
  2) Power off (stop all services)
  3) Generate wp-config.local.php
  4) Import database from SQL file
  5) Search-replace database URLs (single site)
  6) Search-replace database URLs (multisite/network)
  7) Create/refresh sandbox admin user
  8) Compile SASS
  9) Watch SASS (Ctrl+C to stop)
 10) Update Claude CLI (rebuild image with the latest release)
  q) Quit

EOF
    local choice
    read -rp "Choose: " choice
    case "$choice" in
      1) run_action power_on ;;
      2) run_action power_off ;;
      3) run_action generate_wp_config_local ;;
      4) run_action import_database ;;
      5) run_action search_replace_urls ;;
      6) run_action search_replace_multisite ;;
      7) run_action create_admin_user ;;
      8) run_action compile_sass ;;
      9) run_action watch_sass ;;
      10) run_action update_claude_cli ;;
      q|Q) echo "Goodbye."; exit 0 ;;
      *) echo "Invalid choice." ;;
    esac
    echo
    pause
  done
}

main_menu
