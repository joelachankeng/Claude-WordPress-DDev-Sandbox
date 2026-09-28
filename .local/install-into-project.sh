#!/usr/bin/env bash
#
# Install this sandbox's scaffolding into an existing WordPress project.
#
#     .local/install-into-project.sh [options] <target-project-dir>
#
# Re-runnable by design: run it again after the sandbox gains a fix and the
# target picks that fix up. Sandbox-owned files are overwritten every time.
#
# Three classes of file, because "copy everything" is wrong in both directions:
#
#   overwrite  The sandbox machinery (.local/, .ddev/, .claude/, the SASS
#              runner, CLAUDE.md, .mcp.json). This repo is the source of truth,
#              so a newer copy always wins.
#   seed       Per-project files the sandbox only supplies a starting point for:
#              the DB change log and the SASS compile list. Created when absent,
#              never overwritten — they accumulate project history.
#   never      Files the project owns: wp-config.php, .gitignore, .htaccess,
#              README.md, and anything holding credentials or browser state.
#
# The file list is derived from `git ls-files`, not hardcoded, so a file added
# to the sandbox propagates without editing this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

DRY_RUN=0
ASSUME_YES=0
DO_BACKUP=1
TARGET=""

# Files the target project owns. Never written, never overwritten.
#   .gitignore   is merged instead (see write_gitignore_block)
#   README.md    is installed as .local/SANDBOX-README.md instead
#   .htaccess    the project has its own, and it is inert under nginx anyway
#   the dotenv example existed only for the old container's OAuth token
NEVER_COPY=( .gitignore .htaccess README.md ".env.example" )

# Copied only when absent, because they become project history once in use.
SEED_ONLY=( .local/DOC/DB_CHANGES.MD .sass/SASS.settings.json )

GITIGNORE_BEGIN="# >>> claude-ddev-sandbox >>>"
GITIGNORE_END="# <<< claude-ddev-sandbox <<<"

usage() {
    cat <<USAGE
Install the Claude DDEV sandbox into an existing WordPress project.

Usage:
    $(basename "$0") [options] <target-project-dir>

Options:
    -n, --dry-run     Report what would change; write nothing.
    -y, --yes         Do not prompt for confirmation.
        --no-backup   Do not keep copies of overwritten files.
    -h, --help        This text.

Overwritten files are copied first to
<target>/.local/.install-backups/<timestamp>/ unless --no-backup is given.
USAGE
}

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)  DRY_RUN=1 ;;
        -y|--yes)      ASSUME_YES=1 ;;
        --no-backup)   DO_BACKUP=0 ;;
        -h|--help)     usage; exit 0 ;;
        -*)            die "Unknown option: $1 (try --help)" ;;
        *)
            [[ -n "$TARGET" ]] && die "More than one target directory given."
            TARGET="$1"
            ;;
    esac
    shift
done

[[ -n "$TARGET" ]] || { usage >&2; exit 1; }
[[ -d "$TARGET" ]] || die "Target is not a directory: $TARGET"
TARGET="$(cd "$TARGET" && pwd)"

[[ "$TARGET" != "$SRC" ]] || die "Target is the sandbox itself."
case "$TARGET/" in
    "$SRC"/*) die "Target is inside the sandbox: $TARGET" ;;
esac

command -v git >/dev/null 2>&1 || die "git is required: the file list comes from 'git ls-files'."
git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1 \
    || die "$SRC is not a git repository, so the file list cannot be derived."

# ---------------------------------------------------------------- inspection

in_list() {
    local needle="$1"; shift
    local item
    for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
    return 1
}

# Everything tracked here, minus the files the project owns.
mapfile -t TRACKED < <(git -C "$SRC" ls-files)
[[ ${#TRACKED[@]} -gt 0 ]] || die "'git ls-files' returned nothing."

to_overwrite=()
to_seed=()
skipped_seed=()

for rel in "${TRACKED[@]}"; do
    in_list "$rel" "${NEVER_COPY[@]}" && continue
    if in_list "$rel" "${SEED_ONLY[@]}"; then
        if [[ -e "$TARGET/$rel" ]]; then skipped_seed+=("$rel"); else to_seed+=("$rel"); fi
        continue
    fi
    to_overwrite+=("$rel")
done

# Of the overwrites, which actually differ? Only those need reporting or backup.
changed=()
identical=0
for rel in "${to_overwrite[@]}"; do
    if [[ -f "$TARGET/$rel" ]] && cmp -s "$SRC/$rel" "$TARGET/$rel"; then
        identical=$(( identical + 1 ))
    else
        changed+=("$rel")
    fi
done

looks_like_wordpress=1
if [[ ! -f "$TARGET/wp-settings.php" && ! -d "$TARGET/wp-includes" ]]; then
    looks_like_wordpress=0
fi

# Read `database: version:` out of a pantheon yml. Pantheon declares the
# production engine there; the sandbox config.yaml pins its own.
read_db_version() {
    [[ -f "$1" ]] || return 1
    awk '
        /^database:/             { in_db = 1; next }
        in_db && /^[^[:space:]]/ { in_db = 0 }
        in_db && /version:/ {
            sub(/.*version:[[:space:]]*/, "")
            gsub(/["\047[:space:]]/, "")
            if (length($0)) { print; found = 1; exit }
        }
        END { if (!found) exit 1 }
    ' "$1"
}

