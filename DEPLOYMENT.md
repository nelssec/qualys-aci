# Deployment Guide

## Prerequisites

- Azure CLI 2.50.0 or higher
- Azure subscription with Contributor role
- Qualys subscription with Container Security
- For tenant-wide: Management Group permissions

Register required resource providers:

```bash
az provider register --namespace Microsoft.ContainerInstance
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.EventGrid
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.KeyVault
az provider register --namespace Microsoft.Web
```

## Deployment Options

### Option 1: Single Subscription Monitoring

Deploy scanner to monitor a single subscription.

#### Step 1: Configure Parameters

Edit `infrastructure/main.bicepparam`:

```bicep
using './main.bicep'

param location = 'eastus'
param namePrefix = 'qualys-scanner'
param qualysPod = 'US2'
param notificationEmail = 'security@example.com'
param notifySeverityThreshold = 'HIGH'
param functionAppSku = 'Y1'
```

#### Step 2: Deploy

```bash
cd infrastructure

az group create \
  --name qualys-scanner-rg \
  --location eastus

az deployment group create \
  --resource-group qualys-scanner-rg \
  --template-file main.bicep \
  --parameters main.bicepparam \
  --parameters qualysAccessToken='your-access-token'
```

Credentials are passed via command line for security (not stored in parameter files).

#### Step 3: Deploy Function Code

```bash
cd ../function_app

# Get function app name from deployment
FUNCTION_APP=$(az deployment group show \
  --resource-group qualys-scanner-rg \
  --name main \
  --query properties.outputs.functionAppName.value -o tsv)

# Deploy function code
func azure functionapp publish $FUNCTION_APP
```

### Option 2: Tenant-Wide Monitoring

Deploy scanner to monitor ALL subscriptions in your tenant.

#### Step 1: Deploy Function App

First, deploy the Function App to a central subscription:

```bash
cd infrastructure

az group create \
  --name qualys-scanner-rg \
  --location eastus \
  --subscription central-subscription-id

az deployment group create \
  --resource-group qualys-scanner-rg \
  --subscription central-subscription-id \
  --template-file main.bicep \
  --parameters main.bicepparam \
  --parameters qualysAccessToken='your-access-token'
```

#### Step 2: Deploy Function Code

```bash
cd ../function_app

FUNCTION_APP=$(az deployment group show \
  --resource-group qualys-scanner-rg \
  --subscription central-subscription-id \
  --name main \
  --query properties.outputs.functionAppName.value -o tsv)

func azure functionapp publish $FUNCTION_APP
```

#### Step 3: Get Management Group ID

For entire tenant:

```bash
TENANT_ROOT=$(az account management-group list \
  --query "[?displayName=='Tenant Root Group'].name" -o tsv)

echo "Tenant Root MG: $TENANT_ROOT"
```

For specific business unit, list management groups:

```bash
az account management-group list --output table
```

#### Step 4: Configure Tenant-Wide Parameters

Edit `infrastructure/tenant-wide.bicepparam`:

```bicep
using './tenant-wide.bicep'

param managementGroupId = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'  // Your tenant root MG
param functionResourceGroup = 'qualys-scanner-rg'
param functionSubscriptionId = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'  // Central subscription
param functionAppName = 'qualys-scanner-func-abc123'  // From step 2
param namePrefix = 'qualys-scanner'
```

#### Step 5: Deploy Tenant-Wide Event Grid

```bash
az deployment mg create \
  --management-group-id $TENANT_ROOT \
  --location eastus \
  --template-file tenant-wide.bicep \
  --parameters tenant-wide.bicepparam
```

This creates Event Grid subscriptions at the Management Group level that monitor ALL subscriptions.

## Verify Deployment

### Check Function App

```bash
az functionapp show \
  --name $FUNCTION_APP \
  --resource-group qualys-scanner-rg \
  --query "{Name:name, State:state, Identity:identity.principalId}"
```

### Check Event Grid Subscriptions

For single subscription:

```bash
az eventgrid system-topic event-subscription list \
  --resource-group qualys-scanner-rg \
  --system-topic-name qualys-scanner-aci-topic
```

For tenant-wide:

```bash
az eventgrid event-subscription list \
  --source-resource-id /providers/Microsoft.Management/managementGroups/$TENANT_ROOT
```

### Test End-to-End

Deploy a test container:

```bash
az container create \
  --resource-group test-rg \
  --name test-nginx \
  --image nginx:latest \
  --cpu 1 \
  --memory 1
```

Wait 2-3 minutes, then check Application Insights:

```bash
az monitor app-insights query \
  --app $FUNCTION_APP \
  --analytics-query "traces | where timestamp > ago(30m) | where message contains 'nginx' | order by timestamp desc"
```

## Configure Private Registry Access

Grant Function App access to Azure Container Registry:

