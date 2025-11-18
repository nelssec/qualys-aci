using './main.bicep'

param location = 'eastus'
param namePrefix = 'qualys-scanner'
param qualysPod = 'US2'
param qualysAccessToken = ''
param notificationEmail = ''
param notifySeverityThreshold = 'HIGH'
param scanCacheHours = 24
param functionAppSku = 'P1v4'
