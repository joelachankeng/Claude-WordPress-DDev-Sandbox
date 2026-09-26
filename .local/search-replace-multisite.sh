#!/usr/bin/env bash
# Multisite-aware search-replace for the WordPress sandbox.
#
# Why a separate script from the plain "search-replace URLs" action?
# A WordPress *network* stores host info in places a single full-URL replace
# misses, and it can't even be bootstrapped the normal way after a fresh import:
#
#   1. Bootstrap mismatch. wp-config.local.php pins DOMAIN_CURRENT_SITE to the
#      sandbox host (e.g. "wordpress"), but a just-imported production dump still
#      has the live domain (e.g. "projects.hria.org") in wp_blogs / wp_site. With
#      no matching site, wp-cli's multisite bootstrap fatals ("Site not found"),
#      so `wp search-replace` never runs. We work around this by passing
#      --url=<OLD domain still in the DB> so wp-cli boots against a site that
#      actually exists, runs the replacement, and *afterwards* the DB matches the
#      config again.
#
#   2. Bare-domain columns. wp_blogs.domain, wp_site.domain and various
#      wp_sitemeta rows store the host WITHOUT a protocol ("projects.hria.org",
#      not "https://projects.hria.org"). A single full-URL replace leaves those
#      untouched, so every subsite keeps pointing at the live host. We do an
#      extra bare-domain pass to fix them.
#
# Subsite option tables (wp_3_options, wp_4_options, ...) are already covered by
# --all-tables, so no per-site loop is needed.
#
# Usage:
#   ./.local/search-replace-multisite.sh [OLD_URL] [NEW_URL] [options]
#
#   OLD_URL   Full old URL or bare host (e.g. https://projects.hria.org or
#             projects.hria.org). Auto-detected from the DB when omitted.
#   NEW_URL   Full new URL or bare host (default: http://wordpress).
#
# Options:
#   --dry-run     Show what would change without writing (wp-cli --dry-run).
#   -y, --yes     Skip the confirmation prompt.
#   -h, --help    Show this help.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE="$SCRIPT_DIR/compose.sh"

# Match .local/docker-compose.yml.
DB_NAME="db"
DB_ROOT_PASSWORD="root"
DEFAULT_NEW_URL="http://wordpress"

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# -------------------- args --------------------
OLD_URL=""
NEW_URL=""
DRY_RUN=0
ASSUME_YES=0

while (( $# )); do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    -y|--yes)    ASSUME_YES=1 ;;
    -h|--help)   usage; exit 0 ;;
    -*)          echo "Unknown option: $1" >&2; usage; exit 2 ;;
    *)
      if [[ -z "$OLD_URL" ]]; then OLD_URL="$1"
      elif [[ -z "$NEW_URL" ]]; then NEW_URL="$1"
      else echo "Too many arguments: $1" >&2; exit 2; fi
      ;;
  esac
  shift
done

if [[ ! -x "$COMPOSE" ]]; then
  echo "[ERROR] $COMPOSE not found or not executable." >&2
  exit 1
fi

# -------------------- helpers --------------------
confirm() {
  local prompt="${1:-Continue}" default="${2:-N}" hint reply
  case "${default^^}" in
    Y) hint="(Y/n)"; default="Y" ;;
    *) hint="(y/N)"; default="N" ;;
  esac
  read -rp "$prompt $hint: " reply
  reply="${reply:-$default}"
  [[ "${reply,,}" =~ ^(y|yes)$ ]]
}

# Raw SQL against the db container. stdin from /dev/null so it doesn't drain the
# parent shell's stdin (same reasoning as site-control.sh's db_exec_sql).
db_query() {
  # $1 = a single SELECT; prints the value on its own line (no column header).
  "$COMPOSE" exec -T db mariadb -N -B -u root -p"$DB_ROOT_PASSWORD" "$DB_NAME" -e "$1" </dev/null \
    | tr -d '\r'
}

wp_cli() {
  # --skip-plugins / --skip-themes keeps the bootstrap light and is the
  # recommended way to run search-replace (heavy plugins can OOM and abort it).
  "$COMPOSE" --profile cli run --rm -T wp-cli wp --skip-plugins --skip-themes "$@"
}

