# Qualys Container Scanner for Azure ACI/ACA

Event-driven container image scanning for Azure Container Instances and Azure Container Apps using Qualys qscanner.

## Quick Start

```bash
export QUALYS_TOKEN="your-qualys-token"
./deploy.sh
```

See [DEPLOYMENT.md](DEPLOYMENT.md) for details and [AUTOMATION.md](AUTOMATION.md) for how the automation works.

## Overview

This solution automatically scans container images when they're deployed to ACI or ACA. When a deployment event occurs, an Azure Function spins up a temporary container running qscanner, performs the scan, and stores the results. The scan container is deleted after completion.

### Architecture

```
Container Deployment → Event Grid → Azure Function → ACI (qscanner) → Scan → Store Results
```

Event Grid captures ACI/ACA deployment events and triggers an Azure Function. The function creates an Azure Container Instance running the official qualys/qscanner Docker image, which scans the deployed container image. Results are stored in Azure Storage and the scan container is deleted.

### Components

- Event Grid system topic monitoring resource group events
- Azure Function with Event Grid trigger
- On-demand ACI containers running qualys/qscanner
- Azure Storage for scan results (Blob + Table)
- Key Vault for Qualys credentials
- Application Insights for monitoring
- Azure Container Registry (qscanner image mirror)

## Prerequisites

- Azure CLI 2.50.0+
- Azure Functions Core Tools 4.x
- Azure subscription with Contributor role
- Qualys subscription with Container Security
- Python 3.11 (for local development)
- For tenant-wide: Management Group permissions

Register required resource providers:

```bash
az provider register --namespace Microsoft.ContainerInstance
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.EventGrid
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.KeyVault
az provider register --namespace Microsoft.Web
az provider register --namespace Microsoft.ContainerRegistry
```

### Quota Requirements

Default deployment uses Y1 (Consumption) plan which requires "Y1 VMs" quota:

```bash
az vm list-usage --location eastus --query "[?name.value=='Y1'].{Current:currentValue,Limit:limit}"
```

If quota is 0, request increase via Azure Portal or use different SKU (EP1, P1v3) in `infrastructure/deploy.bicepparam`.

## Deployment

### Single Subscription

Configure via environment variables (optional, defaults shown):

```bash
export RESOURCE_GROUP='qualys-scanner-rg'
export LOCATION='eastus'
export QUALYS_POD='US2'
export FUNCTION_SKU='EP1'  # Y1, EP1, P1v3, etc.
export NOTIFICATION_EMAIL='security@example.com'  # Optional
export SCAN_CACHE_HOURS='24'  # Optional
```

Deploy:

```bash
export QUALYS_TOKEN='your-token'
./deploy.sh
```

Minimal deployment (uses defaults):

```bash
export QUALYS_TOKEN='your-token'
./deploy.sh
```

This orchestrates: infrastructure deployment, function code deployment, Event Grid subscriptions.

### Tenant-Wide Monitoring

Monitor all subscriptions in your tenant:

```bash
# Step 1: Deploy to single subscription first
export QUALYS_TOKEN='your-token'
./deploy.sh

# Step 2: Add tenant-wide Event Grid subscriptions
az deployment mg create \
  --management-group-id $(az account management-group list --query "[?displayName=='Tenant Root Group'].name" -o tsv) \
  --location eastus \
  --template-file infrastructure/tenant-wide.bicep \
  --parameters infrastructure/tenant-wide.bicepparam
```

See [TENANT_WIDE.md](TENANT_WIDE.md) for details.

### Manual Deployment

For CI/CD pipelines or manual control:

```bash
# Deploy infrastructure
az group create --name qualys-scanner-rg --location eastus
az deployment group create \
  --resource-group qualys-scanner-rg \
  --template-file infrastructure/main.bicep \
  --parameters @infrastructure/main.bicepparam \
  --parameters qualysAccessToken='your-token'

# Deploy function code
cd function_app
func azure functionapp publish $(az functionapp list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) --python --build remote
cd ..

# Deploy Event Grid subscriptions
az deployment group create \
  --resource-group qualys-scanner-rg \
  --template-file infrastructure/eventgrid.bicep \
  --parameters functionAppName=$(az functionapp list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) \
  --parameters eventGridTopicName=$(az eventgrid system-topic list --resource-group qualys-scanner-rg --query "[0].name" -o tsv)
```

## Configuration

Environment variables configured in Function App:

| Variable | Description | Example |
|----------|-------------|---------|
| `QUALYS_POD` | Qualys platform pod | `US2`, `US3`, `EU1` |
| `QUALYS_ACCESS_TOKEN` | Qualys API token (from Key Vault) | `@Microsoft.KeyVault(...)` |
| `AZURE_SUBSCRIPTION_ID` | Subscription for scan containers | Auto-set |
| `QSCANNER_RESOURCE_GROUP` | Resource group for scan containers | `qualys-scanner-rg` |
| `QSCANNER_IMAGE` | qscanner container image | `{acr}.azurecr.io/qualys/qscanner:latest` |
| `SCAN_TIMEOUT` | Scan timeout (seconds) | `1800` |
| `SCAN_CACHE_HOURS` | Cache duration | `24` |
| `NOTIFY_SEVERITY_THRESHOLD` | Alert threshold | `HIGH`, `CRITICAL` |
| `NOTIFICATION_EMAIL` | Alert email | Optional |

