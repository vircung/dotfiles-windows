#Requires -Version 7.4
#MISE description="Install missing apps from winget/<list>.json in the dotfiles repo (default: dev)"
# Usage: mise run winget:install [-- -List dev] [-Upgrade]
# Installed packages are skipped; -Upgrade upgrades them to the latest version.

param(
    [string]$List = 'dev',
    [switch]$Upgrade
)

$ErrorActionPreference = 'Stop'

# ~/.config/mise is a junction to <repo>/mise - the list lives in <repo>/winget, outside the mise config.
$miseDir = Get-Item (Join-Path $PSScriptRoot '..\..')
$repo = Split-Path ($miseDir.LinkTarget ?? $miseDir.FullName)
$file = Join-Path $repo "winget\$List.json"
if (-not (Test-Path $file)) {
    $available = (Get-ChildItem (Join-Path $repo 'winget') -Filter *.json).BaseName -join ', '
    Write-Host "BLAD: Brak listy $file (dostepne: $available)." -ForegroundColor Red
    exit 1
}

Write-Host "winget import: $file"
$importArgs = @('import', '--import-file', $file, '--ignore-unavailable', '--accept-package-agreements', '--accept-source-agreements')
if (-not $Upgrade) { $importArgs += '--no-upgrade' }
winget @importArgs
exit $LASTEXITCODE
