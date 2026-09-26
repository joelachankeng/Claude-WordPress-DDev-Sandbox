#!/bin/bash
# Test harness for deny-env-reads.sh. Not loaded by Claude Code - this is just
# a developer test runner. Kept inside .claude/hooks so its filename collisions
# with the .env keyword don't have to leave the project.
set -u

run() {
    local label="$1"; local cmd="$2"; local expect="$3"
    echo "--- ${label} (expect ${expect}) ---"
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)" \
        | sh /h/deny-env-reads.sh
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
echo "--- done ---"
