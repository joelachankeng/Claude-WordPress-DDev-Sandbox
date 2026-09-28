#!/usr/bin/env bash
# Interactive control panel for the DDEV WordPress sandbox.
#
#   - Start / stop this project's DDEV site
#   - Generate the DDEV WordPress config and wire wp-config.php to it
#   - Import a SQL dump from the project root
#   - Import the database from Pantheon (reusing a backup under a day old)
#   - Search-replace site URLs (single site, or network/multisite)
#   - Create or refresh a sandbox admin user
#   - Compile / watch SASS
#
# Runs on the host and drives everything through `ddev`. Nothing here needs a
# Compose project name, a port-conflict check, or a UID remap the way the old
# Docker version did: DDEV routes every project through one shared router, so
# any number of sandboxes run side by side, and the web container already runs
# as the host user.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Every ddev command is project-scoped by working directory.
cd "$PROJECT_ROOT" || exit 1

if ! command -v ddev >/dev/null 2>&1; then
  echo "[ERROR] ddev is not installed or not on PATH." >&2
  echo "        See https://docs.ddev.com/en/stable/users/install/ddev-installation/" >&2
  exit 1
fi

SASS_SCRIPT="$PROJECT_ROOT/.sass/sass.sh"
DDEV_CONFIG="$PROJECT_ROOT/.ddev/config.yaml"
DDEV_LOCAL_CONFIG="$PROJECT_ROOT/.ddev/config.local.yaml"
WP_CONFIG="$PROJECT_ROOT/wp-config.php"
WP_CONFIG_DDEV="$PROJECT_ROOT/wp-config-ddev.php"
PANTHEON_DUMP_REL=".ddev/.downloads/pantheon-db.sql.gz"

# How old Pantheon's newest database backup may be before we make a new one.
PANTHEON_BACKUP_MAX_AGE_SECONDS=86400   # 24 hours

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

ddev_configured() { [[ -f "$DDEV_CONFIG" ]]; }

# True only when this project's containers are up. `ddev exec` fails fast on a
# stopped project and never starts one, which makes it a cheap liveness probe.
#
# stdin from /dev/null, here and in every other non-interactive ddev call below:
# `ddev exec` forwards the caller's stdin into the container, so without this it
# silently eats the menu's own keystrokes — the status panel runs three of these
# before the prompt is even drawn. (The Docker version of this script had the
# same guard on `docker compose exec` for the same reason.)
ddev_running() { ddev exec true >/dev/null 2>&1 </dev/null; }

# .ddev/config.yaml deliberately has no `name:`, so DDEV derives the project
# name from the directory. Read a name if one was added, else do the same.
project_name() {
  local n=""
  if [[ -f "$DDEV_CONFIG" ]]; then
    n="$(sed -n 's/^name:[[:space:]]*//p' "$DDEV_CONFIG" | head -1 | tr -d "\"'" | tr -d '[:space:]')"
  fi
  [[ -z "$n" ]] && n="${PROJECT_ROOT##*/}"
  printf '%s' "$n"
}

# Authoritative when the site is up (straight from the container); otherwise the
# name DDEV would derive, which is the project name lowercased.
primary_url() {
  local url=""
  if ddev_running; then
    url="$(ddev exec printenv DDEV_PRIMARY_URL 2>/dev/null </dev/null | tr -d '\r\n')"
  fi
  if [[ -z "$url" ]]; then
    url="https://$(project_name | tr '[:upper:]' '[:lower:]').ddev.site"
  fi
  printf '%s' "$url"
}

# --skip-plugins / --skip-themes: this script only does core DB / user / option /
# search-replace work, none of which needs plugins or themes loaded. Skipping
# them avoids the full plugin bootstrap (heavy plugins such as event-tickets or
# gravityforms can exhaust memory and make wp exit non-zero) and is also the
# recommended way to run search-replace.
wp_cli() { ddev wp --skip-plugins --skip-themes "$@" </dev/null; }

# Raw SQL as root against this project's database. stdin from /dev/null so the
# client can't drain the menu's own stdin when the script is driven from a pipe.
db_query() { ddev mysql -N -B -e "$1" </dev/null; }

