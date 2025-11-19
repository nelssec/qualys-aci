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

resource aciEventSubscription 'Microsoft.EventGrid/eventSubscriptions@2022-06-15' = if (enableEventGrid) {
  name: 'qualys-aci-container-deployments'
  scope: subscription()
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: '${resources.outputs.functionAppId}/functions/EventProcessor'
        maxEventsPerBatch: 1
        preferredBatchSizeInKilobytes: 64
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Resources.ResourceWriteSuccess'
      ]
      advancedFilters: [
        {
          operatorType: 'StringContains'
          key: 'data.resourceProvider'
          values: [
            'Microsoft.ContainerInstance'
          ]
        }
        {
          operatorType: 'StringContains'
          key: 'data.operationName'
          values: [
            'Microsoft.ContainerInstance/containerGroups/write'
          ]
        }
      ]
    }
    eventDeliverySchema: 'EventGridSchema'
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}

resource acaEventSubscription 'Microsoft.EventGrid/eventSubscriptions@2022-06-15' = if (enableEventGrid) {
  name: 'qualys-aca-container-deployments'
  scope: subscription()
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: '${resources.outputs.functionAppId}/functions/EventProcessor'
        maxEventsPerBatch: 1
        preferredBatchSizeInKilobytes: 64
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Resources.ResourceWriteSuccess'
      ]
      advancedFilters: [
        {
          operatorType: 'StringContains'
          key: 'data.resourceProvider'
          values: [
            'Microsoft.App'
          ]
        }
        {
          operatorType: 'StringContains'
          key: 'data.operationName'
          values: [
            'Microsoft.App/containerApps/write'
          ]
        }
      ]
    }
    eventDeliverySchema: 'EventGridSchema'
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}

output functionAppName string = resources.outputs.functionAppName
output functionAppUrl string = resources.outputs.functionAppUrl
output storageAccountName string = resources.outputs.storageAccountName
output keyVaultName string = resources.outputs.keyVaultName
output appInsightsName string = resources.outputs.appInsightsName
output functionAppPrincipalId string = resources.outputs.functionAppPrincipalId
output resourceGroupName string = rg.name
