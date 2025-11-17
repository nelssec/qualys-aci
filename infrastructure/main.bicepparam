using './main.bicep'

param location = 'eastus'
param namePrefix = 'qualys-scanner'
param qualysPod = ''
param qualysAccessToken = ''
param notificationEmail = ''
param notifySeverityThreshold = 'HIGH'
param scanCacheHours = 24
param functionAppSku = 'Y1'
