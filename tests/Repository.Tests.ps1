#requires -Version 7.2
BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:generator = Join-Path $root 'scripts\Build-EgressPolicy.ps1'
}
Describe 'Endpoint policy compiler' {
    It 'produces stable deduplicated output and translates suffix wildcards' {
        $output = Join-Path $TestDrive 'egress.json'
        & $generator -OutputPath $output | Out-Null
        $policy = Get-Content $output -Raw | ConvertFrom-Json
        $policy.httpsFqdns | Should -Contain '*.endpoint.security.microsoft.com'
        $policy.squidDomains | Should -Contain '.endpoint.security.microsoft.com'
        $policy.squidDomains | Should -Not -Contain '*.endpoint.security.microsoft.com'
        $policy.httpFqdns | Should -Not -Contain '*.endpoint.security.microsoft.com'
        ($policy.httpsFqdns | Group-Object | Where-Object Count -GT 1) | Should -BeNullOrEmpty
        $first = Get-Content $output -Raw
        & $generator -OutputPath $output | Out-Null
        (Get-Content $output -Raw) | Should -BeExactly $first
    }
    It 'removes bootstrap-only hosts while preserving required update endpoints' {
        $output = Join-Path $TestDrive 'runtime.json'
        & $generator -OutputPath $output -Phase runtime,maintenance | Out-Null
        $policy = Get-Content $output -Raw | ConvertFrom-Json
        $policy.httpsFqdns | Should -Not -Contain 'aka.ms'
        $policy.httpsFqdns | Should -Contain 'packages.microsoft.com'
    }
    It 'rejects unsafe domains and unsupported ports before writing output' {
        foreach ($badDomain in @('*', '*.microsoft.com', 'azgn*.servicebus.windows.net', 'https://example.com/path', 'example.com;deny all')) {
            $manifest = Get-Content (Join-Path $root 'config\endpoints.json') -Raw | ConvertFrom-Json
            $manifest.endpoints[0].fqdns = @($badDomain)
            $path = Join-Path $TestDrive 'invalid.json'
            $manifest | ConvertTo-Json -Depth 12 | Set-Content $path
            { & $generator -ManifestPath $path -OutputPath (Join-Path $TestDrive 'bad.json') } | Should -Throw
        }
        $manifest.endpoints[0].fqdns = @('example.com')
        $manifest.endpoints[0].ports = @(22)
        $manifest | ConvertTo-Json -Depth 12 | Set-Content $path
        { & $generator -ManifestPath $path -OutputPath (Join-Path $TestDrive 'bad.json') } | Should -Throw
    }
    It 'collapses overlapping Squid suffixes without losing Firewall apex destinations' {
        $manifest = @{
            schemaVersion = 1; cloud = 'AzurePublic'
            endpoints = @(@{
                phase = 'runtime'; service = 'test'; purpose = 'overlap regression'
                source = 'https://example.com'; ports = @(443)
                fqdns = @('*.updates.example.com', '*.download.updates.example.com',
                    'download.updates.example.com', 'updates.example.com', 'separate.example.net')
            })
        }
        $path = Join-Path $TestDrive 'overlapping.json'
        $output = Join-Path $TestDrive 'collapsed.json'
        $manifest | ConvertTo-Json -Depth 10 | Set-Content $path
        & $generator -ManifestPath $path -OutputPath $output | Out-Null
        $policy = Get-Content $output -Raw | ConvertFrom-Json
        $policy.squidHttpsDomains | Should -HaveCount 2
        $policy.squidHttpsDomains | Should -Contain '.updates.example.com'
        $policy.squidHttpsDomains | Should -Contain 'separate.example.net'
        $policy.squidHttpDomains | Should -HaveCount 0
        $policy.httpsFqdns | Should -HaveCount 5
        $policy.httpsFqdns | Should -Contain 'updates.example.com'
    }
}
Describe 'Repository script syntax' {
    It 'parses all PowerShell without executing guest or cloud operations' {
        $parseErrors = @()
        Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1' | ForEach-Object {
            $tokens = $null; $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
            $parseErrors += $errors
        }
        $parseErrors | Should -BeNullOrEmpty
    }
}
Describe 'Portable ARM entry point' {
    BeforeAll {
        $script:arm = Get-Content (Join-Path $root 'infra\azuredeploy.json') -Raw | ConvertFrom-Json -AsHashtable
    }
    It 'does not depend on linked templates or create response automation' {
        $text = Get-Content (Join-Path $root 'infra\azuredeploy.json') -Raw
        $text | Should -Not -Match '"templateLink"\s*:'
        $text | Should -Not -Match 'Microsoft.Logic/workflows|Microsoft.SecurityInsights/automationRules'
        $arm.resources.Count | Should -BeGreaterThan 0
    }
    It 'uses a secure administrator password parameter' {
        $arm.parameters.adminPassword.type | Should -Be 'securestring'
        $arm.parameters.adminPassword.ContainsKey('defaultValue') | Should -BeFalse
    }
    It 'keeps the portal UI aligned with required ARM inputs' {
        $ui = Get-Content (Join-Path $root 'infra\createUiDefinition.json') -Raw | ConvertFrom-Json -AsHashtable
        foreach ($name in $ui.parameters.outputs.Keys) {
            $arm.parameters.ContainsKey($name) | Should -BeTrue -Because "the UI output $name must be a real deployment parameter"
        }
        foreach ($name in $arm.parameters.Keys) {
            if (-not $arm.parameters[$name].ContainsKey('defaultValue')) {
                $ui.parameters.outputs.ContainsKey($name) | Should -BeTrue -Because "the portal must collect required input $name"
            }
        }
    }
}
Describe 'Deployment approval boundary' {
    BeforeAll {
        $script:subscription = '11111111-2222-3333-4444-555555555555'
        $script:deploymentParameters = Join-Path $TestDrive 'private.parameters.json'
        '{}' | Set-Content $deploymentParameters
    }
    It 'does not mutate Azure when Apply is combined with WhatIf' {
        Mock az {
            $global:LASTEXITCODE = 0
            '{"id":"11111111-2222-3333-4444-555555555555"}'
        }
        & (Join-Path $root 'scripts\Deploy-Lab.ps1') -SubscriptionId $subscription `
            -ResourceGroupName 'rg-test' -ParametersFile $deploymentParameters `
            -Apply -LicensingAndCostReviewed -WhatIf
        Should -Invoke az -Times 1 -Exactly
    }
    It 'rejects an Apply request without explicit licensing/cost acknowledgment' {
        Mock az {
            $global:LASTEXITCODE = 0
            '{"id":"11111111-2222-3333-4444-555555555555"}'
        }
        { & (Join-Path $root 'scripts\Deploy-Lab.ps1') -SubscriptionId $subscription `
            -ResourceGroupName 'rg-test' -ParametersFile $deploymentParameters -Apply -Confirm:$false } |
            Should -Throw '*LicensingAndCostReviewed*'
        Should -Invoke az -Times 1 -Exactly
    }
}
