// Bicep template for deploying qscanner as a container instance
// This provides a dedicated qscanner instance for scanning container images

@description('Location for all resources')
param location string = resourceGroup().location

@description('Name for the qscanner container instance')
param qscannerName string = 'qscanner-instance'

@description('Qualys credentials for qscanner')
@secure()
param qualysUsername string

@secure()
param qualysPassword string

@description('Container image for qscanner')
param qscannerImage string = 'qualys/qscanner:latest'

@description('CPU cores for qscanner container')
param cpuCores int = 2

@description('Memory in GB for qscanner container')
param memoryInGb int = 4

@description('Enable Docker socket mounting for local image scanning')
param enableDockerSocket bool = false

@description('Virtual Network ID for VNet integration')
param vnetId string = ''

@description('Subnet name for container instance')
param subnetName string = ''

// Container instance for qscanner
resource qscannerContainer 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: qscannerName
  location: location
  properties: {
    containers: [
      {
        name: 'qscanner'
        properties: {
          image: qscannerImage
          resources: {
            requests: {
              cpu: cpuCores
              memoryInGB: memoryInGb
            }
          }
          environmentVariables: [
            {
              name: 'QUALYS_USERNAME'
              secureValue: qualysUsername
            }
            {
              name: 'QUALYS_PASSWORD'
              secureValue: qualysPassword
            }
          ]
          // Keep container running for on-demand scanning
          command: [
            '/bin/sh'
            '-c'
            'while true; do sleep 3600; done'
          ]
        }
      }
    ]
    osType: 'Linux'
    restartPolicy: 'Always'
    ipAddress: empty(vnetId) ? {
      type: 'Private'
      ports: []
    } : null
    subnetIds: !empty(vnetId) ? [
      {
        id: '${vnetId}/subnets/${subnetName}'
      }
    ] : null
  }
}

output qscannerName string = qscannerContainer.name
output qscannerIp string = empty(vnetId) ? qscannerContainer.properties.ipAddress.ip : 'VNet integrated'
