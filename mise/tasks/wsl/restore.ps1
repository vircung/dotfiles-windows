#Requires -Version 7.4
#MISE description="Restore a WSL distro from a backup (newest by default)"
# Usage: mise run wsl:restore [-- -Distro Ubuntu] [-Previous | -File <path>] [-InstallDir C:\WSL\Ubuntu] [-Force]
# Defaults from ~/.config/mise/config.local.toml:
#   -Distro      the only distro in WSL_BACKUP_DISTROS (required if there are several)
#   -BackupDir   WSL_BACKUP_DIR (backups in <dir>\<distro>\)
#   -InstallDir  the distro's current location, or WSL_DISTRO_DIR\<distro> if it doesn't exist
# Backups: .vhdx.zst (disk image), .tar.zst (-Live backup) or .tar.gz (older backups).
# WARNING: removes the current distro (wsl --unregister) and replaces it with the backup.
# Stops Docker Desktop and WSL during the restore, then restarts Docker.
# Requires zstd for .zst backups (winget install Meta.Zstandard).

param(
    [string]$Distro,
    [string]$BackupDir  = $env:WSL_BACKUP_DIR,
    [string]$File,
    [switch]$Previous,
    [string]$InstallDir,
    [switch]$Force
)

. "$PSScriptRoot\..\..\lib\wsl-common.ps1"

if (-not $Distro) {
    $configured = @(Split-List $env:WSL_BACKUP_DISTROS)
    if ($configured.Count -ne 1) { Fail "Specify the distro: mise run wsl:restore -- -Distro <name> (configured: $($configured -join ', '))." }
    $Distro = $configured[0]
}

# --- Pick the backup ---
if (-not $File) {
    Assert-Config @{ WSL_BACKUP_DIR = $BackupDir }
    $dir = [IO.Path]::Combine($BackupDir, $Distro)   # Join-Path throws on a missing drive
    if (-not (Test-Path $dir)) { Fail "Directory $dir not found (is the drive connected?)." }
    $idx, $what = $Previous ? (1, 'previous') : (0, 'any')
    $backups = Get-Backups $dir
    if ($backups.Count -le $idx) { Fail "No $what backup of '$Distro' in $dir." }
    $File = $backups[$idx].FullName
}
$archive = Get-Item $File -ErrorAction SilentlyContinue
if (-not $archive) { Fail "File $File not found." }
$format = switch -Regex ($archive.Name) {
    '\.vhdx\.zst$' { 'vhdx.zst' }
    '\.tar\.zst$'  { 'tar.zst' }
    '\.tar\.gz$'   { 'tar.gz' }
    default        { Fail "Unknown backup format: $($archive.Name) (expected .vhdx.zst, .tar.zst or .tar.gz)." }
}
# --long=31 allows any window size, so backups made with WSL_BACKUP_ZSTD='... --long' decompress too.
if ($format -like '*.zst') { $zstd = Get-Zstd; $zstdLong = '--long=31' }

# --- Install location: the distro's current location or WSL_DISTRO_DIR\<distro> ---
$info = Get-DistroInfo $Distro
if (-not $InstallDir) {
    if ($info) {
        $InstallDir = $info.BasePath
    } else {
        Assert-Config @{ WSL_DISTRO_DIR = $env:WSL_DISTRO_DIR }
        $InstallDir = Join-Path $env:WSL_DISTRO_DIR $Distro
    }
}

# Every format ends up as <InstallDir>\ext4.vhdx; unregistering the distro deletes only its own current disk.
$vhd = Join-Path $InstallDir 'ext4.vhdx'
if ((Test-Path $vhd) -and -not ($info -and $info.VhdPath -eq $vhd)) { Fail "$vhd already exists and doesn't belong to '$Distro' - remove it or pick another -InstallDir." }

