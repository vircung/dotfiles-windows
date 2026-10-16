#Requires -Version 7.4
#MISE description="Update everything silently: no installer UI and no UAC prompts (see update.ps1 -Silent)"
# Usage: mise run update:silent [-- -SkipWinget] [-SkipMise]

param(
    [switch]$SkipWinget,
    [switch]$SkipMise
)

& (Join-Path $PSScriptRoot '..\update.ps1') -Silent -SkipWinget:$SkipWinget -SkipMise:$SkipMise
exit $LASTEXITCODE
