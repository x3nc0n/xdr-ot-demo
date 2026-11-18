param location string
param tags object
param names object
param ips object
param subnetIds object
param adminUsername string
@secure()
param adminPassword string
param linuxSshPublicKey string
param windowsVmSize string
param linuxVmSize string
param windowsServerImageVersion string
param windows11ImageVersion string
param ubuntuImageVersion string
param workspaceCustomerId string

var keys = ['management', 'l2', 'l3Windows', 'l3Linux', 'wec', 'proxy']
var linuxKeys = ['l3Linux', 'proxy']
var egress = loadJsonContent('../../config/egress.json')
var manifestSquidDomains = [for domain in egress.squidHttpsDomains: replace(replace(domain, '{workspaceId}', workspaceCustomerId), '{region}', toLower(location))]
var allHttpsDomains = union(manifestSquidDomains, [
  '${workspaceCustomerId}.ods.opinsights.azure.com'
  '${toLower(location)}.handler.control.monitor.azure.com'
])
var manifestHttpDomains = [for domain in egress.squidHttpDomains: replace(replace(domain, '{workspaceId}', workspaceCustomerId), '{region}', toLower(location))]
var allHttpDomains = union(manifestHttpDomains, ['archive.ubuntu.com', 'security.ubuntu.com'])
// Adding deployment-specific endpoints must not reintroduce Squid's fatal overlapping ACL entries.
var squidDomains = filter(allHttpsDomains, domain => empty(filter(allHttpsDomains, candidate => candidate != domain && startsWith(candidate, '.') && (endsWith(domain, candidate) || domain == substring(candidate, 1)))))
var allowedHttpDomains = filter(allHttpDomains, domain => empty(filter(allHttpDomains, candidate => candidate != domain && startsWith(candidate, '.') && (endsWith(domain, candidate) || domain == substring(candidate, 1)))))
var clientIps = [ips.management, ips.l2, ips.l3Windows, ips.l3Linux, ips.wec]
var squidConfig = replace(replace(loadTextContent('../../proxy/squid.conf.template'), '__PROXY_IP__', ips.proxy), '__CLIENT_IPS__', join(clientIps, ' '))
var cloudInit = replace(replace(replace(loadTextContent('../../proxy/cloud-init.yaml'), '__SQUID_CONFIG_BASE64__', base64(squidConfig)), '__HTTPS_DOMAINS_BASE64__', base64(join(squidDomains, '\n'))), '__HTTP_DOMAINS_BASE64__', base64(join(allowedHttpDomains, '\n')))

resource nics 'Microsoft.Network/networkInterfaces@2024-05-01' = [for key in keys: {
  name: '${names[key]}-nic'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: false
    ipConfigurations: [
      {
        name: 'private'
        properties: {
          primary: true
          privateIPAllocationMethod: 'Static'
          privateIPAddress: ips[key]
          subnet: { id: subnetIds[key] }
        }
      }
    ]
  }
}]

resource vms 'Microsoft.Compute/virtualMachines@2024-07-01' = [for (key, i) in keys: {
  name: names[key]
  location: location
  tags: union(tags, { role: key })
  identity: { type: contains(['l3Windows', 'l3Linux', 'wec'], key) ? 'None' : 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: contains(linuxKeys, key) ? linuxVmSize : windowsVmSize }
    licenseType: key == 'l2' ? 'Windows_Client' : null
    storageProfile: {
      imageReference: contains(linuxKeys, key) ? {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: ubuntuImageVersion
      } : key == 'l2' ? {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'windows-11'
        sku: 'win11-24h2-ent'
        version: windows11ImageVersion
      } : {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: windowsServerImageVersion
      }
      osDisk: {
        name: '${names[key]}-os'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    osProfile: union({
      computerName: names[key]
      adminUsername: adminUsername
    }, contains(linuxKeys, key) ? {
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: linuxSshPublicKey
            }
          ]
        }
      }
    } : {
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: false
        patchSettings: {
          patchMode: 'Manual'
          assessmentMode: 'ImageDefault'
        }
      }
    }, key == 'proxy' ? { customData: base64(cloudInit) } : {})
    networkProfile: {
      networkInterfaces: [{ id: nics[i].id, properties: { primary: true, deleteOption: 'Delete' } }]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}]
