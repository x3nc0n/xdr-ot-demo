#requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.()-]+$')][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$ConfirmResourceGroupName,
    [switch]$OffboardingAndTenantCleanupComplete
)
$ErrorActionPreference = 'Stop'
if ($ConfirmResourceGroupName -cne $ResourceGroupName) { throw 'Confirmation must exactly match the resource group name.' }
if (-not $OffboardingAndTenantCleanupComplete) { throw 'Complete Arc/MDE offboarding and scoped tenant cleanup first.' }
$group = & az group show --subscription $SubscriptionId --name $ResourceGroupName --output json
if ($LASTEXITCODE -ne 0) { throw 'Cannot read resource group.' }
$group = $group | ConvertFrom-Json
if ($group.tags.otDemo -ne 'true') { throw 'Refusing deletion: resource group does not have otDemo=true.' }
if ($PSCmdlet.ShouldProcess("$SubscriptionId/$ResourceGroupName", 'Delete ALL resources in this lab resource group')) {
    & az group delete --subscription $SubscriptionId --name $ResourceGroupName --yes
    if ($LASTEXITCODE -ne 0) { throw 'Resource group deletion failed.' }
}
