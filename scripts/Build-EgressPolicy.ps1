#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..\config\endpoints.json'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\config\egress.json'),
    [ValidateSet('runtime', 'maintenance', 'bootstrap')]
    [string[]]$Phase = @('runtime', 'maintenance', 'bootstrap')
)
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or $manifest.cloud -ne 'AzurePublic') {
    throw 'Only schemaVersion 1 / AzurePublic manifests are supported.'
}
$https = [Collections.Generic.List[string]]::new()
$http = [Collections.Generic.List[string]]::new()
foreach ($entry in $manifest.endpoints) {
    if ($entry.phase -notin @('runtime', 'maintenance', 'bootstrap') -or
        -not $entry.service -or -not $entry.purpose -or
        $entry.source -notmatch '^https://') {
        throw 'Every endpoint entry requires a known phase, service, purpose and HTTPS source.'
    }
    if (-not $entry.ports -or -not $entry.fqdns) { throw 'Empty endpoint entry.' }
    foreach ($port in $entry.ports) {
        if ($port -notin @(80, 443)) { throw "Unsupported port: $port" }
    }
    foreach ($fqdn in $entry.fqdns) {
        if ($fqdn -cnotmatch '^(\*\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' -or
            $fqdn -in @('*.com', '*.net', '*.org', '*.microsoft.com', '*.azure.com', '*.blob.core.windows.net')) {
            throw "Unsafe or unsupported FQDN: $fqdn"
        }
        if ($entry.phase -in $Phase) {
            if (443 -in $entry.ports) { $https.Add($fqdn) }
            if (80 -in $entry.ports) { $http.Add($fqdn) }
        }
    }
}
$httpsUnique = @($https | Sort-Object -Unique)
$httpUnique = @($http | Sort-Object -Unique)
function ConvertTo-SquidDomainList {
    param([string[]]$Fqdns)
    $converted = @($Fqdns | Sort-Object -Unique | ForEach-Object {
        if ($_.StartsWith('*.')) { $_.Substring(1) } else { $_ }
    })
    $suffixes = @($converted | Where-Object { $_.StartsWith('.') })
    foreach ($domain in $converted) {
        $covered = $false
        foreach ($suffix in $suffixes) {
            if ($domain -ne $suffix -and
                ($domain -eq $suffix.Substring(1) -or $domain.EndsWith($suffix, [StringComparison]::Ordinal))) {
                $covered = $true
                break
            }
        }
        if (-not $covered) { $domain }
    }
}
$result = [ordered]@{
    httpsFqdns = $httpsUnique
    httpFqdns = $httpUnique
    squidHttpsDomains = @(ConvertTo-SquidDomainList $httpsUnique)
    squidHttpDomains = @(ConvertTo-SquidDomainList $httpUnique)
    squidDomains = @(ConvertTo-SquidDomainList ($httpsUnique + $httpUnique))
}
$json = ($result | ConvertTo-Json -Depth 10).Replace("`r`n", "`n")
$directory = Split-Path -Parent $OutputPath
if ($directory -and -not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
[IO.File]::WriteAllText($OutputPath, "$json`n", [Text.UTF8Encoding]::new($false))
Write-Output "Generated $OutputPath ($($httpsUnique.Count) HTTPS, $($httpUnique.Count) HTTP destinations)."