require_running() {
  if ddev_running; then
    return 0
  fi
  echo
  echo "The DDEV site isn't running."
  if confirm "Start it now?" Y; then
    power_on
    ddev_running && return 0
  fi
  echo "Aborting — this action needs the site running."
  return 1
}

test_wp_connection() {
  local out rc
  out=$(wp_cli db check 2>&1)
  rc=$?
  if (( rc != 0 )); then LAST_WP_ERROR="$out"; else LAST_WP_ERROR=""; fi
  return $rc
}

# -------------------- 1 / 2: power --------------------
ensure_configured() {
  if ddev_configured; then
    return 0
  fi
  echo
  echo "No .ddev/config.yaml found in $PROJECT_ROOT."
  echo "This project hasn't been configured for DDEV yet."
  if ! confirm "Create one now with the sandbox's standard settings?" Y; then
    echo "Cancelled."
    return 1
  fi
  # No --project-name on purpose: DDEV then derives it from the directory, so a
  # copy of this scaffolding in another site names itself.
  ddev config \
    --project-type=wordpress \
    --docroot=. \
    --webserver-type=nginx-fpm \
    --php-version=8.2 \
    --database=mariadb:11.8 \
    --nodejs-version=24 || return 1
  echo "Wrote $DDEV_CONFIG"
}

power_on() {
  ensure_configured || return 1
  echo "Starting DDEV project '$(project_name)'..."
  ddev start -y
}

power_off() {
  if ! ddev_configured; then
    echo "Nothing to stop — this project isn't configured for DDEV."
    return 0
  fi
  echo "Stopping DDEV project '$(project_name)'..."
  # `ddev stop` is per-project and keeps the database volume. `ddev poweroff`
  # would stop every project on the machine, including other sandboxes.
  ddev stop
}

# -------------------- 3: wp-config --------------------
# The snippet added to a user-managed wp-config.php. Mirrors what DDEV writes
# into its own generated wp-config.php, including the IS_DDEV_PROJECT guard so
# the file stays harmless on a real host.
wp_config_snippet() {
  cat <<'SNIPPET'

// Include for ddev-managed settings in wp-config-ddev.php.
// Added by .local/site-control.sh (option 3). Safe outside DDEV: the guard
// means a production host skips it entirely.
$ddev_settings = dirname(__FILE__) . '/wp-config-ddev.php';
if (getenv('IS_DDEV_PROJECT') === 'true' && is_readable($ddev_settings)) {
    require_once($ddev_settings);
}

SNIPPET
}

