// Event Grid subscriptions for container deployment events
// Deploy this AFTER function code is deployed to ensure endpoint validation succeeds

param functionAppName string
param eventGridTopicName string

resource functionApp 'Microsoft.Web/sites@2023-01-01' existing = {
  name: functionAppName
}

resource eventGridTopic 'Microsoft.EventGrid/systemTopics@2023-12-15-preview' existing = {
  name: eventGridTopicName
}

resource aciEventSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2023-12-15-preview' = {
  parent: eventGridTopic
  name: 'aci-container-deployments'
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
      // Temporarily removed advanced filters to debug - catch all ResourceWriteSuccess events
      // We'll filter in the function code instead
    }
    eventDeliverySchema: 'EventGridSchema'
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}

resource acaEventSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2023-12-15-preview' = {
  parent: eventGridTopic
  name: 'aca-container-deployments'
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
      // Temporarily removed advanced filters to debug - catch all ResourceWriteSuccess events
      // We'll filter in the function code instead
    }
    eventDeliverySchema: 'EventGridSchema'
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}

output aciSubscriptionName string = aciEventSubscription.name
output acaSubscriptionName string = acaEventSubscription.name
