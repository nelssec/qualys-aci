targetScope = 'managementGroup'

param managementGroupId string
param functionResourceGroup string
param functionSubscriptionId string
param functionAppName string
param namePrefix string = 'qscan'

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
