targetScope = 'subscription'

@description('Location for central resources')
param location string = 'eastus'

@description('Resource group name for central scanner')
param resourceGroupName string = 'qualys-scanner-rg'

@description('Qualys POD identifier (e.g., US2, US3, EU1)')
param qualysPod string

@secure()
@description('Qualys API access token for container scanning')
param qualysAccessToken string

@description('Hours to cache scan results before rescanning')
param scanCacheHours int = 24

@description('Function App SKU')
param functionAppSku string = 'Y1'

@description('URL to function app deployment package (optional)')
param functionPackageUrl string = ''

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module resources 'resources.bicep' = {
  scope: rg
  name: 'qualys-scanner-resources'
  params: {
    location: location
    qualysPod: qualysPod
    qualysAccessToken: qualysAccessToken
    scanCacheHours: scanCacheHours
    functionAppSku: functionAppSku
    functionPackageUrl: functionPackageUrl
  }
}

// Grant Reader role at subscription level for reading container metadata in central subscription
resource readerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, rg.id, 'Reader')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: resources.outputs.functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Grant AcrPull role at subscription level for scanning ACR images in central subscription
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, rg.id, 'AcrPull')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: resources.outputs.functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Configure Activity Log for central subscription to send to local Event Hub
resource activityLogDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'activity-log-to-eventhub'
  scope: subscription()
  properties: {
    eventHubAuthorizationRuleId: '${subscription().id}/resourceGroups/${resourceGroupName}/providers/Microsoft.EventHub/namespaces/${resources.outputs.eventHubNamespace}/authorizationRules/RootManageSharedAccessKey'
    eventHubName: resources.outputs.activityLogHub
    logs: [
      {
        category: 'Administrative'
        enabled: true
      }
      {
        category: 'Security'
        enabled: false
      }
      {
        category: 'ServiceHealth'
        enabled: false
      }
      {
        category: 'Alert'
        enabled: false
      }
      {
        category: 'Recommendation'
        enabled: false
      }
      {
        category: 'Policy'
        enabled: false
      }
      {
        category: 'Autoscale'
        enabled: false
      }
      {
        category: 'ResourceHealth'
        enabled: false
      }
    ]
  }
}

output functionAppName string = resources.outputs.functionAppName
output functionAppUrl string = resources.outputs.functionAppUrl
output storageAccountName string = resources.outputs.storageAccountName
output keyVaultName string = resources.outputs.keyVaultName
output appInsightsName string = resources.outputs.appInsightsName
output functionAppPrincipalId string = resources.outputs.functionAppPrincipalId
output resourceGroupName string = rg.name
output eventHubNamespace string = resources.outputs.eventHubNamespace
output diagnosticsSendConnectionString string = resources.outputs.diagnosticsSendConnectionString
output centralSubscriptionId string = subscription().subscriptionId
