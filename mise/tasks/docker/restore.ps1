#Requires -Version 7.4
#MISE description="Restore a Docker volume from a backup (newest by default)"
# Usage: mise run docker:restore -- -Volume <name> [-Previous | -File <path.tar.zst>] [-Force]
# -BackupDir defaults to DOCKER_BACKUP_DIR from ~/.config/mise/config.local.toml (backups in <dir>\<volume>\).
# WARNING: replaces the volume's contents with the backup; creates the volume if it doesn't exist.
# Running containers that use the volume are stopped during the restore, then started again.
# Requires Docker Desktop running and zstd (winget install Meta.Zstandard).

param(
    [Parameter(Mandatory)][string]$Volume,
    [string]$BackupDir = $env:DOCKER_BACKUP_DIR,
    [string]$File,
    [switch]$Previous,
    [switch]$Force
)

. "$PSScriptRoot\..\..\lib\wsl-common.ps1"

$zstd = Get-Zstd

# --- Pick the backup ---
if (-not $File) {
    Assert-Config @{ DOCKER_BACKUP_DIR = $BackupDir }
    $dir = [IO.Path]::Combine($BackupDir, $Volume)   # Join-Path throws on a missing drive
    if (-not (Test-Path $dir)) { Fail "Directory $dir not found (is the drive connected?)." }
    $idx, $what = $Previous ? (1, 'previous') : (0, 'any')
    $backups = @(Get-Backups $dir | Where-Object Name -like '*.tar.zst')
    if ($backups.Count -le $idx) { Fail "No $what backup of '$Volume' in $dir." }
    $File = $backups[$idx].FullName
}
$archive = Get-Item $File -ErrorAction SilentlyContinue
if (-not $archive) { Fail "File $File not found." }
if ($archive.Name -notlike '*.tar.zst') { Fail "Unknown backup format: $($archive.Name) (expected .tar.zst)." }

docker info --format '{{.ServerVersion}}' *> $null
if ($LASTEXITCODE -ne 0) { Fail 'Docker is not running - start Docker Desktop.' }
$exists = $Volume -in @(docker volume ls --format '{{.Name}}')

Write-Host ('Backup: {0} ({1}, {2})' -f $archive.FullName, (Format-Size $archive.Length), $archive.LastWriteTime)
Write-Host "Volume: $Volume $($exists ? '(EXISTS - contents will be REPLACED)' : '(new)')"

if (-not $Force) {
    $answer = Read-Host "`nType the volume name ($Volume) to continue"
    if ($answer -cne $Volume) { Write-Host 'Cancelled.'; exit 1 }
}

# --- Verify the archive BEFORE touching the volume: zstd checksum, then the tar structure ---
Write-Host "`nVerifying archive..."
& $zstd -t -q $archive.FullName
$ok = $LASTEXITCODE -eq 0
if ($ok) {
    $codes = Invoke-BytePipe ($zstd, '-d', '-c', '-q', $archive.FullName) ('docker.exe', 'run', '--rm', '-i', 'debian:stable-slim', 'sh', '-c', 'tar -tf - > /dev/null')
    $ok = -not ($codes -ne 0)
}
if (-not $ok) { Fail 'The archive is corrupted - nothing was changed.' }
Write-Host 'Archive OK.' -ForegroundColor Green

# --- Replace the contents ---
$running = @(Stop-Containers $Volume)
try {
    if (-not $exists) {
        docker volume create $Volume | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "docker volume create failed with exit code $LASTEXITCODE." }
    }
    Write-Host "Restoring '$Volume'..."
    $codes = Invoke-BytePipe ($zstd, '-d', '-c', '-q', $archive.FullName) ('docker.exe', 'run', '--rm', '-i', '-v', "${Volume}:/v", 'debian:stable-slim', 'sh', '-c', 'find /v -mindepth 1 -delete && tar --numeric-owner -C /v -xpf -')
    if ($codes -ne 0) { Fail "Restore failed (zstd exit $($codes[0]), tar exit $($codes[1])). The volume may be incomplete - run the restore again." }
} finally {
    if ($running) { docker start $running | Out-Null }
}

Write-Host "`nRestored '$Volume'." -ForegroundColor Green
