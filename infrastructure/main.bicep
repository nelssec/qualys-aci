targetScope = 'subscription'

param location string = 'eastus'
param resourceGroupName string = 'qualys-scanner-rg'

@description('Qualys Gateway URL for your POD')
param qualysGatewayUrl string = 'https://gateway.qg2.apps.qualys.com'

@secure()
@description('Qualys API Bearer Token')
param qualysApiToken string

@description('Name for the ACR connector in Qualys')
param acrConnectorName string = 'qualys-aci-connector'

@description('Service Principal Application (Client) ID for ACR access')
param acrApplicationId string

@secure()
@description('Service Principal Client Secret for ACR access')
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

// Grant Reader role at subscription level for reading container metadata
// Required to fetch ACI/ACA container details via Azure Management API
resource readerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, rg.id, 'Reader')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: resources.outputs.functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Note: AcrPull role is NOT needed here because Qualys uses the Service Principal
// to pull images directly. The Service Principal should have AcrPull on relevant ACRs.

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