# A .vhdx backup is decompressed straight into place.
if ($format -eq 'vhdx.zst') {
    # Decompressed size from the zstd frame header; free space counts the disk that unregister will delete.
    $size = Get-ZstdContentSize $archive.FullName
    if ($size) {
        $needGB = [math]::Ceiling($size / 1GB) + 1
        $drive  = [IO.DriveInfo](Split-Path ([IO.Path]::GetFullPath($InstallDir)) -Qualifier)
        $freed  = ($info -and (Split-Path $info.VhdPath -Qualifier) -eq $drive.Name.TrimEnd('\')) ? (Get-AllocatedSize $info.VhdPath) : 0
        $freeGB = [math]::Floor(($drive.AvailableFreeSpace + $freed) / 1GB)
        if ($freeGB -lt $needGB) { Fail "Not enough space on $($drive.Name): $freeGB GB available (after removing the current distro), ~$needGB GB needed." }
    } else {
        Write-Host 'Decompressed size unknown - skipping the free space check.' -ForegroundColor Yellow
    }
}

Write-Host ('Backup:   {0} ({1:N1} GB, {2})' -f $archive.FullName, ($archive.Length / 1GB), $archive.LastWriteTime)
Write-Host "Distro:   $Distro $($info ? '(EXISTS - will be REMOVED)' : '(new)')"
Write-Host "Location: $InstallDir"

if (-not $Force) {
    $answer = Read-Host "`nType the distro name ($Distro) to continue"
    if ($answer -cne $Distro) { Write-Host 'Cancelled.'; exit 1 }
}

# --- Verify the archive BEFORE removing the distro ---
# Checksums only: listing the tar with Windows tar.exe fails on file names it can't convert.
Write-Host "`nVerifying archive integrity (takes a few minutes)..."
if ($format -eq 'tar.gz') {
    $ok = $true
    $in = [IO.File]::OpenRead($archive.FullName)
    try { ([IO.Compression.GZipStream]::new($in, [IO.Compression.CompressionMode]::Decompress)).CopyTo([IO.Stream]::Null, 1MB) }
    catch { $ok = $false }
    finally { $in.Dispose() }
} else {
    & $zstd -t -q $zstdLong $archive.FullName
    $ok = $LASTEXITCODE -eq 0
}
if (-not $ok) { Fail 'The archive is corrupted - nothing was changed.' }
Write-Host 'Archive OK.' -ForegroundColor Green

# --- Replace the distro ---
$dockerWasRunning = $false
try {
    $dockerWasRunning = Stop-DockerAndWsl
    if ($info) {
        wsl --unregister $Distro
        if ($LASTEXITCODE -ne 0) { Fail "wsl --unregister failed with exit code $LASTEXITCODE." }
    }
    New-Item -ItemType Directory -Force $InstallDir | Out-Null

    Write-Host "Importing '$Distro' into $InstallDir..."
    switch ($format) {
        'vhdx.zst' {
            & $zstd -d -f $zstdLong $archive.FullName -o $vhd
            if ($LASTEXITCODE -ne 0) {
                Remove-Item $vhd -Force -ErrorAction SilentlyContinue
                Fail "Decompressing the backup failed with exit code $LASTEXITCODE. The backup is intact; free up space on the drive and run the restore again."
            }
            wsl --import-in-place $Distro $vhd
            if ($LASTEXITCODE -ne 0) { Fail "wsl --import-in-place failed with exit code $LASTEXITCODE. Try manually: wsl --import-in-place $Distro `"$vhd`"" }
        }
        'tar.zst' {
            $codes = Invoke-BytePipe ($zstd, '-d', '-c', '-q', $zstdLong, $archive.FullName) ('wsl.exe', '--import', $Distro, $InstallDir, '-')
            if ($codes -ne 0) { Fail "Import failed (zstd exit $($codes[0]), wsl --import exit $($codes[1]))." }
        }
        'tar.gz' {
            wsl --import $Distro $InstallDir $archive.FullName
            if ($LASTEXITCODE -ne 0) { Fail "wsl --import failed with exit code $LASTEXITCODE. Try manually: wsl --import $Distro `"$InstallDir`" `"$($archive.FullName)`"" }
        }
    }

    wsl --manage $Distro --set-sparse true
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Sparse VHD not enabled. To force it: wsl --manage $Distro --set-sparse true --allow-unsafe" -ForegroundColor Yellow
    }

    # The decompressed disk image has its free space allocated too; trimming it shrinks the .vhdx if it's sparse.
    wsl -d $Distro -u root -- fstrim /
    wsl -d $Distro -- bash -c 'echo "User: $(whoami)"; df -h /'
    if ($LASTEXITCODE -ne 0) { Fail 'The distro failed to start after the import.' }
    # Unregistering moves the default to another distro; restore it only if this one was the default.
    if ($info.IsDefault) { wsl --set-default $Distro | Out-Null }
} finally {
    if ($dockerWasRunning) { Start-DockerDesktop }
}

Write-Host "`nRestored '$Distro'." -ForegroundColor Green
