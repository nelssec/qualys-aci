using './tenant-wide.bicep'

param managementGroupId = ''
param functionResourceGroup = 'qualys-scanner-rg'
param functionSubscriptionId = ''
param functionAppName = ''
param namePrefix = 'qualys-scanner'
