#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$payload = Join-Path $PSScriptRoot 'Write-Heartbeat.ps1'
if (-not (Test-Path -LiteralPath $payload)) { throw 'Missing staged heartbeat payload.' }
if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Install benign OT-Lab Application heartbeat task')) { return }
$root = 'C:\ProgramData\OT-Lab'
New-Item "$root\bin", "$root\data" -ItemType Directory -Force | Out-Null
# The SYSTEM task must never execute code writable by ordinary lab users.
& icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /Q
if ($LASTEXITCODE -ne 0) { throw 'Cannot secure workload directory.' }
Copy-Item -LiteralPath $payload -Destination "$root\bin\Write-Heartbeat.ps1" -Force
if ([Diagnostics.EventLog]::SourceExists('OT-Lab')) {
    if ([Diagnostics.EventLog]::LogNameFromSourceName('OT-Lab', '.') -ne 'Application') { throw 'Existing OT-Lab source belongs to a different log.' }
} else { New-EventLog -LogName Application -Source 'OT-Lab' }
$executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $executable -Argument '-NoProfile -NonInteractive -File "C:\ProgramData\OT-Lab\bin\Write-Heartbeat.ps1"'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -StartWhenAvailable
Register-ScheduledTask -TaskName 'OT-Lab-Heartbeat' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
& "$root\bin\Write-Heartbeat.ps1"
