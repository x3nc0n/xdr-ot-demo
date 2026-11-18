targetScope = 'resourceGroup'

@description('Azure region; verify Firewall Basic, Bastion Basic and VM image/SKU availability before deployment.')
param location string = resourceGroup().location

@minLength(2)
@maxLength(8)
param prefix string = 'otlab'

param adminUsername string = 'labadmin'

@secure()
@minLength(12)
@maxLength(123)
@description('Windows local administrator password. Supply interactively or by Key Vault reference; never commit it.')
param adminPassword string

@description('OpenSSH public key for both Ubuntu VMs. Never supply a private key.')
param linuxSshPublicKey string

param windowsVmSize string = 'Standard_D2s_v5'
param linuxVmSize string = 'Standard_B2s'
param windowsServerImageVersion string = 'latest'
param windows11ImageVersion string = 'latest'
param ubuntuImageVersion string = 'latest'
param privateDnsZoneName string = 'ot.demo.test'
param tags object = {
  workload: 'synthetic-ot-lab'
  owner: 'x3nc0n'
}

@description('Nonoverlapping private CIDRs. Each VM uses host offset 4 in its subnet.')
param addressPlan object = {
  hub: '10.10.0.0/16'
  firewall: '10.10.0.0/26'
  firewallManagement: '10.10.0.64/26'
  bastion: '10.10.1.0/26'
  management: '10.10.2.0/24'
  plant: '10.20.0.0/16'
  l2: '10.20.2.0/24'
  l3Windows: '10.20.3.0/24'
  l3Linux: '10.20.4.0/24'
  wec: '10.20.5.0/24'
  dmz: '10.30.0.0/16'
  proxy: '10.30.1.0/24'
}

@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Daily workspace cap in GB; a cap may interrupt collection and is not a spending guarantee.')
@minValue(1)
param dailyQuotaGb int = 1

@description('Optional subscription budget contacts; leave empty to avoid creating a budget.')
param budgetEmails array = []
param monthlyBudgetAmount int = 250

var names = {
  management: '${prefix}-mgmt'
  l2: '${prefix}-w11'
  l3Windows: '${prefix}-win'
  l3Linux: '${prefix}-linux'
  wec: '${prefix}-wec'
  proxy: '${prefix}-proxy'
}
var ips = {
  management: cidrHost(addressPlan.management, 4)
  l2: cidrHost(addressPlan.l2, 4)
  l3Windows: cidrHost(addressPlan.l3Windows, 4)
  l3Linux: cidrHost(addressPlan.l3Linux, 4)
  wec: cidrHost(addressPlan.wec, 4)
  proxy: cidrHost(addressPlan.proxy, 4)
}

module monitoring 'modules/monitoring.bicep' = {
  name: '${prefix}-monitoring'
  params: {
    prefix: prefix
    location: location
    tags: tags
    retentionInDays: retentionInDays
    dailyQuotaGb: dailyQuotaGb
    budgetEmails: budgetEmails
    monthlyBudgetAmount: monthlyBudgetAmount
  }
}

module network 'modules/network.bicep' = {
  name: '${prefix}-network'
  params: {
    prefix: prefix
    location: location
    tags: tags
    addressPlan: addressPlan
    ips: ips
    privateDnsZoneName: privateDnsZoneName
  }
}

module firewall 'modules/firewall.bicep' = {
  name: '${prefix}-firewall'
  params: {
    prefix: prefix
    location: location
    tags: tags
    subnetIds: network.outputs.subnetIds
    ips: ips
    workspaceResourceId: monitoring.outputs.workspaceResourceId
    workspaceCustomerId: monitoring.outputs.workspaceCustomerId
  }
}

module routing 'modules/routing.bicep' = {
  name: '${prefix}-routing'
  params: {
    routeTableNames: network.outputs.routeTableNames
    firewallPrivateIp: firewall.outputs.privateIp
    addressPlan: addressPlan
  }
}

module compute 'modules/compute.bicep' = {
  name: '${prefix}-compute'
  params: {
    location: location
    tags: tags
    names: names
    ips: ips
    subnetIds: network.outputs.subnetIds
    adminUsername: adminUsername
    adminPassword: adminPassword
    linuxSshPublicKey: linuxSshPublicKey
    windowsVmSize: windowsVmSize
    linuxVmSize: linuxVmSize
    windowsServerImageVersion: windowsServerImageVersion
    windows11ImageVersion: windows11ImageVersion
    ubuntuImageVersion: ubuntuImageVersion
    workspaceCustomerId: monitoring.outputs.workspaceCustomerId
  }
  dependsOn: [
    routing
    firewall
  ]
}

output vmNames object = names
output privateIps object = ips
output proxyUrl string = 'http://${ips.proxy}:3128'
output collectorFqdn string = 'wec.${privateDnsZoneName}'
output workspaceId string = monitoring.outputs.workspaceResourceId
output workspaceName string = monitoring.outputs.workspaceName
output workspaceCustomerId string = monitoring.outputs.workspaceCustomerId
output dcrIds object = monitoring.outputs.dcrIds
output firewallPrivateIp string = firewall.outputs.privateIp
output bastionName string = network.outputs.bastionName
