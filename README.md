# Qualys Container Scanner for Azure

Automated vulnerability scanning for Azure Container Instances (ACI) and Azure Container Apps (ACA) using Qualys qscanner.

## Overview

This solution automatically scans all container images deployed across your Azure subscription using Event Grid triggers and Qualys qscanner. Scan results are uploaded to Qualys Cloud Platform and stored locally in Azure Storage.

## Architecture

```
Container Deployment → Event Grid → Azure Function → ACI (qscanner) → Scan → Qualys + Azure Storage
```

**Components:**
- **Event Grid**: Monitors container deployments across entire subscription
- **Azure Function**: Processes events and orchestrates scans
- **Azure Container Instances**: Runs qscanner in temporary containers
- **Azure Container Registry**: Hosts qscanner image
- **Azure Storage**: Stores scan results and metadata
- **Azure Key Vault**: Securely stores Qualys credentials
- **Scan Caching**: 24-hour cache prevents duplicate scans

**Monitoring Scope:**
- Scans ALL container deployments across the subscription
- Works across all resource groups
- Supports both ACI and ACA containers
- Automatic detection of new containers via Event Grid

## Prerequisites

- Azure CLI 2.50.0 or higher
- Azure subscription with Contributor role
- Qualys subscription with Container Security
- Qualys Access Token (from Qualys Cloud Platform)
- Azure Functions Core Tools 4.x

## Quick Start

### 1. Set Environment Variables

```bash
export RESOURCE_GROUP="qualys-scanner-rg"
export LOCATION="eastus"
export QUALYS_POD="US2"  # Your Qualys POD (US1, US2, US3, EU1, etc.)
export QUALYS_ACCESS_TOKEN="your-qualys-access-token"
```

### 2. Deploy

```bash
./deploy.sh
```

This deploys everything at subscription scope:
- Creates resource group
- Deploys all infrastructure with subscription-level permissions
- Deploys function code
- Configures Event Grid subscriptions

Deployment takes 5-10 minutes.

**Alternative: Pure Bicep Deployment (no script needed)**

```bash
az deployment sub create \
  --location eastus \
  --template-file infrastructure/main.bicep \
  --parameters location=eastus \
  --parameters resourceGroupName=qualys-scanner-rg \
  --parameters qualysPod=US2 \
  --parameters qualysAccessToken="your-token"
```

Then deploy function code: `cd function_app && func azure functionapp publish <function-app-name>`

### 3. Verify

```bash
# Check function app status
az functionapp show \
  --resource-group $RESOURCE_GROUP \
  --name $(az functionapp list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv) \
  --query "{Name:name,State:state,Runtime:siteConfig.linuxFxVersion}"

# Verify Event Grid subscriptions
az eventgrid system-topic event-subscription list \
  --resource-group $RESOURCE_GROUP \
  --system-topic-name $(az eventgrid system-topic list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv) \
  -o table
```

Expected: 2 active subscriptions (aci-container-deployments, aca-container-deployments)

### 4. Test Scanning

Deploy a test container to trigger automatic scanning:

```bash
az container create \
  --resource-group qualys-scanner-rg \
  --name test-scan \
  --image mcr.microsoft.com/dotnet/runtime:8.0 \
  --os-type Linux \
  --restart-policy Never
```

Check results in Qualys Dashboard (Container Security) or Application Insights (EventProcessor logs).

## How It Works

1. Container deployed to ACI or ACA anywhere in subscription
2. Event Grid captures deployment event (subscription-wide monitoring)
3. EventProcessor function triggered
4. Function checks scan cache (24-hour window)
5. If not cached, creates temporary ACI container with qscanner
6. qscanner pulls and scans the image
7. Results uploaded to Qualys Cloud Platform with Azure metadata
8. Results stored in Azure Storage
9. qscanner container deleted
10. Scan metadata cached

**Scan Duration**: 2-5 minutes for typical images
**Scope**: ALL resource groups in the subscription

## Viewing Results

### Qualys Dashboard

1. Login to Qualys Cloud Platform (your POD URL)
2. Navigate to Container Security
3. Filter by tags: `azure_subscription`, `resource_group`, `container_type`

Results appear 2-5 minutes after scan completion.

### Azure Storage

```bash
RG="qualys-scanner-rg"
STORAGE=$(az storage account list --resource-group $RG --query "[0].name" -o tsv)
STORAGE_KEY=$(az storage account keys list --resource-group $RG --account-name $STORAGE --query "[0].value" -o tsv)

# List scan results
az storage blob list \
  --account-name $STORAGE \
  --account-key "$STORAGE_KEY" \
  --container-name scan-results \
  --query "[].{Name:name,LastModified:properties.lastModified}" \
  -o table

# Download specific result
az storage blob download \
  --account-name $STORAGE \
  --account-key "$STORAGE_KEY" \
  --container-name scan-results \
  --name "path/to/result.json" \
  --file result.json
```

### Application Insights

```bash
APP_INSIGHTS_ID=$(az monitor app-insights component list --resource-group $RG --query "[0].appId" -o tsv)

# View recent scans
az monitor app-insights query \
  --app "$APP_INSIGHTS_ID" \
  --analytics-query "traces
    | where timestamp > ago(1h)
    | where operation_Name == 'EventProcessor'
    | project timestamp, message
    | order by timestamp desc"
```

## Configuration

Environment variables in Function App:

