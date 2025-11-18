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
param namePrefix string = 'qscan'
param enableEventGrid bool = true

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module resources 'resources.bicep' = {
  scope: rg
  name: 'qualys-scanner-resources'
  params: {
    location: location
    namePrefix: namePrefix
    qualysPod: qualysPod
    qualysAccessToken: qualysAccessToken
    notificationEmail: notificationEmail
    notifySeverityThreshold: notifySeverityThreshold
    scanCacheHours: scanCacheHours
    functionAppSku: functionAppSku
    functionPackageUrl: functionPackageUrl
    enableEventGrid: enableEventGrid
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

output functionAppName string = resources.outputs.functionAppName
output functionAppUrl string = resources.outputs.functionAppUrl
output storageAccountName string = resources.outputs.storageAccountName
output keyVaultName string = resources.outputs.keyVaultName
output appInsightsName string = resources.outputs.appInsightsName
output functionAppPrincipalId string = resources.outputs.functionAppPrincipalId
output eventGridTopicName string = resources.outputs.eventGridTopicName
output containerRegistryName string = resources.outputs.containerRegistryName
output containerRegistryLoginServer string = resources.outputs.containerRegistryLoginServer
output resourceGroupName string = rg.name
