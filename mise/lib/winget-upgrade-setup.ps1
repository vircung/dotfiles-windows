#Requires -Version 7.4
# Installs the elevated \dotfiles\winget-upgrade scheduled task used by `mise run update`.
# Must run elevated: update.ps1 runs it through gsudo, which is the only UAC prompt.

$ErrorActionPreference = 'Stop'

$dir = Join-Path $env:ProgramData 'dotfiles'
# A user could plant a junction here, sending the ACL changes and deletes below to another folder.
if ((Get-Item $dir -Force -ErrorAction SilentlyContinue).LinkType) { Remove-Item $dir -Force }
New-Item -ItemType Directory -Force $dir | Out-Null
# The task runs the script from here elevated, so only Administrators and SYSTEM may write; Users may read the log.
# Users can create directories in ProgramData: if one did, take ownership and drop its explicit entries first.
foreach ($a in @('/setowner', '*S-1-5-32-544'), @('/reset'),
               @('/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX')) {
    icacls $dir @a | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls $($a[0]) failed with exit code $LASTEXITCODE." }
}
# Locked now, so a user can no longer swap it for a link; check once more before deleting through it.
if ((Get-Item $dir -Force).LinkType) { throw "$dir is a link." }
# Files from before the lock may be owned by a user; none of them needs to be kept.
Get-ChildItem $dir -Force | Remove-Item -Recurse -Force
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
