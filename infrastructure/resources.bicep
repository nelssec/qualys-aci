param location string = resourceGroup().location

@description('Qualys POD identifier (e.g., US2, US3, EU1)')
param qualysPod string

@secure()
@description('Qualys API access token for container scanning')
param qualysAccessToken string

@minValue(1)
@maxValue(168)
@description('Hours to cache scan results before rescanning')
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
@description('Function App SKU. Y1=Consumption (requires Y1 VM quota), EP=ElasticPremium, P=Premium')
param functionAppSku string = 'Y1'

@description('URL to function app deployment package (zip file). Leave empty to skip automatic deployment.')
param functionPackageUrl string = ''

// Resource naming with Azure constraints
// Storage: 3-24 chars, alphanumeric only (qscan=5 + uniqueString=13 = 18 chars)
// Key Vault: 3-24 chars, alphanumeric and hyphens (qskv=4 + uniqueString=13 = 17 chars)
// uniqueString always generates exactly 13 characters
var storageAccountName = 'qscan${uniqueString(resourceGroup().id)}'
var functionAppName = 'qscan-${uniqueString(resourceGroup().id)}'
var appServicePlanName = 'qscan-plan-${uniqueString(resourceGroup().id)}'
var appInsightsName = 'qscan-insights-${uniqueString(resourceGroup().id)}'
var keyVaultName = 'qskv${uniqueString(resourceGroup().id)}'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    accessTier: 'Hot'
    encryption: {
      services: {
        blob: {
          enabled: true
        }
        file: {
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

resource scanResultsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: '${storageAccountName}/default/scan-results'
  dependsOn: [
    storageAccount
  ]
  properties: {
    publicAccess: 'None'
  }
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
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: true
    enableRbacAuthorization: true
    // Soft delete enabled - secrets recoverable for 90 days after deletion
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    // Purge protection - CRITICAL for enterprise: prevents permanent deletion even by admins
    // Once enabled, cannot be disabled. Secrets must wait full retention period before permanent deletion.
    enablePurgeProtection: true
    networkAcls: {
      // Allow Azure services to access Key Vault (required for Function App managed identity)
      bypass: 'AzureServices'
      // Default deny - only Azure services and explicitly allowed IPs can access
      defaultAction: 'Deny'
      // IP rules can be added here for admin access if needed
      ipRules: []
      // Virtual network rules can be added here for VNet integration
      virtualNetworkRules: []
    }
  }
}

resource qualysAccessTokenSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'QualysAccessToken'
  properties: {
    value: qualysAccessToken
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: functionAppSku
    tier: functionAppSku == 'Y1' ? 'Dynamic' : (startsWith(functionAppSku, 'EP') ? 'ElasticPremium' : 'PremiumV3')
  }
  kind: 'functionapp'
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    reserved: true
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      appSettings: concat([
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'QUALYS_POD'
          value: qualysPod
        }
        {
          name: 'QUALYS_ACCESS_TOKEN'
          value: '@Microsoft.KeyVault(SecretUri=${qualysAccessTokenSecret.properties.secretUri})'
        }
        {
          name: 'AZURE_SUBSCRIPTION_ID'
          value: subscription().subscriptionId
        }
        {
          name: 'AZURE_TENANT_ID'
          value: subscription().tenantId
        }
        {
          name: 'STORAGE_CONNECTION_STRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'SCAN_CACHE_HOURS'
          value: string(scanCacheHours)
        }
        {
          name: 'SCAN_TIMEOUT'
          value: '1800'
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        {
          name: 'ENABLE_ORYX_BUILD'
          value: 'true'
        }
        {
          name: 'EVENTHUB_CONNECTION_STRING'
          value: activityLogHubPolicy.listKeys().primaryConnectionString
        }
        {
          name: 'EVENTHUB_NAME'
          value: activityLogHub.name
        }
      ], !empty(functionPackageUrl) ? [
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: functionPackageUrl
        }
      ] : [])
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
  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 1
  }
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
  properties: {
    messageRetentionInDays: 1
    partitionCount: 2
  }
}

resource activityLogHubPolicy 'Microsoft.EventHub/namespaces/eventhubs/authorizationRules@2023-01-01-preview' = {
  parent: activityLogHub
  name: 'FunctionAppListen'
  properties: {
    rights: [
      'Listen'
    ]
  }
}

resource activityLogHubSendPolicy 'Microsoft.EventHub/namespaces/eventhubs/authorizationRules@2023-01-01-preview' = {
  parent: activityLogHub
  name: 'DiagnosticsSend'
  properties: {
    rights: [
      'Send'
    ]
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
output eventHubConnectionString string = activityLogHubPolicy.listKeys().primaryConnectionString
output diagnosticsSendConnectionString string = activityLogHubSendPolicy.listKeys().primaryConnectionString
