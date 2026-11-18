param prefix string
param location string
param tags object
param subnetIds object
param ips object
param workspaceResourceId string
param workspaceCustomerId string

var egress = loadJsonContent('../../config/egress.json')
var manifestHttpsFqdns = [for fqdn in egress.httpsFqdns: replace(replace(fqdn, '{workspaceId}', workspaceCustomerId), '{region}', toLower(location))]
var httpsFqdns = union(manifestHttpsFqdns, [
  '${workspaceCustomerId}.ods.opinsights.azure.com'
  '${toLower(location)}.handler.control.monitor.azure.com'
])
var httpFqdns = [for fqdn in egress.httpFqdns: replace(replace(fqdn, '{workspaceId}', workspaceCustomerId), '{region}', toLower(location))]

resource policy 'Microsoft.Network/firewallPolicies@2024-05-01' = {
  name: '${prefix}-fw-policy'
  location: location
  tags: tags
  properties: {
    sku: { tier: 'Basic' }
    threatIntelMode: 'Alert'
  }
}
resource rules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: policy
  name: 'restricted-egress'
  properties: {
    priority: 100
    ruleCollections: [
      {
        name: 'private-service-chain'
        priority: 100
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: { type: 'Allow' }
        rules: [
          {
            name: 'plant-to-private-proxy'
            ruleType: 'NetworkRule'
            ipProtocols: ['TCP']
            sourceAddresses: [ips.l2, ips.l3Windows, ips.l3Linux, ips.wec]
            destinationAddresses: [ips.proxy]
            destinationPorts: ['3128']
          }
          {
            name: 'L2-to-WEC-HTTPS'
            ruleType: 'NetworkRule'
            ipProtocols: ['TCP']
            sourceAddresses: [ips.l2]
            destinationAddresses: [ips.wec]
            destinationPorts: ['5986']
          }
          {
            name: 'Windows-to-internal-CRL'
            ruleType: 'NetworkRule'
            ipProtocols: ['TCP']
            sourceAddresses: [ips.l2, ips.l3Windows]
            destinationAddresses: [ips.wec]
            destinationPorts: ['80']
          }
        ]
      }
      {
        name: 'proxy-application-egress'
        priority: 200
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: { type: 'Allow' }
        rules: concat([
          {
            name: 'proxy-approved-HTTPS'
            ruleType: 'ApplicationRule'
            sourceAddresses: [ips.proxy]
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: httpsFqdns
            terminateTLS: false
          }
          {
            name: 'proxy-bootstrap-Ubuntu-packages'
            ruleType: 'ApplicationRule'
            sourceAddresses: [ips.proxy]
            protocols: [{ protocolType: 'Http', port: 80 }]
            targetFqdns: ['archive.ubuntu.com', 'security.ubuntu.com']
            terminateTLS: false
          }
        ], empty(httpFqdns) ? [] : [
          {
            name: 'proxy-approved-HTTP'
            ruleType: 'ApplicationRule'
            sourceAddresses: [ips.proxy]
            protocols: [{ protocolType: 'Http', port: 80 }]
            targetFqdns: httpFqdns
            terminateTLS: false
          }
        ])
      }
    ]
  }
}

resource dataPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${prefix}-firewall-data-pip'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}
resource managementPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${prefix}-firewall-management-pip'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}
resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' = {
  name: '${prefix}-firewall'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Basic'
    }
    firewallPolicy: { id: policy.id }
    ipConfigurations: [
      {
        name: 'data'
        properties: {
          subnet: { id: subnetIds.firewall }
          publicIPAddress: { id: dataPip.id }
        }
      }
    ]
    managementIpConfiguration: {
      name: 'management'
      properties: {
        subnet: { id: subnetIds.firewallManagement }
        publicIPAddress: { id: managementPip.id }
      }
    }
  }
  dependsOn: [rules]
}
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'firewall-to-workspace'
  scope: firewall
  properties: {
    workspaceId: workspaceResourceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { category: 'AzureFirewallApplicationRule', enabled: true }
      { category: 'AzureFirewallNetworkRule', enabled: true }
    ]
  }
}

output privateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
