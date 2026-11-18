BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $main = Get-Content (Join-Path $root 'infra\azuredeploy.json') -Raw | ConvertFrom-Json
    $script:arc = Get-Content (Join-Path $root 'infra\arc-monitoring.json') -Raw | ConvertFrom-Json
    function Get-LabModule([string]$Suffix) {
        $main.resources | Where-Object { $_.name -like "*-$Suffix'*" }
    }
    $computeModule = Get-LabModule 'compute'
    $compute = $computeModule.properties.template
    $script:network = (Get-LabModule 'network').properties.template
    $script:firewall = (Get-LabModule 'firewall').properties.template
    $routingModule = Get-LabModule 'routing'
    $script:routing = $routingModule.properties.template
    $script:vm = $compute.resources | Where-Object type -EQ 'Microsoft.Compute/virtualMachines'
    $script:squid = Get-Content (Join-Path $root 'proxy\squid.conf.template') -Raw
    $script:cloudInit = Get-Content (Join-Path $root 'proxy\cloud-init.yaml') -Raw
}

Describe 'Compiled private OT infrastructure contracts' {
    It 'embeds every nested template without a remote template dependency' {
        function Assert-InlineTemplate($Template) {
            foreach ($resource in $Template.resources) {
                if ($resource.type -eq 'Microsoft.Resources/deployments') {
                    $resource.properties.PSObject.Properties.Name | Should -Not -Contain 'templateLink'
                    $resource.properties.template | Should -Not -BeNullOrEmpty
                    Assert-InlineTemplate $resource.properties.template
                }
            }
        }
        Assert-InlineTemplate $main
        Assert-InlineTemplate $arc
    }

    It 'waits for firewall policy and all routes before starting VM bootstrap' {
        ($computeModule.dependsOn -join "`n") | Should -Match '\{0\}-firewall'
        ($computeModule.dependsOn -join "`n") | Should -Match '\{0\}-routing'
        ($routingModule.dependsOn -join "`n") | Should -Match '\{0\}-firewall'
        $fw = $firewall.resources | Where-Object type -EQ 'Microsoft.Network/azureFirewalls'
        ($fw.dependsOn -join "`n") | Should -Match 'firewallPolicies/ruleCollectionGroups'
        $policyRules = $firewall.resources |
            Where-Object type -EQ 'Microsoft.Network/firewallPolicies/ruleCollectionGroups'
        ($policyRules.dependsOn -join "`n") | Should -Match 'Microsoft.Network/firewallPolicies'
    }

    It 'routes through the returned firewall NIC address rather than an assumed subnet host' {
        $routingModule.properties.parameters.firewallPrivateIp.value |
            Should -Match 'outputs\.privateIp\.value'
        $firewall.outputs.privateIp.value |
            Should -Match 'ipConfigurations\[0\]\.properties\.privateIPAddress'
        foreach ($route in $routing.resources) {
            $route.properties.nextHopType | Should -Be 'VirtualAppliance'
            $route.properties.nextHopIpAddress | Should -Be "[parameters('firewallPrivateIp')]"
        }
        ($routing.resources.name -join "`n") | Should -Match 'wef-to-collector-via-firewall'
        ($routing.resources.name -join "`n") | Should -Match 'wef-source-return-via-firewall'
        ($routing.resources.name -join "`n") | Should -Match 'plant-return-via-firewall'
    }

    It 'provisions private VMs with Enterprise client licensing and separate Arc identities' {
        $compute.variables.keys.Count | Should -Be 6
        $nic = $compute.resources | Where-Object type -EQ 'Microsoft.Network/networkInterfaces'
        ($nic | ConvertTo-Json -Depth 20) | Should -Not -Match '"publicIPAddress"'
        $vm.properties.storageProfile.imageReference |
            Should -Match "'MicrosoftWindowsDesktop'.*'windows-11'.*'win11-24h2-ent'"
        $vm.properties.licenseType | Should -Match "'l2'\), 'Windows_Client', null\(\)"
        $vm.identity.type | Should -Match "'l3Windows', 'l3Linux', 'wec'.*'None'"
        $main.parameters.adminPassword.type | Should -Be 'securestring'
        @($arc.resources | Where-Object type -EQ 'Microsoft.HybridCompute/machines').Count |
            Should -Be 0
        @($arc.resources | Where-Object type -EQ 'Microsoft.Compute/virtualMachines/extensions').Count |
            Should -Be 0
    }

    It 'allows only private firewall service hops and proxy-sourced public applications' {
        $group = $firewall.resources |
            Where-Object type -EQ 'Microsoft.Network/firewallPolicies/ruleCollectionGroups'
        $networkRules = $group.properties.ruleCollections[0].rules
        foreach ($rule in $networkRules) {
            $rule.destinationPorts | Should -Not -Contain '443'
        }
        $proxyHop = $networkRules | Where-Object name -EQ 'plant-to-private-proxy'
        $proxyHop.destinationAddresses[0] | Should -Be "[parameters('ips').proxy]"
        $proxyHop.destinationPorts | Should -Contain '3128'
        # Application rules use a concat expression, so inspect its compiled source binding.
        $applicationRules = $group.properties.ruleCollections[1].rules
        $applicationRules | Should -Match "'sourceAddresses', createArray\(parameters\('ips'\)\.proxy\)"
        $networkRules.sourceAddresses | Should -Not -Contain '*'
        $nsgs = $network.resources | Where-Object type -EQ 'Microsoft.Network/networkSecurityGroups'
        $nsgs.properties.securityRules | Should -Match "'management'.*'Allow-private-proxy'"
        $nsgs.properties.securityRules | Should -Match "'destinationAddressPrefix', format\('\{0\}/32', parameters\('ips'\)\.proxy\)"
        $nsgs.properties.securityRules | Should -Match 'Deny-other-outbound'
    }

    It 'replaces every embedded template marker and separates HTTP from CONNECT permissions' {
        $markers = [regex]::Matches($cloudInit, '__[A-Z_]+__').Value | Select-Object -Unique
        foreach ($marker in $markers) {
            $compute.variables.cloudInit | Should -Match ([regex]::Escape("'$marker'"))
        }
        $markers = [regex]::Matches($squid, '__[A-Z_]+__').Value | Select-Object -Unique
        foreach ($marker in $markers) {
            $compute.variables.squidConfig | Should -Match ([regex]::Escape("'$marker'"))
        }
        ($compute.variables.copy | Where-Object name -EQ 'manifestSquidDomains').input |
            Should -Match 'squidHttpsDomains'
        ($compute.variables.copy | Where-Object name -EQ 'manifestHttpDomains').input |
            Should -Match 'squidHttpDomains'
        $compute.variables.squidDomains | Should -Match 'filter\(variables\(''allHttpsDomains''\)'
        $compute.variables.allowedHttpDomains | Should -Match 'filter\(variables\(''allHttpDomains''\)'
        $squid | Should -Not -Match '(?m)^acl localhost '
        $squid | Should -Match '(?m)^http_access deny CONNECT !SSL_ports\r?$'
        $squid | Should -Match '(?m)^http_access allow lab_clients CONNECT approved_tls\r?$'
        $squid | Should -Match '(?m)^http_access allow lab_clients !CONNECT HTTP_ports approved_http\r?$'
        $squid | Should -Not -Match '(?m)^http_access allow (all|lab_clients)\s*$'
        $squid | Should -Match '(?m)^http_access deny all\r?$'
    }

    It 'publishes the WEC name into private DNS linked to each VNet' {
        $record = $network.resources | Where-Object type -EQ 'Microsoft.Network/privateDnsZones/A'
        $record.name | Should -Match "'wec'"
        $record.properties.aRecords[0].ipv4Address | Should -Be "[parameters('ips').wec]"
        $links = $network.resources |
            Where-Object type -EQ 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
        $links.properties.registrationEnabled | Should -BeFalse
        $links.copy.count | Should -Match 'length\(createArray'
        $main.outputs.collectorFqdn.value |
            Should -Be "[format('wec.{0}', parameters('privateDnsZoneName'))]"
    }

    It 'keeps the JSON parameter example password in Key Vault rather than a value fixture' {
        $sample = Get-Content (Join-Path $root 'infra\parameters\private.parameters.example.json') -Raw |
            ConvertFrom-Json
        $sample.parameters.adminPassword.PSObject.Properties.Name | Should -Not -Contain 'value'
        $sample.parameters.adminPassword.reference.keyVault.id |
            Should -Match '/providers/Microsoft.KeyVault/vaults/'
        $sample.parameters.adminPassword.reference.secretName | Should -Not -BeNullOrEmpty
    }
}
