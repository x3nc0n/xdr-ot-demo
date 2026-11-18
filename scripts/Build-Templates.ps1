#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('runtime', 'maintenance', 'bootstrap')]
    [string[]]$Phase = @('runtime', 'maintenance', 'bootstrap')
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Build-EgressPolicy.ps1') -Phase $Phase
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI with Bicep is required.' }
$infra = Join-Path $PSScriptRoot '..\infra'
foreach ($name in @('main', 'arc-monitoring')) {
    $output = if ($name -eq 'main') { 'azuredeploy.json' } else { 'arc-monitoring.json' }
    & az bicep build --file (Join-Path $infra "$name.bicep") --outfile (Join-Path $infra $output)
    if ($LASTEXITCODE -ne 0) { throw "Bicep compilation failed: $name" }
}
