param location string = resourceGroup().location
param qualysGatewayUrl string = 'https://gateway.qg2.apps.qualys.com'
@secure()
param qualysApiToken string
var acrConnectorName = 'acr-${take(subscription().subscriptionId, 8)}-${location}'
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
var eventHubNamespaceName = 'qscan-${uniqueString(resourceGroup().id)}'
var serviceBusNamespaceName = 'qscan-sb-${uniqueString(resourceGroup().id)}'

var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var eventHubsDataReceiverRoleId = 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde'
var serviceBusDataSenderRoleId = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    accessTier: 'Hot'
    encryption: {
      services: {
        blob: { enabled: true }
        file: { enabled: true }
        table: { enabled: true }
        queue: { enabled: true }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

resource scanResultsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  name: '${storageAccountName}/default/scan-results'
  dependsOn: [storageAccount]
  properties: { publicAccess: 'None' }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2025-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource scanMetadataTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2025-01-01' = {
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

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
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

resource qualysApiTokenSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'QualysApiToken'
  properties: { value: qualysApiToken }
}

resource acrClientSecretKV 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'AcrClientSecret'
  properties: { value: acrClientSecret }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: functionAppSku
    tier: functionAppSku == 'Y1' ? 'Dynamic' : (startsWith(functionAppSku, 'EP') ? 'ElasticPremium' : 'PremiumV3')
  }
  kind: 'functionapp'
  properties: { reserved: true }
}

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: eventHubNamespaceName
  location: location
  sku: { name: 'Basic', tier: 'Basic', capacity: 1 }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
    zoneRedundant: false
    isAutoInflateEnabled: false
    kafkaEnabled: false
  }
}

resource activityLogHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: eventHubNamespace
  name: 'activity-log'
  properties: { messageRetentionInDays: 1, partitionCount: 2 }
}

resource activityLogHubSendPolicy 'Microsoft.EventHub/namespaces/eventhubs/authorizationRules@2024-01-01' = {
  parent: activityLogHub
  name: 'DiagnosticsSend'
  properties: { rights: ['Send'] }
}

resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2024-01-01' = {
  name: serviceBusNamespaceName
  location: location
  sku: { name: 'Basic', tier: 'Basic' }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
  }
}

resource scanNotificationsQueue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: serviceBusNamespace
  name: 'scan-notifications'
  properties: { maxDeliveryCount: 10, defaultMessageTimeToLive: 'P1D' }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    reserved: true
    siteConfig: {
      linuxFxVersion: 'Python|3.12'
      appSettings: concat([
        { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net' }
        { name: 'AzureWebJobsStorage__accountName', value: storageAccountName }
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
        { name: 'STORAGE_ACCOUNT_NAME', value: storageAccountName }
        { name: 'SCAN_CACHE_HOURS', value: string(scanCacheHours) }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'ENABLE_ORYX_BUILD', value: 'true' }
        { name: 'EVENTHUB_FULLYQUALIFIEDNAMESPACE', value: '${eventHubNamespaceName}.servicebus.windows.net' }
        { name: 'EVENTHUB_NAME', value: activityLogHub.name }
        { name: 'SERVICEBUS_FULLYQUALIFIEDNAMESPACE', value: '${serviceBusNamespaceName}.servicebus.windows.net' }
        { name: 'SERVICEBUS_QUEUE_NAME', value: scanNotificationsQueue.name }
      ], !empty(functionPackageUrl) ? [{ name: 'WEBSITE_RUN_FROM_PACKAGE', value: functionPackageUrl }] : [])
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      pythonVersion: '3.12'
    }
  }
}

resource keyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionApp.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageBlobRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageTableRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageTableDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource eventHubReceiverRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(eventHubNamespace.id, functionApp.id, eventHubsDataReceiverRoleId)
  scope: eventHubNamespace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventHubsDataReceiverRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource serviceBusSenderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(serviceBusNamespace.id, functionApp.id, serviceBusDataSenderRoleId)
  scope: serviceBusNamespace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', serviceBusDataSenderRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
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
output diagnosticsSendConnectionString string = activityLogHubSendPolicy.listKeys().primaryConnectionString
output serviceBusNamespace string = serviceBusNamespace.name
