param location string = resourceGroup().location
param qualysGatewayUrl string = 'https://gateway.qg2.apps.qualys.com'
@secure()
param qualysApiToken string
var acrConnectorName = 'acr-${take(subscription().subscriptionId, 8)}'
param acrApplicationId string
@secure()
param acrClientSecret string
@minValue(1)
@maxValue(168)
param scanCacheHours int = 24
@allowed(['Y1', 'EP1', 'EP2', 'EP3', 'P1v3', 'P2v3', 'P3v3', 'P0v4', 'P1v4', 'P2v4', 'P3v4'])
param functionAppSku string = 'Y1'
param functionPackageUrl string = ''

@description('Enable private networking: VNet-integrate the function, add private endpoints, and disable public access on storage, Key Vault, Event Hub, and Service Bus. Requires an Elastic Premium/Premium plan (Consumption cannot VNet-integrate).')
param enablePrivateNetworking bool = false
@description('Resource ID of an existing subnet (delegated to Microsoft.Web/serverFarms) for function VNet integration. Required when enablePrivateNetworking is true.')
param functionSubnetId string = ''
@description('Resource ID of an existing subnet for the private endpoint NICs. Required when enablePrivateNetworking is true.')
param privateEndpointSubnetId string = ''
@description('Optional map of existing private DNS zone resource IDs keyed by sub-resource (blob, file, queue, table, vault, servicebus). When a key is present, a private DNS zone group is created for that endpoint; otherwise DNS is left to your central resolver/policy.')
param privateDnsZoneIds object = {}

// Consumption (Y1) cannot VNet-integrate; fall back to Elastic Premium when private networking is on.
var effectiveSku = (enablePrivateNetworking && functionAppSku == 'Y1') ? 'EP1' : functionAppSku
// Event Hubs / Service Bus Basic tier do not support private endpoints; Standard is the minimum.
var messagingTier = enablePrivateNetworking ? 'Standard' : 'Basic'

var storageAccountName = 'qscan${uniqueString(resourceGroup().id)}'
var functionAppName = 'qscan-${uniqueString(resourceGroup().id)}'
var appServicePlanName = 'qscan-plan-${uniqueString(resourceGroup().id)}'
var appInsightsName = 'qscan-insights-${uniqueString(resourceGroup().id)}'
var keyVaultName = 'qskv${uniqueString(resourceGroup().id)}'
var eventHubNamespaceName = 'qscan-${uniqueString(resourceGroup().id)}'
var serviceBusNamespaceName = 'qscan-sb-${uniqueString(resourceGroup().id)}'

// Cloud-agnostic endpoints derived from the deployment cloud (Public, US Gov, China, ...).
// environment() resolves from the cloud the deploying CLI/SDK is targeting.
var storageEndpointSuffix = environment().suffixes.storage
// Service Bus / Event Hub have no environment() suffix; derive from the storage suffix
// (core.windows.net -> servicebus.windows.net, core.usgovcloudapi.net -> servicebus.usgovcloudapi.net).
var serviceBusSuffix = 'servicebus.${replace(storageEndpointSuffix, 'core.', '')}'
var resourceManagerEndpoint = environment().resourceManager
var aadLoginEndpoint = environment().authentication.loginEndpoint

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
    publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: enablePrivateNetworking ? 'Deny' : 'Allow'
    }
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
    publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : 'Enabled'
    networkAcls: { bypass: 'AzureServices', defaultAction: enablePrivateNetworking ? 'Deny' : 'Allow' }
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
    name: effectiveSku
    tier: effectiveSku == 'Y1' ? 'Dynamic' : (startsWith(effectiveSku, 'EP') ? 'ElasticPremium' : 'PremiumV3')
  }
  kind: 'functionapp'
  properties: { reserved: true }
}

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: eventHubNamespaceName
  location: location
  sku: { name: messagingTier, tier: messagingTier, capacity: 1 }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : 'Enabled'
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
  sku: { name: messagingTier, tier: messagingTier }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : 'Enabled'
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
    // Regional VNet integration + route all outbound through the VNet when private.
    virtualNetworkSubnetId: enablePrivateNetworking ? functionSubnetId : null
    vnetContentShareEnabled: enablePrivateNetworking
    siteConfig: {
      linuxFxVersion: 'Python|3.12'
      vnetRouteAllEnabled: enablePrivateNetworking
      appSettings: concat([
        { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${storageEndpointSuffix}' }
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
        { name: 'EVENTHUB__fullyQualifiedNamespace', value: '${eventHubNamespaceName}.${serviceBusSuffix}' }
        { name: 'EVENTHUB_NAME', value: activityLogHub.name }
        { name: 'SERVICEBUS_FULLYQUALIFIEDNAMESPACE', value: '${serviceBusNamespaceName}.${serviceBusSuffix}' }
        { name: 'SERVICEBUS_QUEUE_NAME', value: scanNotificationsQueue.name }
        { name: 'AZURE_RESOURCE_MANAGER_ENDPOINT', value: resourceManagerEndpoint }
        { name: 'AZURE_STORAGE_SUFFIX', value: storageEndpointSuffix }
        { name: 'AZURE_AUTHORITY_HOST', value: aadLoginEndpoint }
      ], enablePrivateNetworking ? [
        { name: 'WEBSITE_CONTENTOVERVNET', value: '1' }
      ] : [], !empty(functionPackageUrl) ? [{ name: 'WEBSITE_RUN_FROM_PACKAGE', value: functionPackageUrl }] : [])
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

// Private endpoints (bring-your-own subnet). Storage needs blob/file/queue/table for the
// Functions runtime; Event Hub and Service Bus share the privatelink.servicebus.* zone.
var privateEndpointSpecs = [
  { key: 'blob', target: storageAccount.id, group: 'blob', zoneKey: 'blob' }
  { key: 'file', target: storageAccount.id, group: 'file', zoneKey: 'file' }
  { key: 'queue', target: storageAccount.id, group: 'queue', zoneKey: 'queue' }
  { key: 'table', target: storageAccount.id, group: 'table', zoneKey: 'table' }
  { key: 'vault', target: keyVault.id, group: 'vault', zoneKey: 'vault' }
  { key: 'eventhub', target: eventHubNamespace.id, group: 'namespace', zoneKey: 'servicebus' }
  { key: 'servicebus', target: serviceBusNamespace.id, group: 'namespace', zoneKey: 'servicebus' }
]

resource privateEndpoints 'Microsoft.Network/privateEndpoints@2024-05-01' = [for spec in (enablePrivateNetworking ? privateEndpointSpecs : []): {
  name: 'pe-${functionAppName}-${spec.key}'
  location: location
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: spec.key
        properties: {
          privateLinkServiceId: spec.target
          groupIds: [spec.group]
        }
      }
    ]
  }
}]

// Attach a private DNS zone group only for endpoints whose zone ID was supplied;
// otherwise DNS is left to the central resolver/Azure Policy.
resource privateEndpointDnsGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [for (spec, i) in (enablePrivateNetworking ? privateEndpointSpecs : []): if (contains(privateDnsZoneIds, spec.zoneKey)) {
  name: '${privateEndpoints[i].name}/default'
  properties: {
    privateDnsZoneConfigs: [
      { name: spec.zoneKey, properties: { privateDnsZoneId: privateDnsZoneIds[spec.zoneKey] } }
    ]
  }
}]

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
