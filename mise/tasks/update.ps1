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
# Reads up to the last LF byte only, so a line or a UTF-8 character is never split between reads.
function Show-Log([string]$Path, [ref]$Position, [switch]$Final) {
    if (-not (Test-Path $Path)) { return }
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -lt $Position.Value) { $Position.Value = 0 }   # truncated by a new run
        $fs.Position = $Position.Value
        $bytes = [byte[]]::new($fs.Length - $Position.Value)
        $n = $fs.Read($bytes, 0, $bytes.Length)
    } finally { $fs.Dispose() }
    if ($n -eq 0) { return }
    $end = $Final ? $n : [Array]::LastIndexOf($bytes, [byte]10, $n - 1) + 1
    $Position.Value += $end
    [Text.Encoding]::UTF8.GetString($bytes, 0, $end) -split "`r|`n" | Where-Object { $_.Trim() -and $_ -notmatch '^\s*[-\\|/]\s*$' -and $_ -notmatch '[\u2588\u2592]' } |
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
        $pos = 0
        # Done when the runner writes its exit code; the task state alone races with a just-started task.
        while (-not ((Test-Path $exitFile) -and (Get-Item $exitFile).LastWriteTime -ge $started)) {
            Start-Sleep -Milliseconds 500
            if ((Test-Path $log) -and (Get-Item $log).LastWriteTime -ge $started) { Show-Log $log ([ref]$pos) }
            $state = (Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName).State
            if ($state -ne 'Running' -and ((Get-Date) - $started).TotalSeconds -gt 15) { break }
        }
        Show-Log $log ([ref]$pos) -Final

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