# The stock Pantheon WordPress upstream ends its config cascade with a dead-code
# fallback that hardcodes placeholder credentials:
#
#     } else {
#         define('DB_NAME', 'database_name');
#         ...
#
# On Pantheon that branch never runs, because PANTHEON_ENVIRONMENT is always set.
# Under DDEV nothing sets it, wp-config-local.php does not exist, so the fallback
# DOES run -- and it runs *above* our include, because the include has to sit
# after ABSPATH is defined (wp-config-ddev.php dereferences ABSPATH when it
# computes WP_SITEURL, so inserting it any higher is an instant fatal).
#
# wp-config-ddev.php guards every constant with defined() || define(), so the
# placeholders win and the site reports "Error establishing a database
# connection" with DB_NAME literally set to the string "database_name".
#
# Retargeting that one `else` to skip under DDEV fixes it. This only ever fires
# when the value is the upstream's placeholder literal, which is never a real
# credential, and behaviour off DDEV is unchanged.
PLACEHOLDER_DB_DEFINE="define('DB_NAME',          'database_name');"
PLACEHOLDER_FALLBACK_MARKER="// DDEV: skip the placeholder fallback"
neutralize_placeholder_db_defines() {
  # Already retargeted on a previous run. Checked before the placeholder test,
  # because the defines themselves stay in the file — only the branch guarding
  # them changes — so the placeholder is still there afterwards.
  if grep -qF "$PLACEHOLDER_FALLBACK_MARKER" "$WP_CONFIG" 2>/dev/null; then
    echo "The placeholder fallback is already retargeted to skip under DDEV."
    return 0
  fi
  grep -qF "$PLACEHOLDER_DB_DEFINE" "$WP_CONFIG" 2>/dev/null || return 0

  echo
  echo "wp-config.php still contains the Pantheon upstream's placeholder fallback:"
  echo "    $PLACEHOLDER_DB_DEFINE"
  echo "Off Pantheon that branch runs, and because it runs before the include"
  echo "above, its placeholders win over DDEV's real credentials and the site"
  echo "cannot reach the database."
  echo
  echo "Fix: make that one 'else' skip itself under DDEV. Everywhere else -- on"
  echo "Pantheon, or a plain local checkout -- it behaves exactly as it does now."
  if ! confirm "Retarget the fallback branch?" Y; then
    echo "Cancelled. Expect 'Error establishing a database connection' until you"
    echo "comment out those placeholder define() calls yourself."
    return 0
  fi

  local backup tmp
  backup="$WP_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  cp "$WP_CONFIG" "$backup" || { echo "[ERROR] Could not back up wp-config.php."; return 1; }
  tmp="$(mktemp)" || return 1

  # Rewrite the LAST bare `} else {` that appears above the placeholder define,
  # so a project with unrelated else-blocks earlier in the file is untouched.
  awk -v target="$PLACEHOLDER_DB_DEFINE" '
    { line[NR] = $0 }
    index($0, target) && !stop { stop = NR }
    END {
      hit = 0
      for (i = stop; i > 0; i--) {
        if (line[i] ~ /^[ \t]*\}[ \t]*else[ \t]*\{[ \t]*$/) { hit = i; break }
      }
      for (i = 1; i <= NR; i++) {
        if (i == hit) {
          sub(/\}[ \t]*else[ \t]*\{/,
              "} elseif (getenv(\047IS_DDEV_PROJECT\047) !== \047true\047) { // DDEV: skip the placeholder fallback",
              line[i])
        }
        print line[i]
      }
      if (!hit) exit 3
    }
  ' "$WP_CONFIG" > "$tmp"
  local rc=$?

  if [[ $rc -eq 3 ]]; then
    echo "[ERROR] Found the placeholder defines but no plain '} else {' above them."
    echo "        Leaving wp-config.php untouched — comment the defines out by hand."
    rm -f "$tmp"
    return 1
  elif [[ $rc -ne 0 ]]; then
    echo "[ERROR] Failed to rewrite wp-config.php."
    rm -f "$tmp"
    return 1
  fi

  if ! php -l "$tmp" >/dev/null 2>&1 && ! ddev exec php -l /dev/stdin <"$tmp" >/dev/null 2>&1; then
    echo "[ERROR] The rewritten wp-config.php does not parse. Leaving it untouched."
    rm -f "$tmp"
    return 1
  fi

  cat "$tmp" > "$WP_CONFIG"
  rm -f "$tmp"
  echo "Retargeted the fallback branch. Backup: $(basename "$backup")"
}

