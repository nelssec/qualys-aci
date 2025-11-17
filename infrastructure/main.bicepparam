using './main.bicep'

param location = 'eastus'
param namePrefix = 'qualys-scanner'
param qualysApiUrl = 'https://qualysapi.qualys.com'
param qualysUsername = ''
param qualysPassword = ''
param notificationEmail = ''
param notifySeverityThreshold = 'HIGH'
param scanCacheHours = 24
param functionAppSku = 'Y1'
