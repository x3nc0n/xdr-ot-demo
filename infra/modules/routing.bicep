param routeTableNames array
param firewallPrivateIp string
param addressPlan object

resource tables 'Microsoft.Network/routeTables@2024-05-01' existing = [for name in routeTableNames: {
  name: name
}]

resource defaults 'Microsoft.Network/routeTables/routes@2024-05-01' = [for (name, i) in routeTableNames: {
  parent: tables[i]
  name: 'default-via-firewall'
  properties: {
    addressPrefix: '0.0.0.0/0'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewallPrivateIp
  }
}]
// More specific than system VNet/peering routes; both directions cross the firewall.
resource plantRoutes 'Microsoft.Network/routeTables/routes@2024-05-01' = [for i in range(1, 4): {
  parent: tables[i]
  name: 'plant-via-firewall'
  properties: {
    addressPrefix: addressPlan.plant
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewallPrivateIp
  }
}]
resource dmzRoutes 'Microsoft.Network/routeTables/routes@2024-05-01' = [for i in range(1, 4): {
  parent: tables[i]
  name: 'dmz-via-firewall'
  properties: {
    addressPrefix: addressPlan.dmz
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewallPrivateIp
  }
}]
resource proxyReturn 'Microsoft.Network/routeTables/routes@2024-05-01' = {
  parent: tables[5]
  name: 'plant-return-via-firewall'
  properties: {
    addressPrefix: addressPlan.plant
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewallPrivateIp
  }
}
resource wefToCollector 'Microsoft.Network/routeTables/routes@2024-05-01' = {
  parent: tables[1]
  name: 'wef-to-collector-via-firewall'
  properties: {
    addressPrefix: '${cidrHost(addressPlan.wec, 4)}/32'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewallPrivateIp
  }
}
resource wefReturn 'Microsoft.Network/routeTables/routes@2024-05-01' = {
  parent: tables[4]
  name: 'wef-source-return-via-firewall'
  properties: {
    addressPrefix: '${cidrHost(addressPlan.l2, 4)}/32'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewallPrivateIp
  }
}