generate_wp_config() {
  ensure_configured || return 1

  # DDEV writes wp-config-ddev.php itself as part of starting a `wordpress`
  # project, so "generate" means: clear the managed copy and let DDEV rewrite it.
  if [[ -f "$WP_CONFIG_DDEV" ]]; then
    if grep -q '#ddev-generated' "$WP_CONFIG_DDEV" 2>/dev/null; then
      echo "Removing the existing ddev-managed wp-config-ddev.php so DDEV rewrites it..."
      rm -f "$WP_CONFIG_DDEV"
    else
      echo "Note: wp-config-ddev.php has no '#ddev-generated' marker — it looks hand-edited."
      if ! confirm "Overwrite it?" N; then
        echo "Keeping your file; only the wp-config.php wiring will be checked."
      else
        rm -f "$WP_CONFIG_DDEV"
      fi
    fi
  fi

  if [[ ! -f "$WP_CONFIG_DDEV" ]]; then
    if ddev_running; then
      echo "Restarting DDEV so it regenerates wp-config-ddev.php..."
      ddev restart -y >/dev/null || { echo "[ERROR] ddev restart failed."; return 1; }
    else
      echo "Starting DDEV so it generates wp-config-ddev.php..."
      ddev start -y >/dev/null || { echo "[ERROR] ddev start failed."; return 1; }
    fi
  fi

  if [[ ! -f "$WP_CONFIG_DDEV" ]]; then
    echo "[ERROR] DDEV did not create wp-config-ddev.php."
    echo "        That normally means it doesn't see this as a WordPress project."
    echo "        Check 'type: wordpress' in $DDEV_CONFIG."
    return 1
  fi
  echo "wp-config-ddev.php is in place (DB credentials, WP_HOME and WP_SITEURL)."

  # --- now make sure wp-config.php actually loads it ---
  if [[ ! -f "$WP_CONFIG" ]]; then
    echo
    echo "No wp-config.php exists yet."
    echo "DDEV creates a fully managed one the next time it starts, once WordPress"
    echo "core is present. Nothing to wire up by hand."
    return 0
  fi

  if grep -q '#ddev-generated' "$WP_CONFIG" 2>/dev/null; then
    echo "wp-config.php is DDEV-managed and already loads it. Nothing to do."
    return 0
  fi

  if grep -q 'wp-config-ddev\.php' "$WP_CONFIG" 2>/dev/null; then
    echo "wp-config.php is yours and already includes wp-config-ddev.php."
    # Still worth checking: the include alone is not enough if a placeholder
    # fallback defines the DB constants ahead of it.
    neutralize_placeholder_db_defines || return 1
    return 0
  fi

  # A user-managed wp-config.php (a Pantheon one, typically) that doesn't know
  # about DDEV. DDEV refuses to edit these — it only prints a suggestion — so do
  # it here, once, idempotently.
  echo
  echo "wp-config.php exists, is not DDEV-managed, and does not include"
  echo "wp-config-ddev.php — so DDEV's database credentials never load."
  echo
  echo "The include has to run BEFORE wp-settings.php, so it will be inserted"
  echo "immediately above the 'require wp-settings.php' line (or appended if"
  echo "there isn't one)."
  if ! confirm "Insert the include into wp-config.php?" Y; then
    echo "Cancelled. Add this yourself, above the wp-settings.php require:"
    wp_config_snippet
    return 0
  fi

  local backup
  backup="$WP_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  cp "$WP_CONFIG" "$backup" || { echo "[ERROR] Could not back up wp-config.php."; return 1; }
  echo "Backed up to $(basename "$backup")"

  local snippet_file tmp
  snippet_file="$(mktemp)" || return 1
  tmp="$(mktemp)" || { rm -f "$snippet_file"; return 1; }
  wp_config_snippet > "$snippet_file"

  awk -v snip="$snippet_file" '
    !done && /require.*wp-settings\.php/ {
      while ((getline line < snip) > 0) print line
      close(snip)
      done = 1
    }
    { print }
    END {
      if (!done) {
        while ((getline line < snip) > 0) print line
        close(snip)
      }
    }
  ' "$WP_CONFIG" > "$tmp" || { echo "[ERROR] Failed to rewrite wp-config.php."; rm -f "$snippet_file" "$tmp"; return 1; }

  if ! grep -q 'wp-config-ddev\.php' "$tmp"; then
    echo "[ERROR] The rewrite did not contain the include — leaving wp-config.php untouched."
    rm -f "$snippet_file" "$tmp"
    return 1
  fi

  # Preserve the original file's permissions rather than mktemp's 0600.
  cat "$tmp" > "$WP_CONFIG"
  rm -f "$snippet_file" "$tmp"
  echo "Inserted the include into wp-config.php."

  neutralize_placeholder_db_defines || return 1

  echo
  echo "If wp-config.php hardcodes DB_NAME / DB_USER / DB_PASSWORD / DB_HOST"
  echo "anywhere else, comment those out — whichever is defined first wins, and"
  echo "DDEV's copy uses defined() guards so it will not override them."
}

# -------------------- 4: import a SQL dump --------------------
import_database() {
  require_running || return 1

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
    printf "  %d) %-45s %s\n" "$i" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
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

  if ! confirm "Replace the '$(project_name)' database with this dump?" N; then
    echo "Cancelled."
    return
  fi

  # ddev import-db drops the existing tables first and understands .sql, .sql.gz,
  # .zip and .tar.gz, so the old gunzip/unzip branches are gone.
  ddev import-db --file="$selected"
}

# -------------------- 5: import the database from Pantheon --------------------
pantheon_site_from_config() {
  [[ -f "$DDEV_LOCAL_CONFIG" ]] || return 0
  sed -n 's/.*DDEV_PANTHEON_SITE=\([^"'"'"' ]*\).*/\1/p' "$DDEV_LOCAL_CONFIG" | head -1
}

