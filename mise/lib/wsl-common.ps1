# Shared functions for the wsl:* mise tasks - dot-sourced from tasks\wsl\*.ps1.
# Lives outside the tasks directory so mise doesn't treat it as a task.

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'   # readable output from wsl.exe

$DockerProcesses = 'Docker Desktop', 'com.docker.backend'

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# Settings come from [env] in ~/.config/mise/config.local.toml; task arguments override them.
function Assert-Config([hashtable]$Settings) {
    $missing = @($Settings.Keys | Where-Object { -not $Settings[$_] })
    if ($missing) { Fail "Missing settings: $($missing -join ', '). Set them in the [env] section of ~/.config/mise/config.local.toml or pass them as arguments." }
}

# "Ubuntu, Ubuntu-OpenRig" -> 'Ubuntu', 'Ubuntu-OpenRig'. Wrap the result in @(), since PowerShell unwraps single-element arrays.
function Split-List($value) { $value -split ',' | ForEach-Object Trim | Where-Object { $_ } }

# Distro BasePath, .vhdx path and whether it's the default, from the registry (wsl.exe doesn't expose them);
# $null if it doesn't exist.
function Get-DistroInfo($Distro) {
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $p = Get-ChildItem $lxss |
        ForEach-Object { Get-ItemProperty $_.PSPath } |
        Where-Object DistributionName -eq $Distro
    if (-not $p) { return }
    $base = $p.BasePath -replace '^\\\\\?\\', ''
    [pscustomobject]@{
        BasePath  = $base
        VhdPath   = Join-Path $base $p.VhdFileName
        IsDefault = (Get-ItemProperty $lxss).DefaultDistribution -eq $p.PSChildName
    }
}

# Stops Docker Desktop (if running) and all of WSL. Returns $true if Docker was running.
# The caller restarts Docker in a finally block via Start-DockerDesktop.
function Stop-DockerAndWsl {
    $wasRunning = [bool](Get-Process $DockerProcesses -ErrorAction SilentlyContinue)
    if ($wasRunning) {
        Write-Host 'Stopping Docker Desktop...'
        docker desktop stop --timeout 120 | Out-Host
        if ($LASTEXITCODE -ne 0) { Get-Process $DockerProcesses -ErrorAction SilentlyContinue | Stop-Process -Force }
    }
    Write-Host 'Stopping WSL...'
    wsl --shutdown | Out-Host
    $wasRunning
}

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1GB) { '{0:N1} GB' -f ($Bytes / 1GB) } elseif ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) } else { '{0:N1} KB' -f ($Bytes / 1KB) }
}

# zstd from winget (Meta.Zstandard); fails if it's missing.
function Get-Zstd {
    $cmd = Get-Command zstd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { Fail 'zstd not found. Install it: winget install Meta.Zstandard (or mise run winget:install).' }
    $cmd.Source
}

# Backups in a distro directory, newest first. Formats:
#   .vhdx.zst - the distro's ext4.vhdx compressed (default)
#   .tar.zst  - wsl --export piped through zstd (-Live)
#   .tar.gz   - wsl --export --format tar.gz (older backups)
function Get-Backups($Dir) {
    @(Get-ChildItem $Dir -File | Where-Object Name -match '\.(vhdx\.zst|tar\.zst|tar\.gz)$' | Sort-Object Name -Descending)
}

# Decompressed size from the first zstd frame header, $null if not recorded.
# (zstd -l can't be used: it fails on large files on Windows.)
function Get-ZstdContentSize($Path) {
    $f = [IO.File]::OpenRead($Path)
    try { $h = [byte[]]::new(18); $null = $f.Read($h, 0, 18) } finally { $f.Dispose() }
    if ([BitConverter]::ToUInt32($h, 0) -ne 0xFD2FB528u) { return }
    $fhd    = $h[4]
    $single = ($fhd -shr 5) -band 1
    $pos    = 5 + (1 - $single) + (0, 1, 2, 4)[$fhd -band 3]   # window descriptor, dictionary ID
    switch ($fhd -shr 6) {
        0 { if ($single) { $h[$pos] } }
        1 { [BitConverter]::ToUInt16($h, $pos) + 256 }
        2 { [BitConverter]::ToUInt32($h, $pos) }
        3 { [BitConverter]::ToUInt64($h, $pos) }
    }
}

# Bytes a (sparse) file actually occupies on disk.
function Get-AllocatedSize($Path) {
    if (-not ('Wsl.Native' -as [type])) {
        Add-Type -Namespace Wsl -Name Native -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern uint GetCompressedFileSizeW(string path, out uint high);'
    }
    $high = 0
    $low  = [Wsl.Native]::GetCompressedFileSizeW($Path, [ref]$high)
    ([uint64]$high -shl 32) -bor $low
}

# Streams the stdout of $From into the stdin of $To (each: exe, args...) and returns both exit codes.
# A PowerShell pipe would only report the last exit code, hiding a failed wsl --export.
function Invoke-BytePipe([string[]]$From, [string[]]$To) {
    $src = [Diagnostics.ProcessStartInfo]::new($From[0])
    $From | Select-Object -Skip 1 | ForEach-Object { $src.ArgumentList.Add($_) }
    $src.RedirectStandardOutput = $true
    $dst = [Diagnostics.ProcessStartInfo]::new($To[0])
    $To | Select-Object -Skip 1 | ForEach-Object { $dst.ArgumentList.Add($_) }
    $dst.RedirectStandardInput = $true
    $s = [Diagnostics.Process]::Start($src)
    $d = [Diagnostics.Process]::Start($dst)
    try { $s.StandardOutput.BaseStream.CopyTo($d.StandardInput.BaseStream, 1MB) } catch { $s.Kill() }
    $d.StandardInput.Close()
    $s.WaitForExit(); $d.WaitForExit()
    $s.ExitCode, $d.ExitCode
}

function Start-DockerDesktop {
    Write-Host 'Starting Docker Desktop...'
    docker desktop start --detach | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Host 'Failed to start Docker Desktop - start it manually.' -ForegroundColor Yellow }
}
