#Requires -Version 7.4
#MISE description="Restore everything from the newest backups: Docker volumes, then WSL distros"
# Usage: mise run restore [-- -Previous] [-SkipDocker] [-SkipWsl] [-Force]
# Restores every volume in DOCKER_BACKUP_VOLUMES ('*' = every volume with a backup in DOCKER_BACKUP_DIR)
# and every distro in WSL_BACKUP_DISTROS. Docker volumes go first, while Docker is still running;
# wsl:restore stops Docker and WSL. Asks for confirmation once (-Force skips it), then runs each
# restore with -Force; each still verifies its archive before changing anything.
# WARNING: replaces the distros and the volumes' contents. A failed step doesn't stop the next one.

param(
    [switch]$Previous,
    [switch]$SkipDocker,
    [switch]$SkipWsl,
    [switch]$Force
)

. "$PSScriptRoot\..\lib\wsl-common.ps1"

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

$volumes = @()
if (-not $SkipDocker) {
    Assert-Config @{ DOCKER_BACKUP_VOLUMES = $env:DOCKER_BACKUP_VOLUMES; DOCKER_BACKUP_DIR = $env:DOCKER_BACKUP_DIR }
    if ($env:DOCKER_BACKUP_VOLUMES.Trim() -eq '*') {
        if (-not (Test-Path $env:DOCKER_BACKUP_DIR)) { Fail "Directory $($env:DOCKER_BACKUP_DIR) not found (is the drive connected?)." }
        $volumes = @(Get-ChildItem $env:DOCKER_BACKUP_DIR -Directory | ForEach-Object Name)
    } else {
        $volumes = @(Split-List $env:DOCKER_BACKUP_VOLUMES)
    }
}
$distros = @()
if (-not $SkipWsl) {
    Assert-Config @{ WSL_BACKUP_DISTROS = $env:WSL_BACKUP_DISTROS }
    $distros = @(Split-List $env:WSL_BACKUP_DISTROS)
}
if (-not ($volumes + $distros)) { Fail 'Nothing to restore.' }

$which = $Previous ? 'previous' : 'newest'
Write-Host "Restoring from the $which backups:"
if ($volumes) { Write-Host "  Docker volumes (contents REPLACED): $($volumes -join ', ')" }
if ($distros) { Write-Host "  WSL distros (REMOVED and re-imported): $($distros -join ', ')" }

if (-not $Force) {
    $answer = Read-Host "`nType 'restore' to continue"
    if ($answer -cne 'restore') { Write-Host 'Cancelled.'; exit 1 }
}

$extra  = @('-Force') + ($Previous ? @('-Previous') : @())
$failed = @()

# Each task runs in its own process: they end with `exit`, which would end this script too.
# Containers are stopped once for all volumes (docker:restore then finds none running), so none
# starts with only some of its volumes restored.
$running = @($volumes | ForEach-Object { docker ps -q --filter "volume=$_" 2>$null } | Sort-Object -Unique)
try {
    if ($running) {
        Step 'Stopping containers that use the volumes'
        docker stop $running | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "docker stop failed with exit code $LASTEXITCODE." }
    }
    foreach ($v in $volumes) {
        Step "Docker volume: $v"
        pwsh -NoProfile -File "$PSScriptRoot\docker\restore.ps1" -Volume $v @extra
        if ($LASTEXITCODE -ne 0) { $failed += "volume $v" }
    }
} finally {
    if ($running) { docker start $running | Out-Null }
}
foreach ($d in $distros) {
    Step "WSL distro: $d"
    pwsh -NoProfile -File "$PSScriptRoot\wsl\restore.ps1" -Distro $d @extra
    if ($LASTEXITCODE -ne 0) { $failed += "distro $d" }
}

if ($failed) { Fail "Failed: $($failed -join ', ')." }
Write-Host "`nRestore complete." -ForegroundColor Green
