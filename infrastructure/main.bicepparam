using './main.bicep'

param location = 'eastus'
param qualysPod = 'US2'
param qualysAccessToken = ''
param notificationEmail = ''
param notifySeverityThreshold = 'HIGH'
param scanCacheHours = 24
param functionAppSku = 'Y1'