```bash
PRINCIPAL_ID=$(az functionapp identity show \
  --name $FUNCTION_APP \
  --resource-group qualys-scanner-rg \
  --query principalId -o tsv)

az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role AcrPull \
  --scope /subscriptions/xxx/resourceGroups/xxx/providers/Microsoft.ContainerRegistry/registries/xxx
```

For tenant-wide, grant access to all ACRs:

```bash
# List all ACRs across subscriptions
az graph query -q "Resources | where type == 'microsoft.containerregistry/registries' | project id" -o tsv | \
while read ACR_ID; do
  az role assignment create \
    --assignee $PRINCIPAL_ID \
    --role AcrPull \
    --scope $ACR_ID
done
```

## Update Deployment

To update the infrastructure:

```bash
az deployment group create \
  --resource-group qualys-scanner-rg \
  --template-file main.bicep \
  --parameters main.bicepparam \
  --parameters qualysAccessToken='your-access-token' \
  --mode Incremental
```

To update function code only:

```bash
cd function_app
func azure functionapp publish $FUNCTION_APP
```

## Configuration Options

### Function App SKU

Edit in `main.bicepparam`:

```bicep
// Consumption (pay per execution)
param functionAppSku = 'Y1'

// Premium (faster cold start, VNet support)
param functionAppSku = 'EP1'  // or EP2, EP3
```

### Scan Timeout

For large images, increase timeout:

```bash
az functionapp config appsettings set \
  --name $FUNCTION_APP \
  --resource-group qualys-scanner-rg \
  --settings "SCAN_TIMEOUT=3600"
```

### Notification Threshold

Edit in `main.bicepparam`:

```bicep
param notifySeverityThreshold = 'CRITICAL'  // or 'HIGH'
```

## Monitoring

### View Deployment History

```bash
az deployment group list \
  --resource-group qualys-scanner-rg \
  --query "[].{Name:name, Time:properties.timestamp, State:properties.provisioningState}" \
  --output table
```

### Check Resource Health

```bash
az resource list \
  --resource-group qualys-scanner-rg \
  --query "[].{Name:name, Type:type, Location:location}" \
  --output table
```

### View Scan Activity

Application Insights query:

```bash
az monitor app-insights query \
  --app $FUNCTION_APP \
  --analytics-query "
traces
| where customDimensions.EventType == 'ContainerScan'
| where timestamp > ago(24h)
| summarize count() by tostring(customDimensions.Image)
| order by count_ desc"
```

## Troubleshooting

### Deployment Fails with Permission Error

Ensure you have Contributor role on the subscription:

```bash
az role assignment list \
  --assignee $(az account show --query user.name -o tsv) \
  --scope /subscriptions/$(az account show --query id -o tsv) \
  --query "[?roleDefinitionName=='Contributor']"
```

### Function App Not Receiving Events

Check Event Grid delivery:

```bash
az monitor metrics list \
  --resource <event-grid-topic-id> \
  --metric DeliverySuccessCount,DeliveryFailedCount \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
```

### Scan Container Fails to Start

Check ACI quota:

```bash
az container list-usage \
  --location eastus \
  --output table
```

Request quota increase if needed via Azure Portal support ticket.

## Security Hardening

### Enable VNet Integration (Premium Plan)

```bash
az functionapp vnet-integration add \
  --name $FUNCTION_APP \
  --resource-group qualys-scanner-rg \
  --vnet <vnet-name> \
  --subnet <subnet-name>
```

### Restrict Storage Access

```bash
STORAGE_ACCOUNT=$(az deployment group show \
  --resource-group qualys-scanner-rg \
  --name main \
  --query properties.outputs.storageAccountName.value -o tsv)

az storage account network-rule add \
  --account-name $STORAGE_ACCOUNT \
  --subnet <subnet-id>

az storage account update \
  --name $STORAGE_ACCOUNT \
  --default-action Deny
```

### Enable Managed Identity for ACR

Already configured automatically. Function App uses system-assigned managed identity for all Azure resources.

## Cleanup

Remove single subscription deployment:

```bash
az group delete \
  --name qualys-scanner-rg \
  --yes --no-wait
```

Remove tenant-wide Event Grid subscriptions:

```bash
az eventgrid event-subscription delete \
  --name qualys-scanner-aci-tenant-wide \
  --source-resource-id /providers/Microsoft.Management/managementGroups/$TENANT_ROOT

az eventgrid event-subscription delete \
  --name qualys-scanner-aca-tenant-wide \
  --source-resource-id /providers/Microsoft.Management/managementGroups/$TENANT_ROOT
```

## Cost Estimation

Use Azure Pricing Calculator with these parameters:

- Function App: Consumption plan, 100 executions/day, 128 MB memory, 30 sec avg duration
- ACI: 100 containers/day, 2 GB RAM, 1 CPU, 2 min avg duration
- Storage: 10 GB blob, 1M table operations/month
- Event Grid: 100K events/month

Estimated: ~$7-10/month for 100 scans/day
