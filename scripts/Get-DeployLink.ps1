#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_./-]+$')][string]$Ref
)
$ErrorActionPreference = 'Stop'
$refPath = (($Ref -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
$template = "https://raw.githubusercontent.com/$Repository/$refPath/infra/azuredeploy.json"
$ui = "https://raw.githubusercontent.com/$Repository/$refPath/infra/createUiDefinition.json"
$url = 'https://portal.azure.com/#create/Microsoft.Template/uri/{0}/createUIDefinitionUri/{1}' -f `
    [Uri]::EscapeDataString($template), [Uri]::EscapeDataString($ui)
Write-Output $url
