// Orchestrates complete deployment: infrastructure + Event Grid
// Note: Function code must be deployed separately via 'func azure functionapp publish'
// This is required because Azure validates Event Grid endpoints during subscription creation

param location string = resourceGroup().location

@minLength(3)
@maxLength(10)
param namePrefix string = 'qscan'

@description('Qualys POD identifier (e.g., US2, US3, EU1)')
param qualysPod string

@secure()
@description('Qualys API access token for container scanning')
param qualysAccessToken string

@description('Optional email for vulnerability notifications')
param notificationEmail string = ''

@allowed([
  'CRITICAL'
  'HIGH'
])
param notifySeverityThreshold string = 'HIGH'

@minValue(1)
@maxValue(168)
param scanCacheHours int = 24

@allowed([
  'Y1'
  'EP1'
  'EP2'
  'EP3'
  'P1v3'
  'P2v3'
  'P3v3'
  'P0v4'
  'P1v4'
  'P2v4'
  'P3v4'
])
param functionAppSku string = 'Y1'

@description('Deploy Event Grid subscriptions (set to true after function code is deployed)')
param deployEventGridSubscriptions bool = false

// Deploy main infrastructure
module infrastructure 'main.bicep' = {
  name: 'infrastructure-deployment'
  params: {
    location: location
    namePrefix: namePrefix
    qualysPod: qualysPod
    qualysAccessToken: qualysAccessToken
    notificationEmail: notificationEmail
    notifySeverityThreshold: notifySeverityThreshold
    scanCacheHours: scanCacheHours
    functionAppSku: functionAppSku
  }
}

// Deploy Event Grid subscriptions (only if function code is deployed)
module eventgrid 'eventgrid.bicep' = if (deployEventGridSubscriptions) {
  name: 'eventgrid-deployment'
  params: {
    functionAppName: infrastructure.outputs.functionAppName
    eventGridTopicName: infrastructure.outputs.eventGridTopicName
  }
  dependsOn: [
    infrastructure
  ]
}

output functionAppName string = infrastructure.outputs.functionAppName
output functionAppUrl string = infrastructure.outputs.functionAppUrl
output storageAccountName string = infrastructure.outputs.storageAccountName
output keyVaultName string = infrastructure.outputs.keyVaultName
output appInsightsName string = infrastructure.outputs.appInsightsName
output eventGridTopicName string = infrastructure.outputs.eventGridTopicName
output containerRegistryName string = infrastructure.outputs.containerRegistryName
output containerRegistryLoginServer string = infrastructure.outputs.containerRegistryLoginServer
output eventGridSubscriptionsDeployed bool = deployEventGridSubscriptions