PANTHEON_DB=""
for f in "$TARGET/pantheon.yml" "$TARGET/pantheon.upstream.yml"; do
    if PANTHEON_DB="$(read_db_version "$f")" && [[ -n "$PANTHEON_DB" ]]; then break; fi
    PANTHEON_DB=""
done
SANDBOX_DB="$(read_db_version "$SRC/.ddev/config.yaml" || true)"

WRITE_DB_OVERRIDE=0
if [[ -n "$PANTHEON_DB" && -n "$SANDBOX_DB" && "$PANTHEON_DB" != "$SANDBOX_DB" \
      && ! -f "$TARGET/.ddev/config.local.yaml" ]]; then
    WRITE_DB_OVERRIDE=1
fi

# ------------------------------------------------------------------ gitignore

gitignore_block() {
    cat <<BLOCK
$GITIGNORE_BEGIN
# Managed by .local/install-into-project.sh. Edits inside this block are lost on
# the next run; put your own rules outside it.
.claude
.cursorignore
.ddev
.local
.mcp.json
CLAUDE.md
.sass
!.sass/SASS.settings.json
!.sass/SASS.settings.example.json
.playwright-mcp

# Credentials never belong in the project's history. The sandbox keeps its own
# under .local/, which is already ignored above; this covers a stray one at the
# repository root.
.env
.env.*
!.env.example

# DDEV regenerates this on every start and marks it #ddev-generated.
# wp-config.php itself is the project's own file and stays in version control.
wp-config-ddev.php

# Installed on each container start from .local/wp-mu-plugins/.
# Assumes the Pantheon layout, with the docroot at the repository root.
/wp-content/mu-plugins/local-mu-plugins/
/wp-content/mu-plugins/00-local-mu-plugins.php
/wp-content/mu-plugins/[0-9][0-9]-sandbox-*.php
$GITIGNORE_END
BLOCK
}

gitignore_action() {
    local gi="$TARGET/.gitignore"
    [[ -f "$gi" ]] || { echo "create"; return; }
    if grep -qF "$GITIGNORE_BEGIN" "$gi"; then
        local current
        current="$(awk -v b="$GITIGNORE_BEGIN" -v e="$GITIGNORE_END" \
            'index($0,b){f=1} f{print} index($0,e){f=0}' "$gi")"
        if [[ "$current" == "$(gitignore_block)" ]]; then echo "current"; else echo "replace"; fi
    else
        echo "append"
    fi
}

write_gitignore_block() {
    local gi="$TARGET/.gitignore" action="$1" tmp
    case "$action" in
        current) return 0 ;;
        create)  gitignore_block > "$gi" ;;
        append)  { [[ -s "$gi" ]] && printf '\n'; gitignore_block; } >> "$gi" ;;
        replace)
            tmp="$(mktemp)"
            awk -v b="$GITIGNORE_BEGIN" -v e="$GITIGNORE_END" \
                'index($0,b){skip=1} !skip{print} index($0,e){skip=0}' "$gi" > "$tmp"
            gitignore_block >> "$tmp"
            cat "$tmp" > "$gi"
            rm -f "$tmp"
            ;;
    esac
}

GITIGNORE_ACTION="$(gitignore_action)"

# ------------------------------------------------------------------ the plan

say "Source: $SRC"
say "Target: $TARGET"
say

if [[ $looks_like_wordpress -eq 0 ]]; then
    warn "Note: no wp-settings.php and no wp-includes/ in the target."
    warn "      Fine for an empty checkout, but check the path is right."
    say
fi

say "Overwrite (sandbox-owned): ${#changed[@]} to write, $identical already identical"
for rel in "${changed[@]}"; do
    if [[ -e "$TARGET/$rel" ]]; then say "    update  $rel"; else say "    add     $rel"; fi
done

