#Requires -Version 7.4
# Installs the elevated \dotfiles\winget-upgrade scheduled task used by `mise run update`.
# Must run elevated: update.ps1 runs it through gsudo, which is the only UAC prompt.

$ErrorActionPreference = 'Stop'

$dir = Join-Path $env:ProgramData 'dotfiles'
New-Item -ItemType Directory -Force $dir | Out-Null
# The task runs the script from here elevated, so only Administrators and SYSTEM may write; Users may read the log.
icacls $dir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed with exit code $LASTEXITCODE." }
Copy-Item (Join-Path $PSScriptRoot 'winget-upgrade-runner.ps1') (Join-Path $dir 'winget-upgrade.ps1') -Force

$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$action = New-ScheduledTaskAction -Execute $powershell `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\winget-upgrade.ps1`""
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskPath '\dotfiles\' -TaskName 'winget-upgrade' `
    -Action $action -Principal $principal -Settings $settings -Force | Out-Null

Write-Host 'Registered scheduled task \dotfiles\winget-upgrade.'
