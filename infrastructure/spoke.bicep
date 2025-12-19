targetScope = 'subscription'

param centralSubscriptionId string
param centralResourceGroupName string
param eventHubNamespace string
param eventHubName string = 'activity-log'
@secure()
param eventHubSendConnectionString string
param functionAppPrincipalId string

resource containerReaderRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, 'qualys-container-reader')
  properties: {
    roleName: 'Qualys Container Reader'
    description: 'Read-only access to ACI container groups and ACA container apps for vulnerability scanning'
    type: 'CustomRole'
    assignableScopes: [subscription().id]
    permissions: [
      {
        actions: [
          'Microsoft.ContainerInstance/containerGroups/read'
          'Microsoft.App/containerApps/read'
          'Microsoft.Resources/subscriptions/resourceGroups/read'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

resource containerReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, centralSubscriptionId, 'QualysContainerReader')
  properties: {
    roleDefinitionId: containerReaderRole.id
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
