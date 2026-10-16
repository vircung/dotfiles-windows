#Requires -Version 7.4
#MISE description="Instaluje brakujace aplikacje z winget/<lista>.json w repo dotfiles (domyslnie dev)"
# Uzycie: mise run winget:install [-- -List dev] [-Upgrade]
# Zainstalowane pakiety sa pomijane; -Upgrade aktualizuje je do najnowszej wersji.

param(
    [string]$List = 'dev',
    [switch]$Upgrade
)

$ErrorActionPreference = 'Stop'

# ~/.config/mise jest junctionem do <repo>/mise - lista lezy w <repo>/winget, poza konfiguracja mise.
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
