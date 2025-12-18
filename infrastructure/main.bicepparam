using './main.bicep'

param location = 'eastus'
param qualysGatewayUrl = 'https://gateway.qg2.apps.qualys.com'
param qualysApiToken = ''
param acrConnectorName = 'qualys-aci-connector'
param acrApplicationId = ''
param acrClientSecret = ''
param scanCacheHours = 24
param functionAppSku = 'Y1'