save_pantheon_site() {
  local site="$1"
  # .ddev/config.local.yaml is git-ignored by DDEV, which is where a per-project
  # value like this belongs — config.yaml is committed and shared by every clone.
  if [[ -f "$DDEV_LOCAL_CONFIG" ]] && grep -q 'DDEV_PANTHEON_SITE=' "$DDEV_LOCAL_CONFIG"; then
    sed -i "s|DDEV_PANTHEON_SITE=[^\"' ]*|DDEV_PANTHEON_SITE=${site}|" "$DDEV_LOCAL_CONFIG"
  elif [[ -f "$DDEV_LOCAL_CONFIG" ]] && grep -q '^web_environment:' "$DDEV_LOCAL_CONFIG"; then
    sed -i "/^web_environment:/a\\    - DDEV_PANTHEON_SITE=${site}" "$DDEV_LOCAL_CONFIG"
  else
    cat >> "$DDEV_LOCAL_CONFIG" <<YAML
# Per-project overrides. DDEV git-ignores this file.
web_environment:
    - DDEV_PANTHEON_SITE=${site}
YAML
  fi
  echo "Saved DDEV_PANTHEON_SITE=${site} to .ddev/config.local.yaml"
  echo "(A restart is needed before the container sees it: ddev restart)"
}

import_database_pantheon() {
  require_running || return 1

  # The machine token lives in ~/.ddev/global_config.yaml web_environment and is
  # injected into the web container; we never read or print it here.
  if ! ddev exec 'test -n "${TERMINUS_MACHINE_TOKEN:-}"' >/dev/null 2>&1 </dev/null; then
    echo
    echo "TERMINUS_MACHINE_TOKEN isn't set in the web container."
    echo "Add it once, globally:"
    echo "    ddev config global --web-environment-add=\"TERMINUS_MACHINE_TOKEN=<token>\""
    echo "    ddev restart"
    echo "Generate a token at https://dashboard.pantheon.io (Account -> Machine Tokens)."
    return 1
  fi

  local site
  site="$(pantheon_site_from_config)"
  if [[ -n "$site" ]]; then
    echo "Pantheon site (from .ddev/config.local.yaml): $site"
    local replacement
    read -rp "Press Enter to use it, or type a different site name: " replacement
    [[ -n "$replacement" ]] && site="$replacement"
  else
    read -rp "Pantheon site name (blank to cancel): " site
    [[ -z "$site" ]] && { echo "Cancelled."; return; }
  fi

  echo
  echo "Which environment should the database come from?"
  echo "  1) live   (production data)"
  echo "  2) test"
  echo "  3) dev"
  echo "  4) other  (a multidev branch name)"
  local env_choice env_name
  read -rp "Choose [1-4, default 1]: " env_choice
  case "${env_choice:-1}" in
    1|"") env_name="live" ;;
    2)    env_name="test" ;;
    3)    env_name="dev" ;;
    4)    read -rp "Multidev environment name: " env_name
          [[ -z "$env_name" ]] && { echo "Cancelled."; return; } ;;
    *)    echo "Invalid choice."; return ;;
  esac

  echo
  cat <<EOF
Plan
----
  Source      : ${site}.${env_name}
  Backup rule : reuse Pantheon's newest database backup if it is less than
                24 hours old; otherwise create a new one first.
  Target      : the '$(project_name)' DDEV database (its contents are replaced)
  Files       : not touched — code and uploads come from git.
  Pushing     : disabled in .ddev/providers/pantheon.yaml.
