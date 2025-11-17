using './tenant-wide.bicep'

// Management Group ID to monitor (use tenant root for entire tenant)
param managementGroupId = ''  // Set to your tenant root MG ID

// Resource Group where Function App is deployed
param functionResourceGroup = 'qualys-scanner-rg'

// Subscription ID where Function App is deployed
param functionSubscriptionId = ''  // Set to your central subscription ID

// Function App name (from main deployment output)
param functionAppName = ''  // Set to your function app name

// Name prefix for event subscriptions
param namePrefix = 'qualys-scanner'
