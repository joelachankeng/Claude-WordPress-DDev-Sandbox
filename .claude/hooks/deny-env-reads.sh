#!/bin/sh
# POSIX-shell version of deny-env-reads.ps1. Used when Claude runs on a Unix
# host (e.g. inside the dev container defined by Dockerfile).
#
# Requirements:
#   - jq         (installed in the Claude container via apt)
#   - GNU grep   (provides -P / PCRE for the lookahead)
#
# Wired up by .claude/settings.json alongside the PowerShell version - both
# entries run; the one whose interpreter is missing on this platform errors
# silently and the other does the work.

# Fail open: any error in this script must not block legitimate work.

raw=$(cat)
if [ -z "$raw" ]; then exit 0; fi

# Pull the bash command out of the hook payload.
cmd=$(printf '%s' "$raw" | jq -r '.tool_input.command // ""' 2>/dev/null)
if [ -z "$cmd" ]; then exit 0; fi

# Match .env.<ext> first (greedy), then bare .env at a word boundary.
# Filter out .env.example - the only .env variant safe to read.
hits=$(printf '%s' "$cmd" \
    | grep -oP '\.env\.[A-Za-z0-9_-]+|\.env(?=\W|$)' 2>/dev/null \
    | grep -vx '\.env\.example' 2>/dev/null)

if [ -n "$hits" ]; then
    joined=$(printf '%s' "$hits" | paste -sd, - | sed 's/,/, /g')
    reason="Refused. Bash command references: ${joined}. CLAUDE.md prohibits reading or copying the .env file via shell commands (this also blocks cp/mv to .env.* backups, which are exfiltration vectors). Use Edit/Write tools if you genuinely need to modify .env."
    # jq handles JSON escaping of the reason string.
    printf '%s' "$reason" | jq -Rsc \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}'
fi

exit 0