EOF
  echo
  if ! confirm "Proceed?" N; then
    echo "Cancelled."
    return
  fi

  mkdir -p "$PROJECT_ROOT/.ddev/.downloads" || return 1

  # Everything terminus-related runs inside the web container, where terminus and
  # the machine token both live.
  if ! ddev exec bash -c '
    set -euo pipefail
    site="$1"; env_name="$2"; max_age="$3"; dest="$4"
    target="${site}.${env_name}"

    echo "Authenticating with Pantheon..."
    terminus auth:login --machine-token="${TERMINUS_MACHINE_TOKEN}" >/dev/null \
      || { echo "terminus login failed — check TERMINUS_MACHINE_TOKEN." >&2; exit 1; }

    echo "Waking ${target}..."
    terminus env:wake -- "${target}" >/dev/null 2>&1 || true

    echo "Looking for an existing database backup..."
    latest="$(terminus backup:list "${target}" --element=database --format=json 2>/dev/null \
              | jq -r "[.[] | .date] | map(select(. != null)) | max // empty")"

    latest_epoch=""
    if [ -n "${latest}" ]; then
      if printf "%s" "${latest}" | grep -qE "^[0-9]+$"; then
        latest_epoch="${latest}"
      else
        # Some terminus versions format the date instead of emitting an epoch.
        latest_epoch="$(date -d "${latest}" +%s 2>/dev/null || true)"
      fi
    fi

    need_new=1
    if [ -n "${latest_epoch}" ]; then
      age=$(( $(date +%s) - latest_epoch ))
      if [ "${age}" -le "${max_age}" ]; then
        printf "Newest backup is %d hours old — reusing it.\n" "$(( age / 3600 ))"
        need_new=0
      else
        printf "Newest backup is %d hours old — older than a day.\n" "$(( age / 3600 ))"
      fi
    else
      echo "No usable database backup found."
    fi

    if [ "${need_new}" -eq 1 ]; then
      echo "Creating a fresh database backup on ${target} (this can take several minutes)..."
      terminus backup:create "${target}" --element=database
    fi

    echo "Downloading the backup..."
    rm -f "${dest}"
    terminus backup:get "${target}" --element=database --to="${dest}"
    ls -lh "${dest}"
  ' -- "$site" "$env_name" "$PANTHEON_BACKUP_MAX_AGE_SECONDS" "/var/www/html/$PANTHEON_DUMP_REL" </dev/null; then
    echo "[ERROR] Pantheon download failed — the local database is untouched."
    return 1
  fi

  echo
  echo "Importing into the '$(project_name)' database..."
  if ! ddev import-db --file="$PROJECT_ROOT/$PANTHEON_DUMP_REL"; then
    echo "[ERROR] Import failed. The dump is still at $PANTHEON_DUMP_REL."
    return 1
  fi
  echo "Import complete."

  # Offer to save the site name only once it has actually worked.
  if [[ "$(pantheon_site_from_config)" != "$site" ]]; then
    echo
    confirm "Remember '$site' as this project's Pantheon site?" Y && save_pantheon_site "$site"
  fi

  echo
  echo "Note: wp-config-ddev.php defines WP_HOME and WP_SITEURL from DDEV, which"
  echo "override whatever URL is in the imported database — so the site is"
  echo "browsable now. Search-replace only matters for URLs hardcoded in content,"
  echo "and for a multisite network (wp_blogs / wp_site store bare domains)."
  echo
  echo "  1) Run search-replace now (single site)"
  echo "  2) Run search-replace now (multisite/network)"
  echo "  3) Skip"
  local sr
  read -rp "Choose [1-3, default 3]: " sr
  case "${sr:-3}" in
    1) search_replace_urls ;;
    2) search_replace_multisite ;;
    *) echo "Skipped." ;;
  esac
}

