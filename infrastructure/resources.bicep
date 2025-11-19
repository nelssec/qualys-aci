param location string = resourceGroup().location

@minLength(3)
@maxLength(10)
@description('Prefix for resource names.')
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
@description('Minimum severity level for notifications')
param notifySeverityThreshold string = 'HIGH'

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

@description('Enable Event Grid subscriptions. Set to true after function code is deployed.')
param enableEventGrid bool = false

@description('Use existing subscription-level system topic instead of creating new one')
param useExistingSystemTopic bool = true

@description('Existing system topic name (if useExistingSystemTopic is true)')
param existingSystemTopicName string = ''

@description('Existing system topic resource group (if useExistingSystemTopic is true)')
param existingSystemTopicResourceGroup string = 'Default-EventGrid'

// Resource naming with Azure constraints
// Storage: 3-24 chars, alphanumeric only (qscan=5 + uniqueString=13 = 18 chars)
// Key Vault: 3-24 chars, alphanumeric and hyphens (qskv=4 + uniqueString=13 = 17 chars)
// uniqueString always generates exactly 13 characters
var storageAccountName = 'qscan${uniqueString(resourceGroup().id)}'
var functionAppName = '${namePrefix}-func-${uniqueString(resourceGroup().id)}'
var appServicePlanName = '${namePrefix}-plan-${uniqueString(resourceGroup().id)}'
var appInsightsName = '${namePrefix}-insights-${uniqueString(resourceGroup().id)}'
var keyVaultName = 'qskv${uniqueString(resourceGroup().id)}'
var acrName = 'qscanacr${uniqueString(resourceGroup().id)}'

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

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
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
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
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
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(functionAppName)
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
          name: 'QSCANNER_RESOURCE_GROUP'
          value: resourceGroup().name
        }
        {
          name: 'AZURE_REGION'
          value: location
        }
        {
          name: 'QSCANNER_IMAGE'
          value: '${acrName}.azurecr.io/qualys/qscanner:latest'
        }
        {
          name: 'STORAGE_CONNECTION_STRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'NOTIFICATION_EMAIL'
          value: notificationEmail
        }
        {
          name: 'NOTIFY_SEVERITY_THRESHOLD'
          value: notifySeverityThreshold
        }
        {
          name: 'SCAN_CACHE_HOURS'
          value: string(scanCacheHours)
        }
        {
          name: 'SCAN_TIMEOUT'
          value: '1800'
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

resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, functionApp.id, 'AcrPull')
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Reference existing subscription-level system topic (common in production environments)
resource existingEventGridTopic 'Microsoft.EventGrid/systemTopics@2023-12-15-preview' existing = if (useExistingSystemTopic) {
  name: existingSystemTopicName
  scope: resourceGroup(existingSystemTopicResourceGroup)
}

// Create new system topic only if not using existing one
resource newEventGridTopic 'Microsoft.EventGrid/systemTopics@2023-12-15-preview' = if (!useExistingSystemTopic) {
  name: '${namePrefix}-aci-topic'
  location: 'global'
  properties: {
    source: subscription().id
    topicType: 'Microsoft.Resources.Subscriptions'
  }
}

// Use whichever topic is appropriate
var eventGridTopicName = useExistingSystemTopic ? existingEventGridTopic.name : newEventGridTopic.name

// Event Grid subscriptions (enabled after function code deployment)
resource aciEventSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2023-12-15-preview' = if (enableEventGrid) {
  name: '${eventGridTopicName}/qualys-aci-container-deployments'
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: '${functionApp.id}/functions/EventProcessor'
        maxEventsPerBatch: 1
        preferredBatchSizeInKilobytes: 64
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Resources.ResourceWriteSuccess'
      ]
    }
    eventDeliverySchema: 'EventGridSchema'
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}

resource acaEventSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2023-12-15-preview' = if (enableEventGrid) {
  name: '${eventGridTopicName}/qualys-aca-container-deployments'
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: '${functionApp.id}/functions/EventProcessor'
        maxEventsPerBatch: 1
        preferredBatchSizeInKilobytes: 64
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Resources.ResourceWriteSuccess'
      ]
    }
    eventDeliverySchema: 'EventGridSchema'
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}

output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output storageAccountName string = storageAccount.name
output keyVaultName string = keyVault.name
output appInsightsName string = appInsights.name
output functionAppPrincipalId string = functionApp.identity.principalId
output eventGridTopicName string = eventGridTopicName
output containerRegistryName string = containerRegistry.name
output containerRegistryLoginServer string = containerRegistry.properties.loginServer
