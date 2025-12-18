param location string = resourceGroup().location
param qualysGatewayUrl string = 'https://gateway.qg2.apps.qualys.com'
@secure()
param qualysApiToken string
param acrConnectorName string = 'qualys-aci-connector'
param acrApplicationId string
@secure()
param acrClientSecret string
@minValue(1)
@maxValue(168)
param scanCacheHours int = 24
@allowed(['Y1', 'EP1', 'EP2', 'EP3', 'P1v3', 'P2v3', 'P3v3', 'P0v4', 'P1v4', 'P2v4', 'P3v4'])
param functionAppSku string = 'Y1'
param functionPackageUrl string = ''

var storageAccountName = 'qscan${uniqueString(resourceGroup().id)}'
var functionAppName = 'qscan-${uniqueString(resourceGroup().id)}'
var appServicePlanName = 'qscan-plan-${uniqueString(resourceGroup().id)}'
var appInsightsName = 'qscan-insights-${uniqueString(resourceGroup().id)}'
var keyVaultName = 'qskv${uniqueString(resourceGroup().id)}'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    accessTier: 'Hot'
    encryption: {
      services: {
        blob: { enabled: true }
        file: { enabled: true }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

resource scanResultsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: '${storageAccountName}/default/scan-results'
  dependsOn: [storageAccount]
  properties: { publicAccess: 'None' }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource scanMetadataTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-01-01' = {
  parent: tableService
  name: 'ScanMetadata'
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    RetentionInDays: 90
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: true
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    networkAcls: { bypass: 'AzureServices', defaultAction: 'Allow' }
  }
}

resource qualysApiTokenSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'QualysApiToken'
  properties: { value: qualysApiToken }
}

resource acrClientSecretKV 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'AcrClientSecret'
  properties: { value: acrClientSecret }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: functionAppSku
    tier: functionAppSku == 'Y1' ? 'Dynamic' : (startsWith(functionAppSku, 'EP') ? 'ElasticPremium' : 'PremiumV3')
  }
  kind: 'functionapp'
  properties: { reserved: true }
}

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    reserved: true
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      appSettings: concat([
        { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'python' }
        { name: 'APPINSIGHTS_INSTRUMENTATIONKEY', value: appInsights.properties.InstrumentationKey }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'QUALYS_GATEWAY_URL', value: qualysGatewayUrl }
        { name: 'QUALYS_API_TOKEN', value: '@Microsoft.KeyVault(SecretUri=${qualysApiTokenSecret.properties.secretUri})' }
        { name: 'ACR_CONNECTOR_NAME', value: acrConnectorName }
        { name: 'ACR_APPLICATION_ID', value: acrApplicationId }
        { name: 'ACR_CLIENT_SECRET', value: '@Microsoft.KeyVault(SecretUri=${acrClientSecretKV.properties.secretUri})' }
        { name: 'AZURE_SUBSCRIPTION_ID', value: subscription().subscriptionId }
        { name: 'AZURE_TENANT_ID', value: subscription().tenantId }
        { name: 'STORAGE_CONNECTION_STRING', value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}' }
        { name: 'SCAN_CACHE_HOURS', value: string(scanCacheHours) }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'ENABLE_ORYX_BUILD', value: 'true' }
        { name: 'EVENTHUB_CONNECTION_STRING', value: activityLogHubPolicy.listKeys().primaryConnectionString }
        { name: 'EVENTHUB_NAME', value: activityLogHub.name }
        { name: 'SERVICEBUS_CONNECTION_STRING', value: serviceBusSendPolicy.listKeys().primaryConnectionString }
        { name: 'SERVICEBUS_QUEUE_NAME', value: scanNotificationsTopic.name }
      ], !empty(functionPackageUrl) ? [{ name: 'WEBSITE_RUN_FROM_PACKAGE', value: functionPackageUrl }] : [])
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      pythonVersion: '3.11'
    }
  }
}

resource keyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionApp.id, 'Key Vault Secrets User')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2023-01-01-preview' = {
  name: 'qscan-${uniqueString(resourceGroup().id)}'
  location: location
  sku: { name: 'Basic', tier: 'Basic', capacity: 1 }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
    zoneRedundant: false
    isAutoInflateEnabled: false
    kafkaEnabled: false
  }
}

resource activityLogHub 'Microsoft.EventHub/namespaces/eventhubs@2023-01-01-preview' = {
  parent: eventHubNamespace
  name: 'activity-log'
  properties: { messageRetentionInDays: 1, partitionCount: 2 }
}

resource activityLogHubPolicy 'Microsoft.EventHub/namespaces/eventhubs/authorizationRules@2023-01-01-preview' = {
  parent: activityLogHub
  name: 'FunctionAppListen'
  properties: { rights: ['Listen'] }
}

resource activityLogHubSendPolicy 'Microsoft.EventHub/namespaces/eventhubs/authorizationRules@2023-01-01-preview' = {
  parent: activityLogHub
  name: 'DiagnosticsSend'
  properties: { rights: ['Send'] }
}

resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: 'qscan-sb-${uniqueString(resourceGroup().id)}'
  location: location
  sku: { name: 'Basic', tier: 'Basic' }
  properties: { minimumTlsVersion: '1.2', publicNetworkAccess: 'Enabled' }
}

resource scanNotificationsTopic 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: serviceBusNamespace
  name: 'scan-notifications'
  properties: { maxDeliveryCount: 10, defaultMessageTimeToLive: 'P1D' }
}

resource serviceBusSendPolicy 'Microsoft.ServiceBus/namespaces/AuthorizationRules@2022-10-01-preview' = {
  parent: serviceBusNamespace
  name: 'FunctionAppSend'
  properties: { rights: ['Send'] }
}

output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output storageAccountName string = storageAccount.name
output keyVaultName string = keyVault.name
output appInsightsName string = appInsights.name
output functionAppPrincipalId string = functionApp.identity.principalId
output functionAppId string = functionApp.id
output eventHubNamespace string = eventHubNamespace.name
output activityLogHub string = activityLogHub.name
output eventHubConnectionString string = activityLogHubPolicy.listKeys().primaryConnectionString
output diagnosticsSendConnectionString string = activityLogHubSendPolicy.listKeys().primaryConnectionString
output serviceBusNamespace string = serviceBusNamespace.name
output serviceBusConnectionString string = serviceBusSendPolicy.listKeys().primaryConnectionString
