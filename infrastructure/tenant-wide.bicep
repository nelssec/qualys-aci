// Tenant-wide deployment using Management Group scope
// Deploy this at the tenant root management group to monitor ALL subscriptions

targetScope = 'managementGroup'

@description('Management Group ID to monitor (use tenant root for entire tenant)')
param managementGroupId string

@description('Resource Group where Function App is deployed')
param functionResourceGroup string

@description('Subscription ID where Function App is deployed')
param functionSubscriptionId string

@description('Function App name')
param functionAppName string

@description('Name prefix for event subscriptions')
param namePrefix string = 'qualys-scanner'

// Create Event Grid subscription at Management Group scope for ACI
resource aciEventSubscription 'Microsoft.EventGrid/eventSubscriptions@2023-12-15-preview' = {
  name: '${namePrefix}-aci-tenant-wide'
  scope: managementGroup()
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: '/subscriptions/${functionSubscriptionId}/resourceGroups/${functionResourceGroup}/providers/Microsoft.Web/sites/${functionAppName}/functions/EventProcessor'
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

// Create Event Grid subscription at Management Group scope for ACA
resource acaEventSubscription 'Microsoft.EventGrid/eventSubscriptions@2023-12-15-preview' = {
  name: '${namePrefix}-aca-tenant-wide'
  scope: managementGroup()
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: '/subscriptions/${functionSubscriptionId}/resourceGroups/${functionResourceGroup}/providers/Microsoft.Web/sites/${functionAppName}/functions/EventProcessor'
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

output aciEventSubscriptionName string = aciEventSubscription.name
output acaEventSubscriptionName string = acaEventSubscription.name
