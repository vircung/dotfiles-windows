#Requires -Version 7.4
#MISE description="Back up WSL distros (vhdx.zst, rotated per WSL_BACKUP_KEEP)"
# Usage: mise run wsl:backup [-- -Distro Ubuntu,Ubuntu-OpenRig -BackupDir D:\backup\wsl -Keep 2 -Live]
# Defaults: WSL_BACKUP_DISTROS, WSL_BACKUP_DIR, WSL_BACKUP_KEEP from ~/.config/mise/config.local.toml.
# By default stops Docker Desktop and WSL, compresses the distro's ext4.vhdx with zstd (all cores),
# then restarts Docker. Copying the whole disk image is several times faster than wsl --export.
# -Live: nothing is stopped; wsl --export (a tar of the running distro) is piped through zstd instead,
# since an image of a running distro's disk could be inconsistent.
# -Zstd (WSL_BACKUP_ZSTD, default '-3 --long'): zstd compression options, e.g. '-6 --long'.
# Requires zstd (winget install Meta.Zstandard).

param(
    [string]$Distro    = $env:WSL_BACKUP_DISTROS,
    [string]$BackupDir = $env:WSL_BACKUP_DIR,
    [int]   $Keep      = $env:WSL_BACKUP_KEEP,
    [string]$Zstd      = $env:WSL_BACKUP_ZSTD,
    [switch]$Live
)

. "$PSScriptRoot\..\..\lib\wsl-common.ps1"

Assert-Config @{ WSL_BACKUP_DISTROS = $Distro; WSL_BACKUP_DIR = $BackupDir; WSL_BACKUP_KEEP = $Keep }
$zstdExe  = Get-Zstd
$zstdArgs = @('-T0') + @(($Zstd ? $Zstd : '-3 --long') -split '\s+' | Where-Object { $_ }) + '--check'
$ext      = $Live ? 'tar.zst' : 'vhdx.zst'

# --- Target drive ---
# DriveInfo doesn't take UNC paths; a \\server\share target is only checked for being reachable.
$root  = [IO.Path]::GetPathRoot($BackupDir)
$drive = $root -like '\\*' ? $null : [IO.DriveInfo]$root
if ($drive ? -not $drive.IsReady : -not (Test-Path $root)) { Fail "Drive $root is not connected." }

# --- Distros ---
# Each distro has its own subdirectory, so rotating "Ubuntu" doesn't touch "Ubuntu-OpenRig" backups.
# Write to a .partial file and rename only on success: a failed backup never displaces good ones.
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$jobs = [Collections.Generic.List[object]]::new()
foreach ($name in Split-List $Distro) {
    $info = Get-DistroInfo $name
    if (-not $info) { Fail "Distro '$name' not found." }
    $dir   = Join-Path $BackupDir $name
    $final = Join-Path $dir "$name-$stamp.$ext"
    $jobs.Add([pscustomobject]@{ Distro = $name; Dir = $dir; Final = $final; Partial = "$final.partial"; Vhd = $info.VhdPath; Exit = $null })
}

# The .vhdx size is an upper bound on the compressed backup size - no need to start the distro.
$needGB = [math]::Ceiling(($jobs | ForEach-Object { (Get-Item $_.Vhd).Length } | Measure-Object -Sum).Sum / 1GB) + 5
# shortcut: no free-space check on a UNC target, add GetDiskFreeSpaceEx if backups to a share run out of space.
if ($drive) {
    $freeGB = [math]::Floor($drive.AvailableFreeSpace / 1GB)
    if ($freeGB -lt $needGB) { Fail "Not enough space on $($drive.Name): $freeGB GB free, ~$needGB GB needed." }
}

foreach ($job in $jobs) {
    New-Item -ItemType Directory -Force $job.Dir | Out-Null
    Get-ChildItem $job.Dir -Filter '*.partial' | Remove-Item -Force
}

# --- Export ---
$dockerWasRunning = $false
try {
    if (-not $Live) { $dockerWasRunning = Stop-DockerAndWsl }
    foreach ($job in $jobs) {
        Write-Host "`nBacking up '$($job.Distro)' -> $($job.Final) (takes several minutes)"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        if ($Live) {
            $codes = Invoke-BytePipe ('wsl.exe', '--export', $job.Distro, '-') (@($zstdExe) + $zstdArgs + '-q', '-f', '-o', $job.Partial)
            $job.Exit = ($codes | Where-Object { $_ -ne 0 } | Select-Object -First 1) ?? 0
        } else {
            & $zstdExe @zstdArgs -f $job.Vhd -o $job.Partial
            $job.Exit = $LASTEXITCODE
        }
        Write-Host ('Time: {0:N1} min' -f $sw.Elapsed.TotalMinutes)
    }
} finally {
    if ($dockerWasRunning) { Start-DockerDesktop }
}

# --- Commit and rotate ---
$failed = @()
foreach ($job in $jobs) {
    Write-Host "`n[$($job.Distro)]"
    if (-not (Complete-Backup $job.Partial $job.Final $Keep ($job.Exit -eq 0))) {
        Write-Host "ERROR: Backup failed with exit code $($job.Exit). Previous backups were left untouched." -ForegroundColor Red
        $failed += $job.Distro
    }
}

if ($failed) { Fail "Backup failed for: $($failed -join ', ')." }