## How It Works

### Scan Process

1. User deploys container to ACI or ACA
2. Azure Resource Manager emits deployment event
3. Event Grid routes event to Function App
4. Function extracts container image details
5. Function creates ACI container with qscanner
6. qscanner pulls and scans the image
7. Results uploaded to Qualys and Azure Storage
8. qscanner container deleted
9. Function stores scan metadata
10. Alerts sent if high-severity findings

### Scan Caching

Images are cached by full name (registry/repository:tag) for `SCAN_CACHE_HOURS`. Cache metadata stored in Azure Table Storage.

To force rescan:

```bash
az storage entity delete \
  --account-name $(az storage account list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) \
  --table-name ScanMetadata \
  --partition-key "scan" \
  --row-key "<image-name>"
```

## Viewing Results

### Qualys Dashboard

1. Log in to Qualys portal
2. Navigate to Container Security
3. Filter by tags: `azure_subscription`, `resource_group`, `container_type`

Scans appear 2-5 minutes after upload.

### Azure Storage

```bash
# Quick view with helper script
./view-scan-results.sh

# Manual query
RG="qualys-scanner-rg"
STORAGE=$(az storage account list --resource-group $RG --query "[0].name" -o tsv)

az storage blob list \
  --account-name $STORAGE \
  --container-name scan-results \
  --query "[].{Name:name, LastModified:properties.lastModified}" \
  --output table
```

### Application Insights

```bash
# Quick view with helper script
./view-logs.sh

# Manual query
RG="qualys-scanner-rg"
APP_INSIGHTS_ID=$(az monitor app-insights component list --resource-group $RG --query "[0].appId" -o tsv)

az monitor app-insights query \
  --app "$APP_INSIGHTS_ID" \
  --analytics-query "traces
    | where timestamp > ago(1h)
    | where operation_Name == 'EventProcessor'
    | project timestamp, severityLevel, message
    | order by timestamp desc" \
  --output table
```

## Testing

Verify deployment status:

```bash
./verify-deployment.sh
```

Test with a fresh image (will trigger actual scan):

```bash
./test-fresh-scan.sh
```

Test with cached image (will skip scan if recently scanned):

```bash
./test-automation.sh
```

Note: Images are cached for 24 hours by default. If you see "Image was recently scanned, skipping" in logs, this is expected behavior. Use `./test-fresh-scan.sh` to test with an image that hasn't been scanned yet.

Manual qscanner test:

```bash
export QUALYS_TOKEN='your-token'
./test-qscanner-manual.sh
```

## Troubleshooting

Quick diagnostics:

```bash
./view-logs.sh          # View Application Insights logs
./view-scan-results.sh  # View scan results from Azure Storage
```

For comprehensive troubleshooting, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

Common issues:

**Scans not triggering**: Check Event Grid subscriptions are active
**Scans failing**: Verify Qualys token is valid and not expired
**Results not in Qualys**: Check POD setting and token permissions

## Updating

Update function code only:

```bash
./update.sh
```

Update Qualys token (requires Key Vault Secrets Officer role):

```bash
export QUALYS_TOKEN='your-new-token'
./update-token.sh
```

If you don't have Key Vault permissions, update via:
- Azure Portal: Key Vault > Secrets > QualysAccessToken > New Version
- Redeploy: `export QUALYS_TOKEN='...' && ./deploy.sh`

## Cost Optimization

- Serverless Function App: Only runs on container deployments
- On-demand ACI: Created per scan, deleted after completion
- Scan caching: Avoids duplicate scans
- Basic SKU ACR: Minimal cost for qscanner image mirror

Typical monthly costs:
- Function App (Consumption): $1-5
- Storage: $1-2
- ACI (per scan): $0.01-0.05
- Event Grid: Free (first 100k operations)
- ACR (Basic): $5

## Security

- Qualys token in Key Vault (secure storage)
- Function App uses managed identity
- RBAC: Minimal required permissions
- Secure environment variables for containers
- No public access to storage or Key Vault

## Files

- `deploy.sh` - Main deployment script
- `infrastructure/deploy.bicep` - Orchestration Bicep template
- `infrastructure/main.bicep` - Core infrastructure
- `infrastructure/eventgrid.bicep` - Event Grid subscriptions
- `function_app/` - Azure Function code
- `test-automation.sh` - Debug: Test automation
- `test-qscanner-manual.sh` - Debug: Manual qscanner test
- `setup-automation.sh` - Debug: Update token and verify config

## Documentation

- [DEPLOYMENT.md](DEPLOYMENT.md) - Detailed deployment guide
- [AUTOMATION.md](AUTOMATION.md) - How automation works
- [TENANT_WIDE.md](TENANT_WIDE.md) - Tenant-wide deployment

## License

MIT