# Strip scheme + trailing slash, leaving a bare host[/path]. "https://x.org/" -> "x.org"
bare_host() { printf '%s' "$1" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/+$##'; }

# -------------------- detect OLD url/domain from the DB --------------------
# We read straight from MySQL rather than via wp-cli because, pre-replace, the
# multisite bootstrap can't resolve the sandbox host yet (see header).
echo "Reading current network host from the database..."

DB_SITEURL="$(db_query "SELECT option_value FROM wp_options WHERE option_name='siteurl' LIMIT 1;" 2>/dev/null || true)"
DB_DOMAIN="$(db_query "SELECT domain FROM wp_site ORDER BY id LIMIT 1;" 2>/dev/null || true)"
[[ -z "$DB_DOMAIN" ]] && DB_DOMAIN="$(db_query "SELECT domain FROM wp_blogs ORDER BY blog_id LIMIT 1;" 2>/dev/null || true)"

if [[ -z "$OLD_URL" ]]; then
  if [[ -n "$DB_SITEURL" ]]; then
    OLD_URL="$DB_SITEURL"
  elif [[ -n "$DB_DOMAIN" ]]; then
    OLD_URL="$DB_DOMAIN"
  else
    echo "Couldn't detect the current host from the database (is it imported and running?)."
    read -rp "Enter the OLD URL or host to replace (blank to cancel): " OLD_URL
    [[ -z "$OLD_URL" ]] && { echo "Cancelled."; exit 1; }
  fi
fi

NEW_URL="${NEW_URL:-$DEFAULT_NEW_URL}"
if [[ -z "${NEW_URL}" ]]; then NEW_URL="$DEFAULT_NEW_URL"; fi

OLD_HOST="$(bare_host "$OLD_URL")"
NEW_HOST="$(bare_host "$NEW_URL")"

# The --url wp-cli boots against must be a host that EXISTS in wp_blogs right
# now, i.e. the OLD host. Prefer the detected DB domain (most authoritative).
BOOT_HOST="${DB_DOMAIN:-$OLD_HOST}"

if [[ "$OLD_HOST" == "$NEW_HOST" ]]; then
  echo "Old and new hosts are identical ('$OLD_HOST') — nothing to do."
  exit 0
fi

# -------------------- plan --------------------
DRY_FLAG=()
(( DRY_RUN )) && DRY_FLAG=(--dry-run)

cat <<EOF

Multisite search-replace plan
-----------------------------
  Detected DB siteurl : ${DB_SITEURL:-<none>}
  Detected DB domain  : ${DB_DOMAIN:-<none>}
  Bootstrap --url     : $BOOT_HOST   (must exist in wp_blogs)

  Replacements (across --all-tables, guid skipped):
    1. https://$OLD_HOST   ->  $NEW_URL
    2. http://$OLD_HOST    ->  $NEW_URL
    3. $OLD_HOST           ->  $NEW_HOST   (bare host: wp_blogs / wp_site / wp_sitemeta, emails, etc.)
$( (( DRY_RUN )) && echo "  Mode: DRY RUN (no changes written)" )
EOF

if (( ! ASSUME_YES )); then
  echo
  if ! confirm "Proceed?" Y; then echo "Cancelled."; exit 0; fi
fi

# -------------------- run --------------------
# Common flags. --url lets wp-cli bootstrap the network against a host that
# still exists in wp_blogs. --all-tables sweeps every subsite option table and
# the network tables in one shot. --network ensures network-registered tables
# (wp_site, wp_sitemeta, wp_blogs) are included in wp-cli's table set.
COMMON=(--all-tables --skip-columns=guid --network --url="$BOOT_HOST" --report-changed-only "${DRY_FLAG[@]}")

run_pass() {
  local from="$1" to="$2"
  echo
  echo ">> search-replace '$from' -> '$to'"
  wp_cli search-replace "$from" "$to" "${COMMON[@]}"
}

rc=0
run_pass "https://$OLD_HOST" "$NEW_URL" || rc=$?
run_pass "http://$OLD_HOST"  "$NEW_URL" || rc=$?
run_pass "$OLD_HOST"         "$NEW_HOST" || rc=$?

echo
if (( DRY_RUN )); then
  echo "Dry run complete — no changes written."
elif (( rc == 0 )); then
  echo "Multisite search-replace complete. Flushing object cache / rewrite is recommended:"
  echo "    $COMPOSE --profile cli run --rm -T wp-cli wp --url=$NEW_HOST cache flush"
else
  echo "[WARN] One or more passes exited non-zero (rc=$rc). Review the output above."
fi
exit "$rc"
