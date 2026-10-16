#Requires -Version 7.4
#MISE description="Kopia zapasowa dystrybucji WSL (tar.gz, rotacja wg WSL_BACKUP_KEEP)"
# Uzycie: mise run wsl:backup [-- -Distro Ubuntu,Ubuntu-OpenRig -BackupDir D:\backup\wsl -Keep 2 -Live]
# Domyslne wartosci: WSL_BACKUP_DISTROS, WSL_BACKUP_DIR, WSL_BACKUP_KEEP z ~/.config/mise/config.local.toml.
# Domyslnie zatrzymuje Docker Desktop i WSL na czas eksportu (spojna kopia), potem uruchamia Dockera ponownie.
# -Live: eksport bez zatrzymywania czegokolwiek.

param(
    [string]$Distro    = $env:WSL_BACKUP_DISTROS,
    [string]$BackupDir = $env:WSL_BACKUP_DIR,
    [int]   $Keep      = $env:WSL_BACKUP_KEEP,
    [switch]$Live
)

. "$PSScriptRoot\..\..\lib\wsl-common.ps1"

Assert-Config @{ WSL_BACKUP_DISTROS = $Distro; WSL_BACKUP_DIR = $BackupDir; WSL_BACKUP_KEEP = $Keep }

# --- Dysk docelowy ---
$drive = [IO.DriveInfo](Split-Path $BackupDir -Qualifier)
if (-not $drive.IsReady) { Fail "Dysk $($drive.Name) nie jest podpiety." }

# --- Dystrybucje ---
# Kazda dystrybucja ma wlasny podkatalog, wiec rotacja "Ubuntu" nie dotyka kopii "Ubuntu-OpenRig".
# Zapis do pliku .partial i zmiana nazwy dopiero po sukcesie: nieudana kopia nie wypiera dobrych.
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$jobs = [Collections.Generic.List[object]]::new()
foreach ($name in Split-List $Distro) {
    $info = Get-DistroInfo $name
    if (-not $info) { Fail "Nie znaleziono dystrybucji '$name'." }
    $dir   = Join-Path $BackupDir $name
    $final = Join-Path $dir "$name-$stamp.tar.gz"
    $jobs.Add([pscustomobject]@{ Distro = $name; Dir = $dir; Final = $final; Partial = "$final.partial"; Vhd = $info.VhdPath; Exit = $null })
}

# Rozmiar .vhdx to gorne ograniczenie rozmiaru spakowanej kopii - nie trzeba uruchamiac dystrybucji.
$needGB = [math]::Ceiling(($jobs | ForEach-Object { (Get-Item $_.Vhd).Length } | Measure-Object -Sum).Sum / 1GB) + 5
$freeGB = [math]::Floor($drive.AvailableFreeSpace / 1GB)
if ($freeGB -lt $needGB) { Fail "Za malo miejsca na $($drive.Name): wolne $freeGB GB, potrzeba ~$needGB GB." }

foreach ($job in $jobs) {
    New-Item -ItemType Directory -Force $job.Dir | Out-Null
    Get-ChildItem $job.Dir -Filter '*.partial' | Remove-Item -Force
}

# --- Eksport ---
$dockerWasRunning = $false
try {
    if (-not $Live) { $dockerWasRunning = Stop-DockerAndWsl }
    foreach ($job in $jobs) {
        Write-Host "`nEksport '$($job.Distro)' -> $($job.Final) (kilka-kilkanascie minut)"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        wsl --export $job.Distro $job.Partial --format tar.gz
        $job.Exit = $LASTEXITCODE
        Write-Host ('Czas: {0:N1} min' -f $sw.Elapsed.TotalMinutes)
    }
} finally {
    if ($dockerWasRunning) { Start-DockerDesktop }
}

# --- Zatwierdzenie i rotacja ---
$failed = @()
foreach ($job in $jobs) {
    Write-Host "`n[$($job.Distro)]"
    if ($job.Exit -ne 0 -or -not (Get-Item $job.Partial -ErrorAction SilentlyContinue).Length) {
        Remove-Item $job.Partial -Force -ErrorAction SilentlyContinue
        Write-Host "BLAD: wsl --export zakonczyl sie kodem $($job.Exit). Poprzednie kopie zostaly bez zmian." -ForegroundColor Red
        $failed += $job.Distro
        continue
    }
    $backup = Rename-Item $job.Partial (Split-Path $job.Final -Leaf) -PassThru
    Write-Host ('OK: {0:N1} GB' -f ($backup.Length / 1GB)) -ForegroundColor Green

    $all = @(Get-ChildItem $job.Dir -Filter '*.tar.gz' | Sort-Object Name -Descending)
    $all | Select-Object -Skip $Keep | ForEach-Object {
        Write-Host "Usuwam stara kopie: $($_.Name)"
        Remove-Item $_.FullName -Force
    }
    $all | Select-Object -First $Keep | ForEach-Object { '  {0}  {1,6:N1} GB' -f $_.Name, ($_.Length / 1GB) }
}

if ($failed) { Fail "Nie udalo sie wykonac kopii: $($failed -join ', ')." }
