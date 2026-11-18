targetScope = 'resourceGroup'

@description('Deploy only AFTER these Arc machines have been onboarded to THIS resource group with system-assigned identity. Never pass Compute VM resource IDs.')
param windowsMachineName string
param wecMachineName string
param linuxMachineName string
param location string = resourceGroup().location
param proxyUrl string
param localSecurityDcrId string
param wefDcrId string
param syslogDcrId string

var machines = [
  { name: windowsMachineName, type: 'AzureMonitorWindowsAgent', version: '1.0', dcrId: localSecurityDcrId }
  { name: wecMachineName, type: 'AzureMonitorWindowsAgent', version: '1.0', dcrId: wefDcrId }
  { name: linuxMachineName, type: 'AzureMonitorLinuxAgent', version: '1.0', dcrId: syslogDcrId }
]
resource arc 'Microsoft.HybridCompute/machines@2024-07-10' existing = [for machine in machines: {
  name: machine.name
}]
resource ama 'Microsoft.HybridCompute/machines/extensions@2024-07-10' = [for (machine, i) in machines: {
  parent: arc[i]
  name: machine.type
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: machine.type
    typeHandlerVersion: machine.version
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {
      proxy: {
        mode: 'application'
        address: proxyUrl
        auth: 'false'
      }
    }
  }
}]
resource associations 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = [for (machine, i) in machines: {
  name: 'otlab-${uniqueString(machine.dcrId)}'
  scope: arc[i]
  properties: {
    description: 'Explicit Arc-only telemetry association; machine must retain its system-assigned identity.'
    dataCollectionRuleId: machine.dcrId
  }
  dependsOn: [ama]
}]
output arcMachineIds array = [for machine in machines: resourceId('Microsoft.HybridCompute/machines', machine.name)]