# -------------------- 6: search-replace (single site) --------------------
search_replace_urls() {
  require_running || return 1

  while true; do
    echo "Testing the WP-CLI database connection..."
    if test_wp_connection; then
      echo "Connection OK."
      break
    fi
    echo
    echo "WP-CLI can't reach the database."
    if [[ -n "${LAST_WP_ERROR:-}" ]]; then
      echo "--- wp-cli output ---"
      echo "$LAST_WP_ERROR"
      echo "---------------------"
    fi
    echo "Likely causes: wp-config.php doesn't include wp-config-ddev.php (menu"
    echo "option 3), or WordPress core isn't present yet."
    if confirm "Fix it and retry?" Y; then continue; else echo "Aborting."; return; fi
  done

  local old_url
  old_url=$(wp_cli option get siteurl 2>/dev/null | tr -d '\r')
  if [[ -z "$old_url" ]]; then
    echo "Couldn't read the current site URL from the database."
    read -rp "Enter the OLD URL to replace (blank to cancel): " old_url
    [[ -z "$old_url" ]] && { echo "Cancelled."; return; }
  else
    echo "Current site URL in the database: $old_url"
  fi

  local new_url input
  new_url="$(primary_url)"
  read -rp "New site URL [default: $new_url]: " input
  new_url="${input:-$new_url}"

  # Strip scheme and any trailing slash so both http:// and https:// forms of the
  # old host get replaced. A production dump is usually https while an older
  # export may hold http links, and missing one leaves mixed-content URLs behind.
  local old_host
  old_host="$(printf '%s' "$old_url" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/+$##')"
  local new_clean
  new_clean="$(printf '%s' "$new_url" | sed -E 's#/+$##')"

  if [[ "https://$old_host" == "$new_clean" ]]; then
    echo "Old and new URLs are the same — nothing to do."
    return
  fi

  echo
  echo "Replacing across all tables (guid skipped):"
  echo "  https://$old_host  ->  $new_clean"
  echo "  http://$old_host   ->  $new_clean"
  if ! confirm "Proceed?" Y; then echo "Cancelled."; return; fi

  local rc=0
  wp_cli search-replace "https://$old_host" "$new_clean" \
    --all-tables --skip-columns=guid --report-changed-only || rc=$?
  wp_cli search-replace "http://$old_host" "$new_clean" \
    --all-tables --skip-columns=guid --report-changed-only || rc=$?

  if (( rc == 0 )); then
    wp_cli cache flush >/dev/null 2>&1 || true
    echo "Done."
  else
    echo "[WARN] One or more passes exited non-zero (rc=$rc). Review the output above."
  fi
  return $rc
}

# -------------------- 7: search-replace (multisite) --------------------
search_replace_multisite() {
  # The single-site action above is wrong for a WordPress *network*: it can't
  # bootstrap WP-CLI after a fresh import, and it misses the protocol-less domain
  # columns in wp_blogs / wp_site / wp_sitemeta. Delegate to the dedicated script.
  local mss="$SCRIPT_DIR/search-replace-multisite.sh"
  if [[ ! -f "$mss" ]]; then
    echo "[ERROR] $mss not found."
    return 1
  fi
  require_running || return 1
  bash "$mss"
}

