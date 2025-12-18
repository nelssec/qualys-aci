targetScope = 'subscription'

param centralSubscriptionId string
param centralResourceGroupName string
param eventHubNamespace string
param eventHubName string = 'activity-log'
@secure()
param eventHubSendConnectionString string
param functionAppPrincipalId string

resource readerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, centralSubscriptionId, 'Reader')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource activityLogDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'activity-log-to-central-eventhub'
  scope: subscription()
  properties: {
    eventHubAuthorizationRuleId: '/subscriptions/${centralSubscriptionId}/resourceGroups/${centralResourceGroupName}/providers/Microsoft.EventHub/namespaces/${eventHubNamespace}/authorizationRules/RootManageSharedAccessKey'
    eventHubName: eventHubName
    logs: [
      { category: 'Administrative', enabled: true }
      { category: 'Security', enabled: false }
      { category: 'ServiceHealth', enabled: false }
      { category: 'Alert', enabled: false }
      { category: 'Recommendation', enabled: false }
      { category: 'Policy', enabled: false }
      { category: 'Autoscale', enabled: false }
      { category: 'ResourceHealth', enabled: false }
    ]
  }
}

output subscriptionId string = subscription().subscriptionId
output diagnosticSettingName string = activityLogDiagnostics.name
