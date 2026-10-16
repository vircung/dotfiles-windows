# Runs elevated from the \dotfiles\winget-upgrade scheduled task; winget-upgrade-setup.ps1 copies it
# into an admin-only directory. Windows PowerShell 5.1, ASCII only.
# Uses .NET only, no cmdlets: cmdlet autoloading searches the user's writable PSModulePath first.

$log = "$PSScriptRoot\winget-upgrade.log"
$exitFile = "$PSScriptRoot\winget-upgrade.exitcode"
[IO.File]::Delete($exitFile)

$psi = [Diagnostics.ProcessStartInfo]::new("$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe",
    'upgrade --all --silent --disable-interactivity --accept-package-agreements --accept-source-agreements')
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true

$out = [IO.File]::Open($log, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
try {
    $p = [Diagnostics.Process]::Start($psi)
    $stderr = $p.StandardError.ReadToEndAsync()
    # Flush every chunk so `mise run update` can show the log live.
    $buffer = [byte[]]::new(4096)
    $stream = $p.StandardOutput.BaseStream
    while (($n = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $out.Write($buffer, 0, $n)
        $out.Flush()
    }
    $p.WaitForExit()
    $bytes = [Text.Encoding]::UTF8.GetBytes($stderr.Result)
    $out.Write($bytes, 0, $bytes.Length)
    $code = $p.ExitCode
} catch {
    $bytes = [Text.Encoding]::UTF8.GetBytes("ERROR: $_")
    $out.Write($bytes, 0, $bytes.Length)
    $code = 1
} finally {
    $out.Dispose()
}
[IO.File]::WriteAllText($exitFile, "$code")
