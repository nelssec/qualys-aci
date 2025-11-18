using './deploy.bicep'

// Azure configuration
param location = 'eastus'
param namePrefix = 'qscan'
param functionAppSku = 'Y1'  // Y1=Consumption, EP1=ElasticPremium, P1v3=Premium

// Qualys configuration
param qualysPod = 'US2'  // US2, US3, EU1, etc.

// Notification configuration (optional)
param notificationEmail = ''
param notifySeverityThreshold = 'HIGH'  // CRITICAL or HIGH

// Scan caching (hours)
param scanCacheHours = 24

// Event Grid subscriptions
// Set to false for initial deployment, true after function code is deployed
param deployEventGridSubscriptions = false
