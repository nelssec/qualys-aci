using './main.bicep'

// Azure region for all resources
param location = 'eastus'

// Name prefix for resources (will be combined with unique suffix)
param namePrefix = 'qualys-scanner'

// Qualys credentials (passed securely via --parameters flag)
param qualysApiUrl = 'https://qualysapi.qualys.com'
param qualysUsername = ''  // Set via: --parameters qualysUsername=xxx
param qualysPassword = ''  // Set via: --parameters qualysPassword=xxx

// Notification settings
param notificationEmail = ''
param notifySeverityThreshold = 'HIGH'

// Scan configuration
param scanCacheHours = 24

// Function App SKU (Y1=Consumption, EP1/EP2/EP3=Premium)
param functionAppSku = 'Y1'
