#requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.()-]+$')][string]$ResourceGroupName,
    [string]$Location = 'eastus2',
    [Parameter(Mandatory)][string]$ParametersFile,
    [switch]$Apply,
    [switch]$LicensingAndCostReviewed
)
$ErrorActionPreference = 'Stop'
function Invoke-AzChecked {
    param([string[]]$Arguments)
    & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..1] -join ' ')" }
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Install Azure CLI and sign in first.' }
if (-not (Test-Path -LiteralPath $ParametersFile)) { throw 'Parameter file not found.' }
$template = Join-Path $PSScriptRoot '..\infra\azuredeploy.json'
if (-not (Test-Path -LiteralPath $template)) { throw 'Build ARM first with scripts\Build-Templates.ps1.' }
$account = (& az account show --subscription $SubscriptionId --output json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or $account.id -ne $SubscriptionId) { throw 'Unable to confirm selected subscription.' }
if ($Apply -and -not $LicensingAndCostReviewed) { throw 'Review licenses, policies and costs; pass -LicensingAndCostReviewed.' }
if ($Apply -and $PSCmdlet.ShouldProcess("$SubscriptionId/$ResourceGroupName", 'Create lab resource group and deploy paid resources')) {
    $exists = & az group exists --subscription $SubscriptionId --name $ResourceGroupName --output tsv
    if ($LASTEXITCODE -ne 0) { throw 'Cannot determine whether the resource group exists.' }
    if ($exists.Trim() -eq 'true') {
        $existing = & az group show --subscription $SubscriptionId --name $ResourceGroupName --output json
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect existing resource group.' }
        if (($existing | ConvertFrom-Json).tags.otDemo -ne 'true') {
            throw 'Existing resource group is not tagged otDemo=true. Use a dedicated, reviewed lab resource group.'
        }
    } else {
        Invoke-AzChecked @('group', 'create', '--subscription', $SubscriptionId, '--name', $ResourceGroupName, '--location', $Location, '--tags', 'otDemo=true', '--output', 'none')
    }
    Invoke-AzChecked @('deployment', 'group', 'create', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroupName,
        '--name', 'ot-lab', '--template-file', $template, '--parameters', "@$ParametersFile")
} elseif (-not $Apply) {
    Write-Output 'What-if only. The resource group must already exist. No resources are created by this command.'
    Invoke-AzChecked @('deployment', 'group', 'what-if', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroupName,
        '--template-file', $template, '--parameters', "@$ParametersFile")
}
