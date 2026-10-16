#Requires -Version 7.4
#MISE description="Back up WSL distros (tar.gz, rotated per WSL_BACKUP_KEEP)"
# Usage: mise run wsl:backup [-- -Distro Ubuntu,Ubuntu-OpenRig -BackupDir D:\backup\wsl -Keep 2 -Live]
# Defaults: WSL_BACKUP_DISTROS, WSL_BACKUP_DIR, WSL_BACKUP_KEEP from ~/.config/mise/config.local.toml.
# By default stops Docker Desktop and WSL during the export (consistent snapshot), then restarts Docker.
# -Live: export without stopping anything.

param(
    [string]$Distro    = $env:WSL_BACKUP_DISTROS,
    [string]$BackupDir = $env:WSL_BACKUP_DIR,
    [int]   $Keep      = $env:WSL_BACKUP_KEEP,
    [switch]$Live
)

. "$PSScriptRoot\..\..\lib\wsl-common.ps1"

Assert-Config @{ WSL_BACKUP_DISTROS = $Distro; WSL_BACKUP_DIR = $BackupDir; WSL_BACKUP_KEEP = $Keep }

# --- Target drive ---
$drive = [IO.DriveInfo](Split-Path $BackupDir -Qualifier)
if (-not $drive.IsReady) { Fail "Drive $($drive.Name) is not connected." }

# --- Distros ---
# Each distro has its own subdirectory, so rotating "Ubuntu" doesn't touch "Ubuntu-OpenRig" backups.
# Write to a .partial file and rename only on success: a failed backup never displaces good ones.
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$jobs = [Collections.Generic.List[object]]::new()
foreach ($name in Split-List $Distro) {
    $info = Get-DistroInfo $name
    if (-not $info) { Fail "Distro '$name' not found." }
    $dir   = Join-Path $BackupDir $name
    $final = Join-Path $dir "$name-$stamp.tar.gz"
    $jobs.Add([pscustomobject]@{ Distro = $name; Dir = $dir; Final = $final; Partial = "$final.partial"; Vhd = $info.VhdPath; Exit = $null })
}

# The .vhdx size is an upper bound on the compressed backup size - no need to start the distro.
$needGB = [math]::Ceiling(($jobs | ForEach-Object { (Get-Item $_.Vhd).Length } | Measure-Object -Sum).Sum / 1GB) + 5
$freeGB = [math]::Floor($drive.AvailableFreeSpace / 1GB)
if ($freeGB -lt $needGB) { Fail "Not enough space on $($drive.Name): $freeGB GB free, ~$needGB GB needed." }

foreach ($job in $jobs) {
    New-Item -ItemType Directory -Force $job.Dir | Out-Null
    Get-ChildItem $job.Dir -Filter '*.partial' | Remove-Item -Force
}

# --- Export ---
$dockerWasRunning = $false
try {
    if (-not $Live) { $dockerWasRunning = Stop-DockerAndWsl }
    foreach ($job in $jobs) {
        Write-Host "`nExporting '$($job.Distro)' -> $($job.Final) (takes several minutes)"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        wsl --export $job.Distro $job.Partial --format tar.gz
        $job.Exit = $LASTEXITCODE
        Write-Host ('Time: {0:N1} min' -f $sw.Elapsed.TotalMinutes)
    }
} finally {
    if ($dockerWasRunning) { Start-DockerDesktop }
}

# --- Commit and rotate ---
$failed = @()
foreach ($job in $jobs) {
    Write-Host "`n[$($job.Distro)]"
    if ($job.Exit -ne 0 -or -not (Get-Item $job.Partial -ErrorAction SilentlyContinue).Length) {
        Remove-Item $job.Partial -Force -ErrorAction SilentlyContinue
        Write-Host "ERROR: wsl --export failed with exit code $($job.Exit). Previous backups were left untouched." -ForegroundColor Red
        $failed += $job.Distro
        continue
    }
    $backup = Rename-Item $job.Partial (Split-Path $job.Final -Leaf) -PassThru
    Write-Host ('OK: {0:N1} GB' -f ($backup.Length / 1GB)) -ForegroundColor Green

    $all = @(Get-ChildItem $job.Dir -Filter '*.tar.gz' | Sort-Object Name -Descending)
    $all | Select-Object -Skip $Keep | ForEach-Object {
        Write-Host "Removing old backup: $($_.Name)"
        Remove-Item $_.FullName -Force
    }
    $all | Select-Object -First $Keep | ForEach-Object { '  {0}  {1,6:N1} GB' -f $_.Name, ($_.Length / 1GB) }
}

if ($failed) { Fail "Backup failed for: $($failed -join ', ')." }
