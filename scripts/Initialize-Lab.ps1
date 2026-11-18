#Requires -RunAsAdministrator
<#
.SYNOPSIS
Local staged guest configuration; never dispatches Azure Run Command or cloud calls.
.DESCRIPTION
Execute on each guest through private RDP/PowerShell after manually staging the repo.
Protection configures an installed Defender agent BEFORE manual tenant onboarding.
Arc prepares/installs only: registration is a separate manual device-code step.
WEF certificate issuance and Collector/Source setup are explicit separate operations.
No passwords, onboarding packages or certificate private keys are copied by this script.
For Ubuntu, manually stage and run the .sh counterparts over private SSH; this Windows
orchestrator does not copy files remotely or pretend Run Command survives conversion.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateSet('windows11', 'windows2022', 'wec')][string]$Role,
    [Parameter(Mandatory)][ValidateSet('Protection', 'Workload', 'Arc')][string]$Stage,
    [uri]$ProxyUrl,
    [string]$DeviceTag,
    [ValidatePattern('^(?=.{1,253}$)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$')][string]$CertificateDistributionFqdn,
    [string]$InstallerPath,
    [string]$InstallerSha256,
    [string]$TrustedSignerThumbprint,
    [switch]$ResponseGuardrailsVerified,
    [switch]$ExtensionsRemovedVerified,
    [switch]$PolicyRedeploymentPrevented,
    [switch]$PrivateManagementVerified
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Stage -eq 'Arc' -and $Role -eq 'windows11') { throw 'Windows 11 retains its Azure guest agent and must never be converted to Arc.' }
if ($Stage -eq 'Workload' -and $Role -eq 'wec') { throw 'The collector is not a synthetic application target.' }
if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Run local guest stage $Stage for $Role")) { return }
switch ($Stage) {
    'Protection' {
        if (-not $ProxyUrl -or -not $DeviceTag) { throw 'Protection requires ProxyUrl and DeviceTag.' }
        if ($Role -eq 'wec') { throw 'WEC MDE onboarding is outside the initial target scope; review entitlement and response guardrails separately.' }
        $protection = @{
            ProxyUrl = $ProxyUrl
            DeviceTag = $DeviceTag
            ResponseGuardrailsVerified = $ResponseGuardrailsVerified
            Confirm = $false
        }
        if ($CertificateDistributionFqdn) { $protection.CertificateDistributionFqdn = $CertificateDistributionFqdn }
        & (Join-Path $PSScriptRoot 'Set-LabProtection.ps1') @protection
    }
    'Workload' {
        & (Join-Path $PSScriptRoot '..\workloads\windows\Install-Heartbeat.ps1') -Confirm:$false
    }
    'Arc' {
        if (-not $ProxyUrl -or -not $InstallerPath -or -not $InstallerSha256 -or -not $TrustedSignerThumbprint) { throw 'Arc requires ProxyUrl, InstallerPath, InstallerSha256 and TrustedSignerThumbprint.' }
        & (Join-Path $PSScriptRoot 'ConvertTo-ArcLab.ps1') -Role $Role -ProxyUrl $ProxyUrl -InstallerPath $InstallerPath -InstallerSha256 $InstallerSha256 -TrustedSignerThumbprint $TrustedSignerThumbprint -ExtensionsRemovedVerified:$ExtensionsRemovedVerified -PolicyRedeploymentPrevented:$PolicyRedeploymentPrevented -PrivateManagementVerified:$PrivateManagementVerified -Confirm:$false
    }
}
