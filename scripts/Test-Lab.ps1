#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Workstation', 'SensitiveServer', 'Collector')][string]$Role,
    [Parameter(Mandatory)][ValidatePattern('^http://[A-Za-z0-9.-]+:3128$')][string]$ProxyUrl,
    [string]$CollectorFqdn,
    [string]$EvidencePath
)
$ErrorActionPreference = 'Stop'
$checks = [Collections.Generic.List[object]]::new()
function Add-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $checks.Add([pscustomobject]@{ Name=$Name; Passed=$Passed; Detail=$Detail })
}
$guest = Get-Service WindowsAzureGuestAgent -ErrorAction SilentlyContinue
if ($Role -eq 'Workstation') {
    Add-Check 'AzureGuestAgent' ($null -ne $guest -and $guest.Status -eq 'Running') 'Win11 guest agent must remain running.'
    Add-Check 'NoArcAgent' (-not (Get-Service himds -ErrorAction SilentlyContinue)) 'Win11 must not be Arc-converted.'
} else {
    Add-Check 'AzureGuestAgent' ($null -ne $guest -and $guest.Status -eq 'Stopped' -and $guest.StartType -eq 'Disabled') 'Guest agent must be disabled and stopped.'
    $arc = Get-Service himds -ErrorAction SilentlyContinue
    Add-Check 'ArcService' ($null -ne $arc -and $arc.Status -eq 'Running') 'Also verify azcmagent show reports Connected.'
    foreach ($ip in @('169.254.169.253', '169.254.169.254')) {
        $blocked = @(Get-NetFirewallRule -Direction Outbound -Enabled True -Action Block |
            Get-NetFirewallAddressFilter | Where-Object { $ip -in $_.RemoteAddress }).Count -gt 0
        Add-Check "IMDS-$ip" $blocked 'Outbound host block must persist after reboot.'
    }
}
if ($Role -ne 'Collector') {
    $mp = Get-MpComputerStatus
    Add-Check 'ActiveAntivirus' ($mp.AMRunningMode -eq 'Normal' -and $mp.RealTimeProtectionEnabled) 'Active AV still has residual blocking/quarantine risk.'
}
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe is required for independent direct/proxy probes.' }
& curl.exe --silent --show-error --output NUL --connect-timeout 5 --max-time 15 --proxy $ProxyUrl --noproxy 'nonexistent.invalid' https://login.microsoftonline.com/
Add-Check 'ApprovedProxyDestination' ($LASTEXITCODE -eq 0) 'Transport only; does not prove all MDE/Arc/AMA endpoints.'
& curl.exe --silent --output NUL --connect-timeout 3 --max-time 8 --proxy $ProxyUrl --noproxy 'nonexistent.invalid' https://example.com/
$deniedProxy = $LASTEXITCODE -ne 0
Add-Check 'ProxyDeniesOtherDestination' $deniedProxy 'Correlate with Squid deny log; failure alone is not enforcement proof.'
& curl.exe --silent --output NUL --connect-timeout 3 --max-time 8 --noproxy '*' https://example.com/
Add-Check 'NoDirectInternet' ($LASTEXITCODE -ne 0) 'Correlate with effective NSG/routes and firewall denies.'
if ($Role -eq 'Workstation') {
    if (-not $CollectorFqdn) { throw 'Workstation validation requires -CollectorFqdn.' }
    Add-Check 'WEFTransport' (Test-NetConnection $CollectorFqdn -Port 5986 -InformationLevel Quiet) 'Confirm subscription runtime and WindowsEvent ingestion separately.'
}
$checks | Format-Table -AutoSize | Out-Host
if ($EvidencePath) {
    $checks | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
}
if (@($checks | Where-Object { -not $_.Passed }).Count) { throw 'One or more local checks failed. See docs\operations.md for full cloud acceptance.' }
Write-Output 'Local checks passed. Tenant policy and Sentinel ingestion still require the documented manual checks.'
