targetScope = 'subscription'

param location string = 'eastus'
param resourceGroupName string = 'qualys-scanner-rg'
param qualysGatewayUrl string = 'https://gateway.qg2.apps.qualys.com'
@secure()
param qualysApiToken string
param acrConnectorName string = 'qualys-aci-connector'
param acrApplicationId string
@secure()
param acrClientSecret string
param scanCacheHours int = 24
param functionAppSku string = 'Y1'
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
    qualysGatewayUrl: qualysGatewayUrl
    qualysApiToken: qualysApiToken
    acrConnectorName: acrConnectorName
    acrApplicationId: acrApplicationId
    acrClientSecret: acrClientSecret
    scanCacheHours: scanCacheHours
    functionAppSku: functionAppSku
    functionPackageUrl: functionPackageUrl
  }
}

// Custom role: Minimal permissions to read ACI and ACA container metadata
resource containerReaderRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, 'qualys-container-reader')
  properties: {
    roleName: 'Qualys Container Reader'
    description: 'Read-only access to ACI container groups and ACA container apps for vulnerability scanning'
    type: 'CustomRole'
    assignableScopes: [subscription().id]
    permissions: [
      {
        actions: [
          'Microsoft.ContainerInstance/containerGroups/read'
          'Microsoft.App/containerApps/read'
          'Microsoft.Resources/subscriptions/resourceGroups/read'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

// Assign custom role instead of Reader
resource containerReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, rg.id, 'QualysContainerReader')
  properties: {
    roleDefinitionId: containerReaderRole.id
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
      { category: 'Administrative', enabled: true }
      { category: 'Security', enabled: false }
      { category: 'ServiceHealth', enabled: false }
      { category: 'Alert', enabled: false }
      { category: 'Recommendation', enabled: false }
      { category: 'Policy', enabled: false }
      { category: 'Autoscale', enabled: false }
      { category: 'ResourceHealth', enabled: false }
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
output containerReaderRoleId string = containerReaderRole.id
