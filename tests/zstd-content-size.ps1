#Requires -Version 7.4
# Self-check for Get-ZstdContentSize, which the wsl:restore free-space check relies on.
# Run: pwsh -NoProfile -File tests\zstd-content-size.ps1
# The sizes cover the 1-, 2- and 4-byte size fields, with and without a window descriptor (3 MB).

. "$PSScriptRoot\..\mise\lib\wsl-common.ps1"

$zstd = Get-Zstd
$dir  = New-Item -ItemType Directory -Force (Join-Path ([IO.Path]::GetTempPath()) "zstd-content-size-$PID")
try {
    foreach ($size in 100, 1000, 100KB, 3MB) {
        $raw = Join-Path $dir "$size.bin"
        [IO.File]::WriteAllBytes($raw, [byte[]]::new($size))
        & $zstd -1 -q -f $raw -o "$raw.zst"
        $got = Get-ZstdContentSize "$raw.zst"
        if ($got -ne $size) { Fail "Get-ZstdContentSize read $size bytes as '$got'." }
    }
    Write-Host 'OK' -ForegroundColor Green
} finally {
    Remove-Item $dir -Recurse -Force
}
