#!/usr/bin/env bash
# Multisite-aware search-replace for the WordPress sandbox.
#
# Why a separate script from the plain "search-replace URLs" action?
# A WordPress *network* stores host info in places a single full-URL replace
# misses, and it can't even be bootstrapped the normal way after a fresh import:
#
#   1. Bootstrap mismatch. DDEV's wp-config-ddev.php pins WP_HOME / WP_SITEURL to
#      https://<project>.ddev.site, but a just-imported production dump still has
#      the live domain (e.g. "projects.hria.org") in wp_blogs / wp_site. With no
#      matching site, WP-CLI's multisite bootstrap fatals ("Site not found"), so
#      `wp search-replace` never runs. We work around this by passing
#      --url=<OLD domain still in the DB> so WP-CLI boots against a site that
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
#   NEW_URL   Full new URL or bare host. Defaults to this project's DDEV URL.
#
# Options:
#   --dry-run     Show what would change without writing (wp-cli --dry-run).
#   -y, --yes     Skip the confirmation prompt.
#   -h, --help    Show this help.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT" || exit 1

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

if ! command -v ddev >/dev/null 2>&1; then
  echo "[ERROR] ddev is not installed or not on PATH." >&2
  exit 1
fi

if ! ddev exec true >/dev/null 2>&1; then
  echo "[ERROR] The DDEV site isn't running. Start it with 'ddev start' first." >&2
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

# Raw SQL as root against this project's database. -N -B gives tab-separated
# rows with no column header. stdin from /dev/null so the client can't drain the
# caller's stdin when this script is driven from a pipe.
db_query() { ddev mysql -N -B -e "$1" </dev/null | tr -d '\r'; }

# --skip-plugins / --skip-themes keeps the bootstrap light and is the recommended
# way to run search-replace (heavy plugins can exhaust memory and abort it).
wp_cli() { ddev wp --skip-plugins --skip-themes "$@"; }

# Strip scheme + trailing slash, leaving a bare host[/path]. "https://x.org/" -> "x.org"
bare_host() { printf '%s' "$1" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/+$##'; }

# -------------------- detect OLD url/domain from the DB --------------------
# We read straight from MySQL rather than via WP-CLI because, pre-replace, the
# multisite bootstrap can't resolve the sandbox host yet (see header).
echo "Reading current network host from the database..."

DB_SITEURL="$(db_query "SELECT option_value FROM wp_options WHERE option_name='siteurl' LIMIT 1;" 2>/dev/null)"
DB_DOMAIN="$(db_query "SELECT domain FROM wp_site ORDER BY id LIMIT 1;" 2>/dev/null)"
[[ -z "$DB_DOMAIN" ]] && DB_DOMAIN="$(db_query "SELECT domain FROM wp_blogs ORDER BY blog_id LIMIT 1;" 2>/dev/null)"

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

# Default target: whatever DDEV actually serves this project at.
if [[ -z "$NEW_URL" ]]; then
  NEW_URL="$(ddev exec printenv DDEV_PRIMARY_URL 2>/dev/null | tr -d '\r\n')"
  if [[ -z "$NEW_URL" ]]; then
    echo "[ERROR] Could not read DDEV_PRIMARY_URL from the web container." >&2
    echo "        Pass the new URL explicitly: $(basename "$0") <old> <new>" >&2
    exit 1
  fi
fi

OLD_HOST="$(bare_host "$OLD_URL")"
NEW_HOST="$(bare_host "$NEW_URL")"
NEW_URL="${NEW_URL%/}"

# The --url WP-CLI boots against must be a host that EXISTS in wp_blogs right
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
# --url lets WP-CLI bootstrap the network against a host that still exists in
# wp_blogs. --all-tables sweeps every subsite option table and the network tables
# in one shot. --network ensures network-registered tables (wp_site, wp_sitemeta,
# wp_blogs) are included in WP-CLI's table set.
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
  echo "Multisite search-replace complete. Flushing the object cache..."
  wp_cli --url="$NEW_HOST" cache flush 2>/dev/null || \
    echo "(cache flush skipped — run 'ddev wp --url=$NEW_HOST cache flush' by hand if needed)"
else
  echo "[WARN] One or more passes exited non-zero (rc=$rc). Review the output above."
fi
exit "$rc"
