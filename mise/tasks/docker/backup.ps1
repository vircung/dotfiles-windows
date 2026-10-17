#Requires -Version 7.4
#MISE description="Back up Docker volumes (tar.zst, rotated per DOCKER_BACKUP_KEEP)"
# Usage: mise run docker:backup [-- -Volume claude-home-sii,shell-history-default -BackupDir D:\backup\docker -Keep 2]
# Defaults: DOCKER_BACKUP_VOLUMES, DOCKER_BACKUP_DIR, DOCKER_BACKUP_KEEP from ~/.config/mise/config.local.toml.
# DOCKER_BACKUP_VOLUMES = '*' backs up all named volumes (anonymous ones are skipped).
# Each volume is packed by tar in a throwaway debian:stable-slim container (GNU tar) and compressed with zstd on the host.
# Running containers that use a volume are stopped during its backup (consistent files), then started again.
# Requires Docker Desktop running and zstd (winget install Meta.Zstandard).

param(
    [string]$Volume    = $env:DOCKER_BACKUP_VOLUMES,
    [string]$BackupDir = $env:DOCKER_BACKUP_DIR,
    [int]   $Keep      = $env:DOCKER_BACKUP_KEEP
)

. "$PSScriptRoot\..\..\lib\wsl-common.ps1"

Assert-Config @{ DOCKER_BACKUP_VOLUMES = $Volume; DOCKER_BACKUP_DIR = $BackupDir; DOCKER_BACKUP_KEEP = $Keep }
$zstd = Get-Zstd

# --- Target drive ---
$drive = [IO.DriveInfo](Split-Path $BackupDir -Qualifier)
if (-not $drive.IsReady) { Fail "Drive $($drive.Name) is not connected." }

# --- Docker and volumes ---
docker info --format '{{.ServerVersion}}' *> $null
if ($LASTEXITCODE -ne 0) { Fail 'Docker is not running - start Docker Desktop.' }

$existing = @(docker volume ls --format '{{.Name}}')
if ($Volume.Trim() -eq '*') {
    $names = @($existing | Where-Object { $_ -notmatch '^[0-9a-f]{64}$' })
} else {
    $names = @(Split-List $Volume)
    $missing = @($names | Where-Object { $_ -notin $existing })
    if ($missing) { Fail "Volume(s) not found: $($missing -join ', ')." }
}
if (-not $names) { Fail 'No volumes to back up.' }

# --- Back up each volume ---
# Same layout as wsl:backup: <dir>\<volume>\<volume>-<stamp>.tar.zst, written as .partial and renamed on success.
$stamp  = Get-Date -Format 'yyyy-MM-dd_HHmm'
$failed = @()
foreach ($name in $names) {
    Write-Host "`n[$name]"
    $dir     = Join-Path $BackupDir $name
    $final   = Join-Path $dir "$name-$stamp.tar.zst"
    $partial = "$final.partial"
    New-Item -ItemType Directory -Force $dir | Out-Null
    Get-ChildItem $dir -Filter '*.partial' | Remove-Item -Force

    $running = @(docker ps -q --filter "volume=$name")
    try {
        if ($running) {
            Write-Host "Stopping containers using it: $(docker ps --format '{{.Names}}' --filter "volume=$name")"
            docker stop $running | Out-Null
        }
        $codes = Invoke-BytePipe ('docker.exe', 'run', '--rm', '-v', "${name}:/v:ro", 'debian:stable-slim', 'tar', '--numeric-owner', '-C', '/v', '-cf', '-', '.') ($zstd, '-T0', '-3', '--check', '-q', '-f', '-o', $partial)
    } finally {
        if ($running) { docker start $running | Out-Null }
    }

    if ($codes -ne 0 -or -not (Get-Item $partial -ErrorAction SilentlyContinue).Length) {
        Remove-Item $partial -Force -ErrorAction SilentlyContinue
        Write-Host "ERROR: Backup failed (tar exit $($codes[0]), zstd exit $($codes[1])). Previous backups were left untouched." -ForegroundColor Red
        $failed += $name
        continue
    }
    $backup = Rename-Item $partial (Split-Path $final -Leaf) -PassThru
    Write-Host "OK: $(Format-Size $backup.Length)" -ForegroundColor Green

    $all = Get-Backups $dir
    $all | Select-Object -Skip $Keep | ForEach-Object {
        Write-Host "Removing old backup: $($_.Name)"
        Remove-Item $_.FullName -Force
    }
    $all | Select-Object -First $Keep | ForEach-Object { '  {0}  {1,10}' -f $_.Name, (Format-Size $_.Length) }
}

if ($failed) { Fail "Backup failed for: $($failed -join ', ')." }
