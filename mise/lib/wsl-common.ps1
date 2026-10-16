# Shared functions for the wsl:* mise tasks - dot-sourced from tasks\wsl\*.ps1.
# Lives outside the tasks directory so mise doesn't treat it as a task.

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'   # readable output from wsl.exe

$DockerProcesses = 'Docker Desktop', 'com.docker.backend'

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# Settings come from [env] in ~/.config/mise/config.local.toml; task arguments override them.
function Assert-Config([hashtable]$Settings) {
    $missing = @($Settings.Keys | Where-Object { -not $Settings[$_] })
    if ($missing) { Fail "Missing settings: $($missing -join ', '). Set them in the [env] section of ~/.config/mise/config.local.toml or pass them as arguments." }
}

# "Ubuntu, Ubuntu-OpenRig" -> 'Ubuntu', 'Ubuntu-OpenRig'. Wrap the result in @(), since PowerShell unwraps single-element arrays.
function Split-List($value) { $value -split ',' | ForEach-Object Trim | Where-Object { $_ } }

# Distro BasePath and .vhdx path from the registry (wsl.exe doesn't expose them); $null if it doesn't exist.
function Get-DistroInfo($Distro) {
    $p = Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss |
        ForEach-Object { Get-ItemProperty $_.PSPath } |
        Where-Object DistributionName -eq $Distro
    if (-not $p) { return }
    $base = $p.BasePath -replace '^\\\\\?\\', ''
    [pscustomobject]@{ BasePath = $base; VhdPath = Join-Path $base $p.VhdFileName }
}

# Stops Docker Desktop (if running) and all of WSL. Returns $true if Docker was running.
# The caller restarts Docker in a finally block via Start-DockerDesktop.
function Stop-DockerAndWsl {
    $wasRunning = [bool](Get-Process $DockerProcesses -ErrorAction SilentlyContinue)
    if ($wasRunning) {
        Write-Host 'Stopping Docker Desktop...'
        docker desktop stop --timeout 120 | Out-Host
        if ($LASTEXITCODE -ne 0) { Get-Process $DockerProcesses -ErrorAction SilentlyContinue | Stop-Process -Force }
    }
    Write-Host 'Stopping WSL...'
    wsl --shutdown | Out-Host
    $wasRunning
}

function Start-DockerDesktop {
    Write-Host 'Starting Docker Desktop...'
    docker desktop start --detach | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Host 'Failed to start Docker Desktop - start it manually.' -ForegroundColor Yellow }
}
