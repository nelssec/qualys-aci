targetScope = 'subscription'

param location string = 'eastus'
param resourceGroupName string = 'qualys-scanner-rg'
param qualysPod string
@secure()
param qualysAccessToken string
param notificationEmail string = ''
param notifySeverityThreshold string = 'HIGH'
param scanCacheHours int = 24
param functionAppSku string = 'Y1'
param functionPackageUrl string = ''
param enableEventGrid bool = false

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
    notificationEmail: notificationEmail
    notifySeverityThreshold: notifySeverityThreshold
    scanCacheHours: scanCacheHours
    functionAppSku: functionAppSku
    functionPackageUrl: functionPackageUrl
  }
}

resource contributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, rg.id, 'Contributor')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalId: resources.outputs.functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

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
