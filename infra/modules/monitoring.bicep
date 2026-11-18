param prefix string
param location string
param tags object
param retentionInDays int
param dailyQuotaGb int
param budgetEmails array
param monthlyBudgetAmount int
param budgetStartDate string = utcNow('yyyy-MM-01')

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-law-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionInDays
    workspaceCapping: { dailyQuotaGb: dailyQuotaGb }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}
resource sentinel 'Microsoft.SecurityInsights/onboardingStates@2024-03-01' = {
  name: 'default'
  scope: workspace
  properties: { customerManagedKey: false }
}
resource localSecurity 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: '${prefix}-dcr-local-security'
  location: location
  tags: tags
  kind: 'Windows'
  properties: {
    description: 'Selected local Windows Security events -> SecurityEvent; associate only with the sensitive Windows Arc machine.'
    dataSources: {
      windowsEventLogs: [
        {
          name: 'localSecurity'
          streams: ['Microsoft-SecurityEvent']
          xPathQueries: ['Security!*[System[(EventID=4624 or EventID=4625 or EventID=4688 or EventID=1102)]]']
        }
      ]
    }
    destinations: { logAnalytics: [{ name: 'workspace', workspaceResourceId: workspace.id }] }
    dataFlows: [{ streams: ['Microsoft-SecurityEvent'], destinations: ['workspace'] }]
  }
}
resource wef 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: '${prefix}-dcr-wef'
  location: location
  tags: tags
  kind: 'Windows'
  properties: {
    description: 'WEC forwarded events -> WindowsEvent, not SecurityEvent. Event selection is constrained by the source subscription.'
    dataSources: {
      windowsEventLogs: [
        {
          name: 'forwardedEvents'
          streams: ['Microsoft-WindowsEvent']
          xPathQueries: ['ForwardedEvents!*']
        }
      ]
    }
    destinations: { logAnalytics: [{ name: 'workspace', workspaceResourceId: workspace.id }] }
    dataFlows: [{ streams: ['Microsoft-WindowsEvent'], destinations: ['workspace'] }]
  }
}
resource syslog 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: '${prefix}-dcr-syslog'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    description: 'Synthetic local0 application events only -> Syslog.'
    dataSources: {
      syslog: [
        {
          name: 'syntheticSyslog'
          streams: ['Microsoft-Syslog']
          facilityNames: ['local0']
          logLevels: ['Debug', 'Info', 'Notice', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency']
        }
      ]
    }
    destinations: { logAnalytics: [{ name: 'workspace', workspaceResourceId: workspace.id }] }
    dataFlows: [{ streams: ['Microsoft-Syslog'], destinations: ['workspace'] }]
  }
}
resource budget 'Microsoft.Consumption/budgets@2023-11-01' = if (!empty(budgetEmails)) {
  name: '${prefix}-monthly-budget'
  properties: {
    category: 'Cost'
    amount: monthlyBudgetAmount
    timeGrain: 'Monthly'
    timePeriod: { startDate: budgetStartDate }
    notifications: {
      actual80Percent: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: budgetEmails
      }
    }
  }
}

output workspaceResourceId string = workspace.id
output workspaceName string = workspace.name
output workspaceCustomerId string = workspace.properties.customerId
output dcrIds object = {
  localSecurity: localSecurity.id
  wef: wef.id
  syslog: syslog.id
}
