targetScope = 'subscription'

@description('Central subscription ID where Event Hub is deployed')
param centralSubscriptionId string

@description('Central resource group name where Event Hub is deployed')
param centralResourceGroupName string

@description('Event Hub namespace name in central subscription')
param eventHubNamespace string

@description('Event Hub name for Activity Log')
param eventHubName string = 'activity-log'

@secure()
@description('Event Hub connection string with Send permission from central subscription')
param eventHubSendConnectionString string

@description('Function app managed identity principal ID from central subscription')
param functionAppPrincipalId string

// Grant Reader role to central function app for reading container metadata in this subscription
resource readerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, centralSubscriptionId, 'Reader')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Grant AcrPull role to central function app for scanning ACR images in this subscription
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, centralSubscriptionId, 'AcrPull')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Configure Activity Log to send to central Event Hub
resource activityLogDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'activity-log-to-central-eventhub'
  scope: subscription()
  properties: {
    eventHubAuthorizationRuleId: '/subscriptions/${centralSubscriptionId}/resourceGroups/${centralResourceGroupName}/providers/Microsoft.EventHub/namespaces/${eventHubNamespace}/authorizationRules/RootManageSharedAccessKey'
    eventHubName: eventHubName
    logs: [
      {
        category: 'Administrative'
        enabled: true
      }
      {
        category: 'Security'
        enabled: false
      }
      {
        category: 'ServiceHealth'
        enabled: false
      }
      {
        category: 'Alert'
        enabled: false
      }
      {
        category: 'Recommendation'
        enabled: false
      }
      {
        category: 'Policy'
        enabled: false
      }
      {
        category: 'Autoscale'
        enabled: false
      }
      {
        category: 'ResourceHealth'
        enabled: false
      }
    ]
  }
}

output subscriptionId string = subscription().subscriptionId
output diagnosticSettingName string = activityLogDiagnostics.name
