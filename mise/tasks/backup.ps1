#Requires -Version 7.4
#MISE description="Back up everything: Docker volumes, then WSL distros"
# Usage: mise run backup [-- -SkipDocker] [-SkipWsl]
# Runs docker:backup first, while Docker is still running, then wsl:backup (which stops Docker
# and WSL for the snapshot). A failed step doesn't stop the next one; the task fails at the end.

param(
    [switch]$SkipDocker,
    [switch]$SkipWsl
)

$ErrorActionPreference = 'Stop'
$failed = @()

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# Each task runs in its own process: they end with `exit`, which would end this script too.
if (-not $SkipDocker) {
    Step 'Docker volumes'
    pwsh -NoProfile -File "$PSScriptRoot\docker\backup.ps1"
    if ($LASTEXITCODE -ne 0) { $failed += 'docker:backup' }
}
if (-not $SkipWsl) {
    Step 'WSL distros'
    pwsh -NoProfile -File "$PSScriptRoot\wsl\backup.ps1"
    if ($LASTEXITCODE -ne 0) { $failed += 'wsl:backup' }
}

if ($failed) { Write-Host "`nERROR: Failed: $($failed -join ', ')." -ForegroundColor Red; exit 1 }
Write-Host "`nBackup complete." -ForegroundColor Green
