#!/bin/bash
# Test harness for deny-env-reads.sh. Not loaded by Claude Code - this is just
# a developer test runner. Kept inside .claude/hooks so its filename collisions
# with the .env keyword don't have to leave the project.
set -u

# Resolve the hook next to this harness. This used to be the hardcoded path
# /h/deny-env-reads.sh, which was where the hooks directory was mounted inside
# the old Docker container; Claude runs natively on the VM now, so that path no
# longer exists and every case failed to even start.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOK_DIR/deny-env-reads.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq is not installed, and the hook needs it to parse its payload."
    echo "      .claude/settings.json only runs the hook when jq is present, so the"
    echo "      hook layer is inert without it. Install it: sudo apt install jq"
    exit 2
fi

run() {
    local label="$1"; local cmd="$2"; local expect="$3"
    echo "--- ${label} (expect ${expect}) ---"
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)" \
        | sh "$HOOK"
    echo
}

run "cat secret file"               "cat .env"                                            "BLOCK"
run "powershell read secret"        "powershell -NoProfile -Command \"Get-Content .env\"" "BLOCK"
run "cat example (no secret)"       "cat .env.example"                                    "ALLOW"
run "copy to backup"                "cp .env .env.bak"                                    "BLOCK"
run "harmless git"                  "git status"                                          "ALLOW"
run "envrc is a different file"     "cat .envrc"                                          "ALLOW"
run "wizard call (no .env in cmd)"  "powershell -File scripts/fetch-project.ps1"          "ALLOW"
run "restore from backup"           "mv .env.testbackup .env"                             "BLOCK"
run "find -exec cat"                "find . -name .env -exec cat {} +"                    "BLOCK"
run "playwright secrets"            "cat .local/.playwright-secrets"                       "BLOCK"
run "playwright secrets via grep"   "grep -i pass .local/.playwright-secrets"              "BLOCK"
run "playwright profile is fine"    "ls .local/.playwright-profile"                        "ALLOW"
echo "--- done ---"
