param prefix string
param location string
param tags object
param addressPlan object
param ips object
param privateDnsZoneName string

var workloadKeys = ['management', 'l2', 'l3Windows', 'l3Linux', 'wec', 'proxy']
var plantKeys = ['l2', 'l3Windows', 'l3Linux', 'wec']
var proxyClients = [for client in ['management', 'l2', 'l3Windows', 'l3Linux', 'wec']: '${ips[client]}/32']
var managedGuests = [for guest in ['l2', 'l3Windows', 'l3Linux', 'wec', 'proxy']: '${ips[guest]}/32']

resource routeTables 'Microsoft.Network/routeTables@2024-05-01' = [for key in workloadKeys: {
  name: '${prefix}-rt-${key}'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
  }
}]

resource nsgs 'Microsoft.Network/networkSecurityGroups@2024-05-01' = [for key in workloadKeys: {
  name: '${prefix}-nsg-${key}'
  location: location
  tags: tags
  properties: {
    securityRules: concat([
      {
        name: 'Allow-Azure-DNS'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzurePlatformDNS'
          destinationPortRange: '53'
        }
      }
      {
        name: 'Allow-Azure-wire-server'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '168.63.129.16'
          destinationPortRanges: ['80', '32526']
        }
      }
      {
        name: 'Allow-private-management'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: key == 'management' ? addressPlan.bastion : '${ips.management}/32'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: contains(['proxy', 'l3Linux'], key) ? ['22'] : ['3389']
        }
      }
      {
        name: 'Deny-other-inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-other-outbound'
        properties: {
          priority: 4000
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ], key != 'proxy' ? [
      {
        name: 'Allow-private-proxy'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '${ips.proxy}/32'
          destinationPortRange: '3128'
        }
      }
    ] : [
      {
        name: 'Allow-approved-proxy-clients'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefixes: proxyClients
          sourcePortRange: '*'
          destinationAddressPrefix: '${ips.proxy}/32'
          destinationPortRange: '3128'
        }
      }
      {
        name: 'Allow-HTTP-HTTPS-via-firewall'
        properties: {
          priority: 140
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRanges: ['80', '443']
        }
      }
    ], key == 'management' ? [
      {
        name: 'Allow-management-to-guests'
        properties: {
          priority: 150
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '${ips.management}/32'
          sourcePortRange: '*'
          destinationAddressPrefixes: managedGuests
          destinationPortRanges: ['3389', '22']
        }
      }
    ] : [], key == 'wec' ? [
      {
        name: 'Allow-WEF-from-L2'
        properties: {
          priority: 160
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '${ips.l2}/32'
          sourcePortRange: '*'
          destinationAddressPrefix: '${ips.wec}/32'
          destinationPortRange: '5986'
        }
      }
      {
        name: 'Allow-private-CRL'
        properties: {
          priority: 170
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefixes: ['${ips.l2}/32', '${ips.l3Windows}/32', '${ips.management}/32']
          sourcePortRange: '*'
          destinationAddressPrefix: '${ips.wec}/32'
          destinationPortRange: '80'
        }
      }
    ] : [], contains(['management', 'l2', 'l3Windows'], key) ? [
      {
        name: 'Allow-WEC-certificate-revocation'
        properties: {
          priority: 180
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '${ips.wec}/32'
          destinationPortRange: '80'
        }
      }
    ] : [], key == 'l2' ? [
      {
        name: 'Allow-WEF-to-WEC'
        properties: {
          priority: 190
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '${ips.l2}/32'
          sourcePortRange: '*'
          destinationAddressPrefix: '${ips.wec}/32'
          destinationPortRange: '5986'
        }
      }
    ] : [])
  }
}]

resource hub 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${prefix}-hub'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [addressPlan.hub] }
    subnets: [
      { name: 'AzureFirewallSubnet', properties: { addressPrefix: addressPlan.firewall } }
      { name: 'AzureFirewallManagementSubnet', properties: { addressPrefix: addressPlan.firewallManagement } }
      // Bastion has no NSG: Azure's complete service platform rules remain intact.
      { name: 'AzureBastionSubnet', properties: { addressPrefix: addressPlan.bastion } }
      {
        name: 'management'
        properties: {
          addressPrefix: addressPlan.management
          defaultOutboundAccess: false
          networkSecurityGroup: { id: nsgs[0].id }
          routeTable: { id: routeTables[0].id }
        }
      }
    ]
  }
}

resource plant 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${prefix}-plant'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [addressPlan.plant] }
    subnets: [for (key, i) in plantKeys: {
      name: key
      properties: {
        addressPrefix: addressPlan[key]
        defaultOutboundAccess: false
        networkSecurityGroup: { id: nsgs[i + 1].id }
        routeTable: { id: routeTables[i + 1].id }
      }
    }]
  }
}

resource dmz 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${prefix}-dmz'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [addressPlan.dmz] }
    subnets: [
      {
        name: 'proxy'
        properties: {
          addressPrefix: addressPlan.proxy
          defaultOutboundAccess: false
          networkSecurityGroup: { id: nsgs[5].id }
          routeTable: { id: routeTables[5].id }
        }
      }
    ]
  }
}

var spokeNames = [plant.name, dmz.name]
resource hubPeerings 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = [for spoke in spokeNames: {
  parent: hub
  name: 'to-${spoke}'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: { id: resourceId('Microsoft.Network/virtualNetworks', spoke) }
  }
}]
resource plantToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: plant
  name: 'to-hub'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: { id: hub.id }
  }
}
resource dmzToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: dmz
  name: 'to-hub'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: { id: hub.id }
  }
}

resource bastionPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${prefix}-bastion-pip'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}
resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: '${prefix}-bastion'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    ipConfigurations: [
      {
        name: 'bastion'
        properties: {
          subnet: { id: '${hub.id}/subnets/AzureBastionSubnet' }
          publicIPAddress: { id: bastionPip.id }
        }
      }
    ]
  }
}

resource dns 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}
resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for vnetName in [hub.name, plant.name, dmz.name]: {
  parent: dns
  name: vnetName
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: resourceId('Microsoft.Network/virtualNetworks', vnetName) }
  }
}]
resource wecDns 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: dns
  name: 'wec'
  properties: {
    ttl: 300
    aRecords: [{ ipv4Address: ips.wec }]
  }
}

output routeTableNames array = [for key in workloadKeys: '${prefix}-rt-${key}']
output subnetIds object = {
  firewall: '${hub.id}/subnets/AzureFirewallSubnet'
  firewallManagement: '${hub.id}/subnets/AzureFirewallManagementSubnet'
  management: '${hub.id}/subnets/management'
  l2: '${plant.id}/subnets/l2'
  l3Windows: '${plant.id}/subnets/l3Windows'
  l3Linux: '${plant.id}/subnets/l3Linux'
  wec: '${plant.id}/subnets/wec'
  proxy: '${dmz.id}/subnets/proxy'
}
output bastionName string = bastion.name
