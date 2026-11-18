#Requires -RunAsAdministrator
<#
.SYNOPSIS
Configures Windows AV and EDR proxies before MANUAL MDE onboarding.
.DESCRIPTION
ResponseGuardrailsVerified attests external tenant/canary validation, including initial
enrollment scope, no automatic response, and existing Sentinel/Defender integrations.
This script cannot verify those tenant settings. It never executes onboarding content.
CertificateDistributionFqdn optionally permits one approved internal CRL host to
bypass the WinHTTP proxy; allow that host/port in the lab firewall separately.
Manually obtain the tenant's Windows onboarding CMD from Defender, validate its trusted
SHA256 out-of-band, inspect it, and execute locally using the portal's instructions.
Do not transcript onboarding, store its contents in this repo, or pass its secrets as arguments.
Reference: https://learn.microsoft.com/defender-endpoint/configure-proxy-internet
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][uri]$ProxyUrl,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$DeviceTag,
    [ValidatePattern('^(?=.{1,253}$)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$')][string]$CertificateDistributionFqdn,
    [switch]$ResponseGuardrailsVerified
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $ResponseGuardrailsVerified) { throw 'Stop: scoped response policies and initial-enrollment canary must be verified before configuration/onboarding.' }
if ($ProxyUrl.Scheme -ne 'http' -or $ProxyUrl.UserInfo -or $ProxyUrl.AbsolutePath -ne '/' -or $ProxyUrl.Query -or $ProxyUrl.Fragment) {
    throw 'Use an anonymous explicit http://host:port proxy.'
}
Get-Command Set-MpPreference, Add-MpPreference, Get-MpComputerStatus, Get-MpPreference -ErrorAction Stop | Out-Null
$status = Get-MpComputerStatus
if ($status.AMRunningMode -ne 'Normal' -or -not $status.AMServiceEnabled) {
    throw 'Defender Antivirus must be installed and active (Normal mode). Resolve competing/passive AV manually; do not force policy.'
}
if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Configure EDR, AV and WinHTTP proxies, lab tag, real-time AV and one data-file exclusion')) { return }
$proxy = $ProxyUrl.Authority
$edr = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
New-Item $edr -Force | Out-Null
New-ItemProperty $edr -Name DisableEnterpriseAuthProxy -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty $edr -Name TelemetryProxyServer -Value $proxy -PropertyType String -Force | Out-Null
$proxyArguments = @('winhttp', 'set', 'proxy', "proxy-server=$proxy")
# An explicitly approved internal CRL host is the only supported direct bypass.
if ($CertificateDistributionFqdn) { $proxyArguments += "bypass-list=$CertificateDistributionFqdn" }
& netsh.exe @proxyArguments
if ($LASTEXITCODE -ne 0) { throw 'WinHTTP proxy configuration failed.' }
Set-MpPreference -ProxyServer $proxy -DisableRealtimeMonitoring $false
$file = 'C:\ProgramData\OT-Lab\data\sample-state.json'
if ($file -notin (Get-MpPreference).ExclusionPath) { Add-MpPreference -ExclusionPath $file }
$tagPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging'
New-Item $tagPath -Force | Out-Null
New-ItemProperty $tagPath -Name Group -Value $DeviceTag -PropertyType String -Force | Out-Null
$result = Get-MpComputerStatus
if (-not $result.RealTimeProtectionEnabled -or $result.AMRunningMode -ne 'Normal') { throw 'Real-time active AV not verified. Do not onboard.' }
Write-Output 'Local settings applied; no onboarding performed. Check policy readback, EDR/AV connectivity, scoped enrollment and update/CRL paths before manually running the verified tenant onboarding CMD. Existing broad exclusions were not removed; review them.'
