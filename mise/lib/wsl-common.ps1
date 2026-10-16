# Wspolne funkcje taskow mise wsl:* - dolaczane przez dot-source z tasks\wsl\*.ps1.
# Lezy poza katalogiem tasks, zeby mise nie traktowal go jako taska.

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'   # czytelny output z wsl.exe

$DockerProcesses = 'Docker Desktop', 'com.docker.backend'

function Fail($msg) { Write-Host "BLAD: $msg" -ForegroundColor Red; exit 1 }

# Konfiguracja pochodzi z [env] w ~/.config/mise/config.local.toml; argumenty taska ja nadpisuja.
function Assert-Config([hashtable]$Settings) {
    $missing = @($Settings.Keys | Where-Object { -not $Settings[$_] })
    if ($missing) { Fail "Brak ustawien: $($missing -join ', '). Ustaw je w sekcji [env] pliku ~/.config/mise/config.local.toml albo podaj jako argumenty." }
}

# "Ubuntu, Ubuntu-OpenRig" -> 'Ubuntu', 'Ubuntu-OpenRig'. Wynik owijaj w @(), bo PowerShell rozpakowuje jednoelementowe tablice.
function Split-List($value) { $value -split ',' | ForEach-Object Trim | Where-Object { $_ } }

# BasePath i sciezka .vhdx dystrybucji z rejestru (wsl.exe ich nie podaje); $null, jesli nie istnieje.
function Get-DistroInfo($Distro) {
    $p = Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss |
        ForEach-Object { Get-ItemProperty $_.PSPath } |
        Where-Object DistributionName -eq $Distro
    if (-not $p) { return }
    $base = $p.BasePath -replace '^\\\\\?\\', ''
    [pscustomobject]@{ BasePath = $base; VhdPath = Join-Path $base $p.VhdFileName }
}

# Zatrzymuje Docker Desktop (jesli dziala) i caly WSL. Zwraca $true, jesli Docker dzialal.
# Wywolujacy uruchamia Dockera z powrotem w bloku finally przez Start-DockerDesktop.
function Stop-DockerAndWsl {
    $wasRunning = [bool](Get-Process $DockerProcesses -ErrorAction SilentlyContinue)
    if ($wasRunning) {
        Write-Host 'Zatrzymywanie Docker Desktop...'
        docker desktop stop --timeout 120 | Out-Host
        if ($LASTEXITCODE -ne 0) { Get-Process $DockerProcesses -ErrorAction SilentlyContinue | Stop-Process -Force }
    }
    Write-Host 'Zatrzymywanie WSL...'
    wsl --shutdown | Out-Host
    $wasRunning
}

function Start-DockerDesktop {
    Write-Host 'Uruchamianie Docker Desktop...'
    docker desktop start --detach | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Host 'Nie udalo sie uruchomic Docker Desktop - uruchom go recznie.' -ForegroundColor Yellow }
}