# -------------------- 8: admin user --------------------
create_admin_user() {
  require_running || return 1

  local email="admin@admin.com"
  local password="admin"
  local username="admin"

  if test_wp_connection; then
    echo "WP-CLI connection OK — using wp user commands."
    local existing_id
    existing_id=$(wp_cli user get "$email" --field=ID 2>/dev/null | tr -d '\r[:space:]')
    if [[ -n "$existing_id" && "$existing_id" =~ ^[0-9]+$ ]]; then
      echo "User $email exists (ID $existing_id). Resetting the password and ensuring the administrator role."
      wp_cli user update "$existing_id" --user_pass="$password" --role=administrator
    else
      echo "Creating $username / $email / password '$password' (administrator)."
      wp_cli user create "$username" "$email" --user_pass="$password" --role=administrator --display_name=Admin
    fi
    return
  fi

  echo "WP-CLI is unavailable — falling back to direct SQL."
  if [[ -n "${LAST_WP_ERROR:-}" ]]; then
    echo "--- wp-cli output ---"
    echo "$LAST_WP_ERROR"
    echo "---------------------"
  fi

  # Best-effort table-prefix detection. wp-config-ddev.php honours DB_PREFIX and
  # otherwise falls back to wp_, so check the project's own config files first.
  local prefix="wp_" f found
  for f in "$WP_CONFIG" "$WP_CONFIG_DDEV"; do
    [[ -f "$f" ]] || continue
    found=$(grep -oP "table_prefix\s*=\s*['\"]\K[^'\"]+" "$f" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then prefix="$found"; break; fi
  done
  echo "Using table prefix: $prefix"

  local users_table="${prefix}users"
  local usermeta_table="${prefix}usermeta"

  local existing_id
  existing_id=$(db_query "SELECT ID FROM \`$users_table\` WHERE user_email='$email' LIMIT 1;" 2>/dev/null | tr -d '[:space:]')

  if [[ -n "$existing_id" && "$existing_id" =~ ^[0-9]+$ ]]; then
    echo "User $email exists (ID $existing_id). Resetting the password to '$password'"
    echo "(legacy MD5 hash; WordPress rehashes it on the next login)."
    db_query "UPDATE \`$users_table\` SET user_pass = MD5('$password') WHERE ID = $existing_id;"
  else
    echo "Inserting a new admin user via SQL."
    db_query "
      INSERT INTO \`$users_table\` (user_login, user_pass, user_nicename, user_email, user_registered, display_name)
      VALUES ('$username', MD5('$password'), '$username', '$email', NOW(), 'Admin');
      SET @uid = LAST_INSERT_ID();
      INSERT INTO \`$usermeta_table\` (user_id, meta_key, meta_value)
      VALUES (@uid, '${prefix}capabilities', 'a:1:{s:13:\"administrator\";b:1;}');
      INSERT INTO \`$usermeta_table\` (user_id, meta_key, meta_value)
      VALUES (@uid, '${prefix}user_level', '10');
    " && echo "Admin user inserted."
  fi
}

# -------------------- 9 / 10: sass --------------------
run_sass() {
  local mode="$1"  # compile | watch
  if [[ ! -f "$SASS_SCRIPT" ]]; then
    echo "[ERROR] $SASS_SCRIPT not found."
    return 1
  fi
  require_running || return 1
  echo "Running SASS $mode in the web container..."
  bash "$SASS_SCRIPT" "$mode"
}

compile_sass() { run_sass compile; }
watch_sass()   { run_sass watch; }

# -------------------- status --------------------
print_status() {
  local name url ddev_state="stopped" cfg="missing" core="absent" siteurl="-"

  name="$(project_name)"
  if ! ddev_configured; then
    ddev_state="not configured"
  elif ddev_running; then
    ddev_state="running"
  fi
  url="$(primary_url)"

  if [[ -f "$WP_CONFIG" ]]; then
    if grep -q '#ddev-generated' "$WP_CONFIG" 2>/dev/null; then
      cfg="present (DDEV-managed)"
    elif grep -q 'wp-config-ddev\.php' "$WP_CONFIG" 2>/dev/null; then
      cfg="present (yours, includes DDEV config)"
    else
      cfg="present - NOT wired to DDEV (run option 3)"
    fi
  fi

  [[ -f "$PROJECT_ROOT/wp-settings.php" ]] && core="present"

  if [[ "$ddev_state" == "running" ]]; then
    siteurl=$(db_query "SELECT option_value FROM wp_options WHERE option_name='siteurl' LIMIT 1;" 2>/dev/null | tr -d '[:space:]')
    [[ -z "$siteurl" ]] && siteurl="(no wp_options row — database empty?)"
  fi

  cat <<EOF
------------------------------------------
 Status   (project: $name)
------------------------------------------
  ddev:        $ddev_state
  url:         $url
  mailpit:     ${url}:8026
  wp core:     $core
  wp-config:   $cfg
  db siteurl:  $siteurl
EOF
}

# -------------------- main menu --------------------
run_action() {
  local fn="$1"
  ( "$fn" )
  local rc=$?
  (( rc != 0 )) && echo "[action exited with status $rc]"
}

main_menu() {
  while true; do
    print_status
    cat <<'EOF'
==========================================
   Sandbox site control
==========================================
  1) Power on  (ddev start)
  2) Power off (ddev stop)
  3) Generate the DDEV WordPress config
  4) Import database from a SQL file
  5) Import database from Pantheon
  6) Search-replace database URLs (single site)
  7) Search-replace database URLs (multisite/network)
  8) Create/refresh sandbox admin user
  9) Compile SASS
 10) Watch SASS (Ctrl+C to stop)
  q) Quit

EOF
    local choice
    read -rp "Choose: " choice
    case "$choice" in
      1)  run_action power_on ;;
      2)  run_action power_off ;;
      3)  run_action generate_wp_config ;;
      4)  run_action import_database ;;
      5)  run_action import_database_pantheon ;;
      6)  run_action search_replace_urls ;;
      7)  run_action search_replace_multisite ;;
      8)  run_action create_admin_user ;;
      9)  run_action compile_sass ;;
      10) run_action watch_sass ;;
      q|Q) echo "Goodbye."; exit 0 ;;
      *)  echo "Invalid choice." ;;
    esac
    echo
    pause
  done
}

main_menu
