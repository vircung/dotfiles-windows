# Links files and directories from this repo into their places on the system (Windows).
# Must work in Windows PowerShell 5.1 (on a new machine pwsh is only installed by `mise install`).
# Run: powershell -ExecutionPolicy Bypass -File install.ps1
#
# Directories -> junction (no admin or Developer Mode needed).
# Files       -> symlink  (requires Developer Mode or admin).
# An existing target that is not already a link to this repo is moved to <target>.backup-<date>.

$ErrorActionPreference = 'Stop'

# --- mise ---
if (Get-Command mise -ErrorAction SilentlyContinue) {
    Write-Host "OK:      mise $((mise --version) -split ' ' | Select-Object -First 1)"
} else {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'Neither mise nor winget found. Install App Installer from the Microsoft Store, or mise manually: https://mise.jdx.dev' }
    Write-Host 'Installing mise (winget)...'
    winget install --id jdx.mise --exact --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget install jdx.mise failed with exit code $LASTEXITCODE." }
    # winget adds mise to PATH in the registry; refresh PATH for this session
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (Get-Command mise -ErrorAction SilentlyContinue)) { throw 'mise installed, but not on PATH - open a new terminal and run the script again.' }
    Write-Host "OK:      mise $((mise --version) -split ' ' | Select-Object -First 1)" -ForegroundColor Green
}

# --- Local files (*.local.*, git-ignored) created from *.example templates ---
Get-ChildItem $PSScriptRoot -Recurse -File -Filter '*.local.*.example' | ForEach-Object {
    $local = $_.FullName -replace '\.example$', ''
    if (Test-Path $local) { return }
    Copy-Item $_.FullName $local
    Write-Host "NEW:     $local (from template - adjust it to this machine)" -ForegroundColor Yellow
}

# --- Links: repo source => system target ---
$links = [ordered]@{
    'mise' = "$env:USERPROFILE\.config\mise"
}

foreach ($entry in $links.GetEnumerator()) {
    $source = Join-Path $PSScriptRoot $entry.Key
    $target = $entry.Value
    if (-not (Test-Path $source)) { Write-Host "SKIP:    $source missing" -ForegroundColor Yellow; continue }

    $existing = Get-Item $target -Force -ErrorAction SilentlyContinue
    if ($existing -and $existing.LinkType) {
        if (@($existing.Target)[0] -eq $source) { Write-Host "OK:      $target"; continue }
        Write-Host "Replacing link $target (pointed to $(@($existing.Target)[0]))"
        $existing.Delete()
    } elseif ($existing) {
        $backup = "$target.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-Host "BACKUP:  $target -> $backup"
        Move-Item $target $backup
    }

    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
    $type = if ((Get-Item $source).PSIsContainer) { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $type -Path $target -Target $source | Out-Null
    Write-Host "LINK:    $target -> $source ($type)" -ForegroundColor Green
}

# --- Tools from mise/config.toml (incl. pwsh, required by the tasks) ---
Write-Host 'mise install...'
mise install
if ($LASTEXITCODE -ne 0) { throw "mise install failed with exit code $LASTEXITCODE." }
