# PreToolUse hook for Bash. Blocks any shell command whose text references
# .env, .env.bak, .env.local, .env.testbackup, etc. .env.example is allowed
# (it has no secrets).
#
# The hook receives Claude Code's tool-call payload as JSON on stdin and
# responds with a JSON permissionDecision. Wired up by .claude/settings.json
# under hooks.PreToolUse with matcher "Bash".

$ErrorActionPreference = 'Stop'

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $payload = $raw | ConvertFrom-Json
    $cmd = [string]$payload.tool_input.command
    if ([string]::IsNullOrWhiteSpace($cmd)) { exit 0 }

    # Match .env followed by a word boundary (end / space / quote / slash / etc.)
    # OR .env.<ext>. Excludes .envrc, .environment, etc. (no boundary).
    # Order matters: put the longer ".env.<ext>" alternative first so it wins
    # the alternation, otherwise ".env" in ".env.example" gets matched and the
    # .env.example exclusion below never fires.
    $found = [regex]::Matches($cmd, '\.env\.[A-Za-z0-9_-]+|\.env(?=\W|$)')
    $hits = @($found | ForEach-Object { $_.Value } | Where-Object { $_ -ne '.env.example' })

    if ($hits.Count -gt 0) {
        $reply = @{
            hookSpecificOutput = @{
                hookEventName            = 'PreToolUse'
                permissionDecision       = 'deny'
                permissionDecisionReason = "Refused. Bash command references: $($hits -join ', '). CLAUDE.md prohibits reading or copying the .env file via shell commands (this also blocks cp/mv to .env.* backups, which are exfiltration vectors). Use Edit/Write tools if you genuinely need to modify .env."
            }
        }
        $reply | ConvertTo-Json -Compress -Depth 5
    }
}
catch {
    # Hook errors must not block legitimate work. Fail open with a stderr note.
    [Console]::Error.WriteLine("deny-env-reads.ps1: $($_.Exception.Message)")
}

exit 0
