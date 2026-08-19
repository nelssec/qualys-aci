using './main.bicep'

param location = 'eastus'
param qualysGatewayUrl = 'https://gateway.qg2.apps.qualys.com'
param qualysApiToken = ''
param acrApplicationId = ''
param acrClientSecret = ''
param scanCacheHours = 24
param functionAppSku = 'Y1'

// Private networking (opt-in). When true, set both subnet IDs below.
// enablePrivateNetworking forces an Elastic Premium plan and Standard messaging tier.
param enablePrivateNetworking = false
param functionSubnetId = ''         // existing subnet delegated to Microsoft.Web/serverFarms
param privateEndpointSubnetId = ''  // existing subnet for private endpoint NICs
// Optional: existing private DNS zone IDs to auto-register records, e.g.
// { blob: '<id>', file: '<id>', queue: '<id>', table: '<id>', vault: '<id>', servicebus: '<id>' }
param privateDnsZoneIds = {}
