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
    if ($configured.Count -ne 1) { Fail "Podaj dystrybucje: mise run wsl:restore -- -Distro <nazwa> (skonfigurowane: $($configured -join ', '))." }
    $Distro = $configured[0]
}

# --- Pick the backup ---
if (-not $File) {
    Assert-Config @{ WSL_BACKUP_DIR = $BackupDir }
    $dir = Join-Path $BackupDir $Distro
    if (-not (Test-Path $dir)) { Fail "Brak katalogu $dir (czy dysk jest podpiety?)." }
    $idx, $what = $Previous ? (1, 'poprzedniej') : (0, 'zadnej')
    $backups = @(Get-ChildItem $dir -Filter '*.tar.gz' | Sort-Object Name -Descending)
    if ($backups.Count -le $idx) { Fail "Brak $what kopii '$Distro' w $dir." }
    $File = $backups[$idx].FullName
}
$archive = Get-Item $File -ErrorAction SilentlyContinue
if (-not $archive) { Fail "Nie znaleziono pliku $File." }

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

Write-Host ('Kopia:       {0} ({1:N1} GB, {2})' -f $archive.FullName, ($archive.Length / 1GB), $archive.LastWriteTime)
Write-Host "Dystrybucja: $Distro $($info ? '(ISTNIEJE - zostanie USUNIETA)' : '(nowa)')"
Write-Host "Lokalizacja: $InstallDir"

if (-not $Force) {
    $answer = Read-Host "`nWpisz nazwe dystrybucji ($Distro), aby kontynuowac"
    if ($answer -cne $Distro) { Write-Host 'Anulowano.'; exit 1 }
}

# --- Verify the archive BEFORE removing the distro ---
# The listing (hundreds of thousands of lines) goes straight to a null stream, bypassing the PowerShell pipeline.
Write-Host "`nSprawdzanie integralnosci archiwum (kilka minut)..."
$psi = New-Object Diagnostics.ProcessStartInfo "$env:SystemRoot\System32\tar.exe", "-tzf `"$($archive.FullName)`""
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$tar = [Diagnostics.Process]::Start($psi)
$tar.StandardOutput.BaseStream.CopyTo([IO.Stream]::Null)
$tar.WaitForExit()
if ($tar.ExitCode -ne 0) { Fail 'Archiwum jest uszkodzone - nic nie zostalo zmienione.' }
Write-Host 'Archiwum OK.' -ForegroundColor Green

# --- Replace the distro ---
$dockerWasRunning = $false
try {
    $dockerWasRunning = Stop-DockerAndWsl
    if ($info) {
        wsl --unregister $Distro
        if ($LASTEXITCODE -ne 0) { Fail "wsl --unregister zakonczyl sie kodem $LASTEXITCODE." }
    }
    New-Item -ItemType Directory -Force $InstallDir | Out-Null

    Write-Host "Import '$Distro' do $InstallDir..."
    wsl --import $Distro $InstallDir $archive.FullName
    if ($LASTEXITCODE -ne 0) { Fail "wsl --import zakonczyl sie kodem $LASTEXITCODE. Sprobuj recznie: wsl --import $Distro `"$InstallDir`" `"$($archive.FullName)`"" }

    wsl --manage $Distro --set-sparse true
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Nie wlaczono sparse. Jesli chcesz: wsl --manage $Distro --set-sparse true --allow-unsafe" -ForegroundColor Yellow
    }

    wsl -d $Distro -- bash -c 'echo "Uzytkownik: $(whoami)"; df -h /'
    if ($LASTEXITCODE -ne 0) { Fail 'Dystrybucja nie uruchomila sie po imporcie.' }
    wsl --set-default $Distro | Out-Null
} finally {
    if ($dockerWasRunning) { Start-DockerDesktop }
}

Write-Host "`nOdtworzono '$Distro'." -ForegroundColor Green
