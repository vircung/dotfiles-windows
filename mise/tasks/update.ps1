#Requires -Version 7.4
#MISE description="Update everything: all winget apps, mise itself and mise tools (installers may show UI and UAC prompts)"
# Usage: mise run update [-- -SkipWinget] [-SkipMise]
# -Silent (used by `mise run update:silent`): winget runs with --silent through the elevated
# \dotfiles\winget-upgrade scheduled task, so installers get admin rights without UAC prompts.
# The task is installed on first use (and whenever the runner changes) with one UAC prompt.

param(
    [switch]$SkipWinget,
    [switch]$SkipMise,
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'
$failed = @()

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

$taskPath = '\dotfiles\'
$taskName = 'winget-upgrade'
$taskDir  = Join-Path $env:ProgramData 'dotfiles'
$runner   = Join-Path $PSScriptRoot '..\lib\winget-upgrade-runner.ps1'

function Test-WingetTask {
    $installed = Join-Path $taskDir 'winget-upgrade.ps1'
    (Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue) -and
        (Test-Path $installed) -and ((Get-FileHash $runner).Hash -eq (Get-FileHash $installed).Hash)
}

# Prints complete new log lines from $Position on, skipping winget's progress bars and spinners.
function Show-Log([string]$Path, [ref]$Position, [ref]$Pending, [switch]$Final) {
    if (-not (Test-Path $Path)) { return }
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -lt $Position.Value) { $Position.Value = 0 }   # truncated by a new run
        $fs.Position = $Position.Value
        $text = $Pending.Value + [IO.StreamReader]::new($fs).ReadToEnd()
        $Position.Value = $fs.Length
    } finally { $fs.Dispose() }
    $parts = $text -split "`r|`n"
    $Pending.Value = $Final ? '' : $parts[-1]
    $complete = $Final ? $parts : ($parts | Select-Object -SkipLast 1)
    $complete | Where-Object { $_.Trim() -and $_ -notmatch '^\s*[-\\|/]\s*$' -and $_ -notmatch '[\u2588\u2592]' } |
        ForEach-Object { Write-Host $_.TrimEnd() }
}

# mise is pinned in winget by install.ps1, so `winget upgrade --all` skips it; mise updates itself below.
if (-not $SkipWinget -and -not $Silent) {
    Step 'winget upgrade --all'
    winget upgrade --all --accept-package-agreements --accept-source-agreements
    # 0x8A15002B: no applicable upgrade
    if ($LASTEXITCODE -notin 0, -1978335189) { $failed += 'winget upgrade' }
}

if (-not $SkipWinget -and $Silent) {
    if (-not (Test-WingetTask)) {
        Step 'Installing the elevated winget task (one-time UAC prompt)'
        gsudo pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\lib\winget-upgrade-setup.ps1')
    }
    if (-not (Test-WingetTask)) {
        Write-Host 'ERROR: the winget task is not installed - skipping winget.' -ForegroundColor Red
        $failed += 'winget task setup'
    } else {
        Step 'winget upgrade --all (silent, elevated)'
        $log      = Join-Path $taskDir 'winget-upgrade.log'
        $exitFile = Join-Path $taskDir 'winget-upgrade.exitcode'
        $started  = Get-Date
        Start-ScheduledTask -TaskPath $taskPath -TaskName $taskName
        $pos = 0; $pending = ''
        # Done when the runner writes its exit code; the task state alone races with a just-started task.
        while (-not ((Test-Path $exitFile) -and (Get-Item $exitFile).LastWriteTime -ge $started)) {
            Start-Sleep -Milliseconds 500
            if ((Test-Path $log) -and (Get-Item $log).LastWriteTime -ge $started) { Show-Log $log ([ref]$pos) ([ref]$pending) }
            $state = (Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName).State
            if ($state -ne 'Running' -and ((Get-Date) - $started).TotalSeconds -gt 15) { break }
        }
        Show-Log $log ([ref]$pos) ([ref]$pending) -Final

        $code = ((Test-Path $exitFile) -and (Get-Item $exitFile).LastWriteTime -ge $started) ? [int](Get-Content $exitFile) : $null
        # 0x8A15002B: no applicable upgrade
        if ($code -notin 0, -1978335189) {
            Write-Host "ERROR: winget upgrade failed (exit code $code)." -ForegroundColor Red
            $failed += 'winget upgrade'
        }
    }
}

if (-not $SkipMise) {
    Step 'mise self-update'
    mise self-update --yes
    if ($LASTEXITCODE -ne 0) { $failed += 'mise self-update' }

    # Old versions are kept: a running tool (e.g. claude) locks its files on Windows. Clean up later with `mise prune`.
    Step 'mise upgrade'
    mise upgrade --yes --no-prune
    if ($LASTEXITCODE -ne 0) { $failed += 'mise upgrade' }
}

if ($failed) {
    Write-Host "`nERROR: failed: $($failed -join ', ')." -ForegroundColor Red
    exit 1
}
Write-Host "`nEverything is up to date." -ForegroundColor Green