if [[ ${#to_seed[@]} -gt 0 ]]; then
    say
    say "Seed (created once, never overwritten):"
    for rel in "${to_seed[@]}"; do say "    add     $rel"; done
fi
if [[ ${#skipped_seed[@]} -gt 0 ]]; then
    say
    say "Seed (already present, left alone):"
    for rel in "${skipped_seed[@]}"; do say "    keep    $rel"; done
fi

say
say "Docs:"
say "    write   .local/SANDBOX-README.md   (the project's own README.md is untouched)"

say
case "$GITIGNORE_ACTION" in
    create)  say ".gitignore: create, with the sandbox block" ;;
    append)  say ".gitignore: append the sandbox block (existing rules untouched)" ;;
    replace) say ".gitignore: refresh the sandbox block (rules outside it untouched)" ;;
    current) say ".gitignore: sandbox block already current" ;;
esac

if [[ $WRITE_DB_OVERRIDE -eq 1 ]]; then
    say
    say "Database: Pantheon declares MariaDB $PANTHEON_DB, this sandbox pins $SANDBOX_DB."
    say "          Writing .ddev/config.local.yaml to match production."
elif [[ -n "$PANTHEON_DB" && -n "$SANDBOX_DB" && "$PANTHEON_DB" != "$SANDBOX_DB" ]]; then
    # config.local.yaml exists. It may be an override this script wrote on an
    # earlier run, or one holding something else entirely (site-control.sh
    # option 5 keeps DDEV_PANTHEON_SITE there). Either way it is not ours to
    # rewrite — but only say something if it does NOT already match.
    local_db="$(read_db_version "$TARGET/.ddev/config.local.yaml" || true)"
    say
    if [[ "$local_db" == "$PANTHEON_DB" ]]; then
        say "Database: MariaDB $PANTHEON_DB, matching Pantheon — set in .ddev/config.local.yaml."
    else
        say "Database: Pantheon declares MariaDB $PANTHEON_DB, this sandbox pins $SANDBOX_DB,"
        say "          and .ddev/config.local.yaml already exists — not touching it."
        say "          To match production, add this to that file:"
        say "              database:"
        say "                  type: mariadb"
        say "                  version: \"$PANTHEON_DB\""
    fi
fi

say
say "Never touched: wp-config.php, .htaccess, README.md, .git/, the dotenv files,"
say "               the Playwright secrets file, .ddev/config.local.yaml,"
say "               .local/.playwright-profile/"

if [[ $DRY_RUN -eq 1 ]]; then
    say
    say "Dry run — nothing written."
    exit 0
fi

nothing_to_do=0
if [[ ${#changed[@]} -eq 0 && ${#to_seed[@]} -eq 0 && "$GITIGNORE_ACTION" == "current" \
      && $WRITE_DB_OVERRIDE -eq 0 ]]; then
    nothing_to_do=1
fi

if [[ $ASSUME_YES -eq 0 ]]; then
    say
    read -rp "Proceed? (y/N): " reply
    [[ "${reply,,}" == y* ]] || { say "Cancelled."; exit 0; }
fi

# ---------------------------------------------------------------------- write

BACKUP_DIR=""
if [[ $DO_BACKUP -eq 1 && ${#changed[@]} -gt 0 ]]; then
    BACKUP_DIR="$TARGET/.local/.install-backups/$(date +%Y%m%d%H%M%S)"
fi

copy_one() {
    local rel="$1" mode
    mode="$(git -C "$SRC" ls-files -s -- "$rel" | awk '{print $1}')"
    mkdir -p "$TARGET/$(dirname "$rel")"
    if [[ -n "$BACKUP_DIR" && -f "$TARGET/$rel" ]]; then
        mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
        cp -p "$TARGET/$rel" "$BACKUP_DIR/$rel"
    fi
    cp "$SRC/$rel" "$TARGET/$rel"
    # git records only one exec bit, so reapply it rather than trusting cp.
    if [[ "$mode" == "100755" ]]; then chmod 755 "$TARGET/$rel"; else chmod 644 "$TARGET/$rel"; fi
}

for rel in "${changed[@]}"; do copy_one "$rel"; done
for rel in "${to_seed[@]}";  do copy_one "$rel"; done

mkdir -p "$TARGET/.local"
cp "$SRC/README.md" "$TARGET/.local/SANDBOX-README.md"
chmod 644 "$TARGET/.local/SANDBOX-README.md"

write_gitignore_block "$GITIGNORE_ACTION"

if [[ $WRITE_DB_OVERRIDE -eq 1 ]]; then
    mkdir -p "$TARGET/.ddev"
    cat > "$TARGET/.ddev/config.local.yaml" <<YAML
# Per-project overrides. DDEV merges this over config.yaml and git-ignores it,
# so it survives re-running .local/install-into-project.sh.
#
# Matching the database engine Pantheon actually runs (read from
# pantheon.upstream.yml) is much of the point of the sandbox: a version mismatch
# is exactly the kind of thing that makes a bug reproduce here but not in
# production, or the reverse.
database:
    type: mariadb
    version: "$PANTHEON_DB"
YAML
fi

# --------------------------------------------------------------------- report

say
if [[ $nothing_to_do -eq 1 ]]; then
    say "Already up to date."
else
    say "Done."
    [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] && say "Overwritten files backed up to ${BACKUP_DIR#"$TARGET"/}"
fi

say
say "Next, in $TARGET:"
say "    1. ddev start"
say "    2. bash .local/site-control.sh  ->  option 3 (wire up wp-config.php)"
say "       This also fixes the Pantheon upstream's placeholder DB_NAME fallback,"
say "       which otherwise gives 'Error establishing a database connection'."
say "    3. bash .local/site-control.sh  ->  option 5 (pull the database)"
say "    4. Deactivate AIOS and WP Mail SMTP if the import activated them — see"
say "       'After importing a production database' in .local/CLAUDE-LOCAL.md."
say
say "Uploads are not in git and option 5 pulls the database only, so expect"
say "missing media until you fetch wp-content/uploads separately."
