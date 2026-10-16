#Requires -Version 7.4
#MISE description="Restore a WSL distro from a backup (newest by default)"
# Usage: mise run wsl:restore [-- -Distro Ubuntu] [-Previous | -File <path.tar.gz>] [-InstallDir C:\WSL\Ubuntu] [-Force]
# Defaults from ~/.config/mise/config.local.toml:
#   -Distro      the only distro in WSL_BACKUP_DISTROS (required if there are several)
#   -BackupDir   WSL_BACKUP_DIR (backups in <dir>\<distro>\)
#   -InstallDir  the distro's current location, or WSL_DISTRO_DIR\<distro> if it doesn't exist
# WARNING: removes the current distro (wsl --unregister) and replaces it with the backup.
# Stops Docker Desktop and WSL during the restore, then restarts Docker.

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
    $dir = Join-Path $BackupDir $Distro
    if (-not (Test-Path $dir)) { Fail "Directory $dir not found (is the drive connected?)." }
    $idx, $what = $Previous ? (1, 'previous') : (0, 'any')
    $backups = @(Get-ChildItem $dir -Filter '*.tar.gz' | Sort-Object Name -Descending)
    if ($backups.Count -le $idx) { Fail "No $what backup of '$Distro' in $dir." }
    $File = $backups[$idx].FullName
}
$archive = Get-Item $File -ErrorAction SilentlyContinue
if (-not $archive) { Fail "File $File not found." }

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

Write-Host ('Backup:   {0} ({1:N1} GB, {2})' -f $archive.FullName, ($archive.Length / 1GB), $archive.LastWriteTime)
Write-Host "Distro:   $Distro $($info ? '(EXISTS - will be REMOVED)' : '(new)')"
Write-Host "Location: $InstallDir"

if (-not $Force) {
    $answer = Read-Host "`nType the distro name ($Distro) to continue"
    if ($answer -cne $Distro) { Write-Host 'Cancelled.'; exit 1 }
}

# --- Verify the archive BEFORE removing the distro ---
# The listing (hundreds of thousands of lines) goes straight to a null stream, bypassing the PowerShell pipeline.
Write-Host "`nVerifying archive integrity (takes a few minutes)..."
$psi = New-Object Diagnostics.ProcessStartInfo "$env:SystemRoot\System32\tar.exe", "-tzf `"$($archive.FullName)`""
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$tar = [Diagnostics.Process]::Start($psi)
$tar.StandardOutput.BaseStream.CopyTo([IO.Stream]::Null)
$tar.WaitForExit()
if ($tar.ExitCode -ne 0) { Fail 'The archive is corrupted - nothing was changed.' }
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
    wsl --import $Distro $InstallDir $archive.FullName
    if ($LASTEXITCODE -ne 0) { Fail "wsl --import failed with exit code $LASTEXITCODE. Try manually: wsl --import $Distro `"$InstallDir`" `"$($archive.FullName)`"" }

    wsl --manage $Distro --set-sparse true
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Sparse VHD not enabled. To force it: wsl --manage $Distro --set-sparse true --allow-unsafe" -ForegroundColor Yellow
    }

    wsl -d $Distro -- bash -c 'echo "User: $(whoami)"; df -h /'
    if ($LASTEXITCODE -ne 0) { Fail 'The distro failed to start after the import.' }
    wsl --set-default $Distro | Out-Null
} finally {
    if ($dockerWasRunning) { Start-DockerDesktop }
}

Write-Host "`nRestored '$Distro'." -ForegroundColor Green
