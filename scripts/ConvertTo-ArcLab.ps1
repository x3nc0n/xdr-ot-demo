#Requires -RunAsAdministrator
<#
.SYNOPSIS
Prepares a Windows Server 2022 Azure VM for evaluation-only Arc installation.
.DESCRIPTION
Run locally over previously tested private administration, never Azure Run Command.
The switches attest that the operator removed ALL Compute VM extensions and prevented
policy reprovisioning. They do not refer to Arc extensions. No cloud API is called.
Supply a staged Microsoft MSI and independently obtained SHA256 and signer thumbprint.
After this script, connect manually using interactive device-code authentication:
  & "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" connect --tenant-id <tenant> --subscription-id <subscription> --resource-group <group> --location <region> --use-device-code
Do not pass service-principal credentials. Preserve an existing Arc identity.
Reference: https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateSet('windows2022', 'wec')][string]$Role,
    [Parameter(Mandatory)][uri]$ProxyUrl,
    [Parameter(Mandatory)][string]$InstallerPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$InstallerSha256,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$TrustedSignerThumbprint,
    [switch]$ExtensionsRemovedVerified,
    [switch]$PolicyRedeploymentPrevented,
    [switch]$PrivateManagementVerified
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$agent = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
if (Test-Path -LiteralPath $agent) {
    $raw = & $agent show --json
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect existing Arc identity; refusing conversion.' }
    $state = $raw | ConvertFrom-Json
    if ($state.PSObject.Properties['resourceId'] -and $state.resourceId) {
        Write-Output 'An Arc resource identity already exists. No conversion or reconnection performed.'
        return
    }
}
if (-not ($ExtensionsRemovedVerified -and $PolicyRedeploymentPrevented -and $PrivateManagementVerified)) {
    throw 'Required: verified Compute extension removal, policy redeployment prevention, and private management/recovery.'
}
$os = Get-CimInstance Win32_OperatingSystem
if ($os.ProductType -eq 1 -or $os.BuildNumber -ne '20348') { throw 'Only Windows Server 2022 is supported; never run on Windows 11.' }
if ($ProxyUrl.Scheme -ne 'http' -or $ProxyUrl.UserInfo -or $ProxyUrl.AbsolutePath -ne '/' -or $ProxyUrl.Query -or $ProxyUrl.Fragment) {
    throw 'Use an anonymous explicit http://host:port proxy without a path.'
}
$installer = Get-Item -LiteralPath $InstallerPath
if ($installer.Extension -ne '.msi' -or $installer.PSIsContainer) { throw 'A locally staged Arc MSI is required.' }
if ((Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256).Hash -ne $InstallerSha256) { throw 'Installer SHA256 mismatch.' }
$signature = Get-AuthenticodeSignature -LiteralPath $installer.FullName
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $TrustedSignerThumbprint -or
    $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'Installer Microsoft signature verification failed.' }
if (-not (Get-Service WindowsAzureGuestAgent -ErrorAction SilentlyContinue)) { throw 'Azure guest agent not found; inspect this host manually.' }
if (Get-NetFirewallProfile | Where-Object { -not $_.Enabled }) { throw 'All Windows Firewall profiles must be enabled before conversion.' }
if (-not $PSCmdlet.ShouldProcess("$env:COMPUTERNAME ($Role)", 'Disable Azure guest agents, persist IMDS blocks, install Arc and set proxy (no connect)')) { return }
[Environment]::SetEnvironmentVariable('MSFT_ARC_TEST', 'true', 'Machine')
$env:MSFT_ARC_TEST = 'true'
foreach ($name in 'WindowsAzureGuestAgent', 'RdAgent') {
    if (Get-Service $name -ErrorAction SilentlyContinue) {
        Stop-Service $name -Force
        Set-Service $name -StartupType Disabled
    }
}
foreach ($suffix in '253', '254') {
    $name = "OT-Lab-Block-IMDS-$suffix"
    if (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue) {
        Set-NetFirewallRule -Name $name -Enabled True -Profile Any -Direction Outbound -Action Block
        Get-NetFirewallRule -Name $name | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress "169.254.169.$suffix" | Out-Null
    } else {
        New-NetFirewallRule -Name $name -DisplayName $name -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress "169.254.169.$suffix" | Out-Null
    }
}
if (-not (Test-Path -LiteralPath $agent)) {
    $process = Start-Process msiexec.exe -ArgumentList "/i `"$($installer.FullName)`" /qn /norestart" -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) { throw "Arc MSI failed with exit $($process.ExitCode). Private management is required for recovery." }
}
$servicePath = 'HKLM:\SYSTEM\CurrentControlSet\Services\himds'
if (-not (Test-Path $servicePath)) { throw 'Installed Arc HIMDS service is missing; do not connect.' }
$serviceProperties = Get-ItemProperty $servicePath
$environment = @()
if ($serviceProperties.PSObject.Properties['Environment']) {
    $environment = @($serviceProperties.Environment | Where-Object { $_ -notmatch '^MSFT_ARC_TEST=' })
}
New-ItemProperty $servicePath -Name Environment -PropertyType MultiString -Value @($environment + 'MSFT_ARC_TEST=true') -Force | Out-Null
Restart-Service himds -Force
& $agent config set proxy.url $ProxyUrl.AbsoluteUri.TrimEnd('/')
if ($LASTEXITCODE -ne 0) { throw 'Arc proxy configuration failed; do not connect.' }
Write-Output 'Prepared only. Reboot and verify disabled guest agents and both IMDS blocks. Then run the manual device-code connect command in this script help with your tenant/subscription/group/region. Configure AMA proxy separately.'