| Variable | Description | Default |
|----------|-------------|---------|
| `QUALYS_POD` | Qualys platform pod | From deployment |
| `QUALYS_ACCESS_TOKEN` | From Key Vault | From deployment |
| `QSCANNER_IMAGE` | qscanner container image | `{acr}.azurecr.io/qualys/qscanner:latest` |
| `SCAN_CACHE_HOURS` | Cache duration | `24` |
| `SCAN_TIMEOUT` | Scan timeout (seconds) | `1800` |

## Updating

### Update Function Code

```bash
./update.sh
```

### Update Qualys Token

```bash
export QUALYS_ACCESS_TOKEN='your-new-token'
./update-token.sh
```

**If you don't have Key Vault permissions:**
- Azure Portal: Key Vault → Secrets → QualysAccessToken → New Version
- Or redeploy: `export QUALYS_ACCESS_TOKEN='...' && ./deploy.sh`

## Scan Caching

Images are cached by full name (registry/repository:tag) for 24 hours to prevent duplicate scans and reduce costs.

**To force rescan:**
- Wait 24 hours for cache to expire
- Deploy with different tag: `image:v2` instead of `image:v1`
- Deploy with specific digest: `image@sha256:...`
- Update `SCAN_CACHE_HOURS` environment variable in Function App

## Troubleshooting

### Scans Not Triggering

Check Event Grid subscriptions:

```bash
az eventgrid system-topic event-subscription list \
  --resource-group qualys-scanner-rg \
  --system-topic-name $(az eventgrid system-topic list --resource-group qualys-scanner-rg --query "[0].name" -o tsv)
```

Expected: 2 subscriptions with `ProvisioningState: Succeeded`

Test by deploying a container:

```bash
az container create \
  --resource-group qualys-scanner-rg \
  --name test-$(date +%s) \
  --image mcr.microsoft.com/dotnet/runtime:8.0 \
  --os-type Linux \
  --restart-policy Never
```

### Results Not in Qualys

Verify token and POD:

```bash
# Check POD setting
az functionapp config appsettings list \
  --resource-group qualys-scanner-rg \
  --name $(az functionapp list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) \
  --query "[?name=='QUALYS_POD'].value" -o tsv
```

Update token:

```bash
export QUALYS_ACCESS_TOKEN='your-valid-token'
./update-token.sh
```

### Deployment Timeout

If `deploy.sh` times out during function code deployment:

1. The deployment often succeeds in the background despite the timeout
2. Wait 1-2 minutes and check function app state:
   ```bash
   az functionapp show \
     --resource-group qualys-scanner-rg \
     --name $(az functionapp list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) \
     --query "state" -o tsv
   ```
3. If state is "Running", deployment succeeded - continue with Event Grid setup:
   ```bash
   ./update.sh
   ```
4. If deployment actually failed, retry:
   ```bash
   cd function_app
   func azure functionapp publish $(az functionapp list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) --python --build remote
   cd ..
   ```

### QScanner Image Missing

Import qscanner image:

```bash
ACR_NAME=$(az acr list --resource-group qualys-scanner-rg --query "[0].name" -o tsv)
az acr import \
  --name $ACR_NAME \
  --source docker.io/qualys/qscanner:latest \
  --image qualys/qscanner:latest
```

## Deployment Scopes

**Subscription-Wide (Native Bicep):**
The Bicep template deploys at subscription scope with native subscription-level RBAC. It monitors ALL container deployments across the entire subscription in all resource groups.

To deploy to a different subscription:
```bash
az deployment sub create \
  --location eastus \
  --subscription "<subscription-id>" \
  --template-file infrastructure/main.bicep \
  --parameters qualysPod=US2 \
  --parameters qualysAccessToken="your-token"
```

**Multi-Subscription / Tenant-Wide:**
Deploy once per subscription. Each deployment monitors its subscription independently. For centralized management:
- Use Azure Lighthouse for multi-tenant scenarios
- Use Azure Policy to enforce deployment across subscriptions

## Security

- **Credentials**: Qualys token in Azure Key Vault with RBAC
- **Authentication**: Function App managed identity (no stored credentials)
- **RBAC Roles**:
  - Contributor (subscription scope) - scan containers across all resource groups
  - Key Vault Secrets User - read Qualys token
  - AcrPull - pull qscanner image
- **Network**: Azure Services only
- **Encryption**: Soft delete enabled on Key Vault
- **Principle of Least Privilege**: Function app only has read access to containers, write access limited to creating temporary scan containers in scanner resource group

## Cost

Typical monthly cost for moderate usage:

- **Function App (Consumption)**: $1-5
- **Storage (Blob + Table)**: $1-2
- **ACI (per scan)**: $0.01-0.05
- **ACR (Basic)**: $5
- **Event Grid**: Free (first 100k operations)

**Total**: ~$8-15/month

## Architecture Details

**Function App**:
- Runtime: Python 3.11
- Extension Bundle: v4
- Trigger: Event Grid
- Timeout: 30 minutes
- Retry: 3 attempts with 5s delay

**Storage**:
- Blob: `scan-results` (full scan JSON)
- Table: `ScanMetadata` (cache and metadata)

**Event Grid**:
- System Topic: Subscription-wide events
- Scope: All resource groups in subscription
- Filters: ACI and ACA deployments
- Schema: Event Grid Schema

**Container Registry**:
- SKU: Basic
- Auth: Managed identity
- Image: `qualys/qscanner:latest`

## License

See [LICENSE](LICENSE)
