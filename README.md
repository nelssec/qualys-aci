# Qualys Container Scanner for Azure

Automated vulnerability scanning for Azure Container Instances (ACI) and Azure Container Apps (ACA) using Qualys qscanner binary.

## Overview

This solution automatically scans all container images deployed across your Azure subscription using Event Grid and Qualys qscanner. The scanner runs directly in Azure Functions (no container orchestration needed). Scan results are uploaded to Qualys Cloud Platform and stored in Azure Storage.

## Architecture

```
Container Deployment → Event Grid → Azure Function → qscanner binary → Qualys + Azure Storage
```

**Components:**
- **Event Grid**: Subscription-wide monitoring for container deployments
- **Azure Function**: Event processor + qscanner binary runtime
- **Azure Storage**: Scan results and metadata cache
- **Azure Key Vault**: Qualys credentials (RBAC-protected)
- **qscanner binary**: Auto-downloads latest version on first use

**Key Features:**
- **No container orchestration**: qscanner runs directly in function runtime
- **Auto-updating**: Downloads latest qscanner binary automatically
- **Subscription-wide**: Monitors ALL resource groups
- **Smart caching**: 24-hour deduplication
- **Cost-effective**: No ACI/ACR costs, only function execution

## Prerequisites

- Azure CLI 2.50.0+
- Azure subscription with Contributor role
- Qualys subscription with Container Security
- Qualys Access Token ([generate here](https://qualysguard.qualys.com/cloudview-apps/#/tokens))
- Azure Functions Core Tools 4.x (for local development)

## Deployment

### Step 1: Deploy Infrastructure

```bash
az deployment sub create \
  --location eastus \
  --template-file infrastructure/main.bicep \
  --parameters location=eastus \
  --parameters resourceGroupName=qualys-scanner-rg \
  --parameters qualysPod=US2 \
  --parameters qualysAccessToken="<your-token>"
```

**Parameters:**
- `qualysPod`: Your Qualys platform (US1, US2, US3, EU1, etc.)
- `qualysAccessToken`: Qualys subscription access token
- `location`: Azure region (default: eastus)
- `resourceGroupName`: Resource group name (default: qualys-scanner-rg)

### Step 2: Deploy Function Code

```bash
FUNCTION_APP=$(az functionapp list --resource-group qualys-scanner-rg --query "[0].name" -o tsv)
cd function_app
func azure functionapp publish $FUNCTION_APP --python --build remote
cd ..
```

The qscanner binary will auto-download on first function execution.

### Step 3: Enable Event Grid Subscriptions

```bash
az deployment sub create \
  --location eastus \
  --template-file infrastructure/main.bicep \
  --parameters location=eastus \
  --parameters resourceGroupName=qualys-scanner-rg \
  --parameters qualysPod=US2 \
  --parameters qualysAccessToken="<your-token>" \
  --parameters enableEventGrid=true
```

Event Grid system topic is automatically created if it doesn't exist. Deployments are idempotent.

## Testing

Deploy a test container to trigger automatic scanning:

```bash
az container create \
  --resource-group qualys-scanner-rg \
  --name test-scan-$(date +%s) \
  --image mcr.microsoft.com/dotnet/runtime:8.0 \
  --os-type Linux \
  --restart-policy Never
```

Monitor execution:
```bash
# Function logs
func azure functionapp logstream $FUNCTION_APP

# Or Application Insights
az monitor app-insights query \
  --app $(az monitor app-insights component list --resource-group qualys-scanner-rg --query "[0].appId" -o tsv) \
  --analytics-query "traces | where timestamp > ago(30m) | where operation_Name == 'EventProcessor' | project timestamp, message | order by timestamp desc" \
  --offset 1h
```

## How It Works

1. Container deployed to ACI/ACA anywhere in subscription
2. Event Grid captures deployment event
3. `EventProcessor` function triggered
4. Function checks 24-hour scan cache
5. If not cached, qscanner binary executes (auto-downloads if missing)
6. qscanner pulls and scans container image
7. Results uploaded to Qualys Cloud Platform with Azure tags
8. Results stored in Azure Storage
9. Scan metadata cached

**Scan Duration**: 2-5 minutes per image
**Scope**: Entire subscription, all resource groups

## Viewing Results

### Qualys Dashboard

1. Login to Qualys Cloud Platform (e.g., https://qualysguard.qg2.apps.qualys.com/)
2. Navigate to **Container Security** → **Images**
3. Filter by custom tags:
   - `azure_subscription`
   - `resource_group`
   - `container_type`

Results appear 2-5 minutes after scan completion.

### Azure Storage

```bash
RG="qualys-scanner-rg"
STORAGE=$(az storage account list --resource-group $RG --query "[0].name" -o tsv)

# List recent scans
az storage blob list \
  --account-name $STORAGE \
  --auth-mode login \
  --container-name scan-results \
  --query "[].{Name:name,Modified:properties.lastModified}" \
  -o table

# Download scan result
az storage blob download \
  --account-name $STORAGE \
  --auth-mode login \
  --container-name scan-results \
  --name "2024/01/15/scan-12345.json" \
  --file scan-result.json
```

## Configuration

| Environment Variable | Description | Default |
|---------------------|-------------|---------|
| `QUALYS_POD` | Qualys platform pod | From deployment |
| `QUALYS_ACCESS_TOKEN` | Qualys token (from Key Vault) | From deployment |
| `QSCANNER_VERSION` | qscanner version to download | `4.6.0` |
| `SCAN_CACHE_HOURS` | Cache duration before rescanning | `24` |
| `SCAN_TIMEOUT` | Scan timeout (seconds) | `1800` |
| `NOTIFY_SEVERITY_THRESHOLD` | Alert threshold (CRITICAL/HIGH) | `HIGH` |
| `NOTIFICATION_EMAIL` | Email for alerts (optional) | - |

Update via Azure Portal: Function App → Configuration → Application Settings

## Updating

### Update Function Code

```bash
FUNCTION_APP=$(az functionapp list --resource-group qualys-scanner-rg --query "[0].name" -o tsv)
cd function_app
func azure functionapp publish $FUNCTION_APP --python --build remote
```

### Update qscanner Version

```bash
# Set new version
az functionapp config appsettings set \
  --resource-group qualys-scanner-rg \
  --name $FUNCTION_APP \
  --settings QSCANNER_VERSION=4.7.0

# Restart function app to download new binary
az functionapp restart --resource-group qualys-scanner-rg --name $FUNCTION_APP
```

### Update Qualys Token

```bash
# Via infrastructure redeployment (preferred)
az deployment sub create \
  --location eastus \
  --template-file infrastructure/main.bicep \
  --parameters qualysPod=US2 \
  --parameters qualysAccessToken="<new-token>" \
  --parameters enableEventGrid=true

# Or via Key Vault
az keyvault secret set \
  --vault-name $(az keyvault list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) \
  --name QualysAccessToken \
  --value "<new-token>"
```

## Troubleshooting

### Scans Not Triggering

Check Event Grid subscriptions:
```bash
az eventgrid system-topic event-subscription list \
  --resource-group qualys-scanner-rg \
  --system-topic-name $(az eventgrid system-topic list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) \
  --query "[].{Name:name,State:provisioningState}" -o table
```

Expected: 2 subscriptions with `Succeeded` state.

### qscanner Binary Download Failures

Check function logs:
```bash
func azure functionapp logstream $FUNCTION_APP
```

Common issues:
- **Network connectivity**: Function can't reach `cdn.qualys.com`
- **Invalid version**: Check `QSCANNER_VERSION` environment variable
- **Permissions**: `/home` directory not writable (unlikely in Azure Functions)

Manual download verification:
```bash
# Test download locally
curl -sSL https://cdn.qualys.com/qscanner/4.6.0/qscanner_4.6.0_linux_amd64 -o qscanner
chmod +x qscanner
./qscanner version
```

### Results Not in Qualys

Verify credentials:
```bash
# Check POD configuration
az functionapp config appsettings list \
  --resource-group qualys-scanner-rg \
  --name $FUNCTION_APP \
  --query "[?name=='QUALYS_POD'].value" -o tsv

# Test token manually
curl -H "Authorization: Bearer <your-token>" \
  https://gateway.qg2.apps.qualys.com/csapi/v1.3/images
```

### Force Rescan

```bash
# Option 1: Clear cache (requires Storage Blob Data Contributor role)
az storage blob delete-batch \
  --account-name $(az storage account list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) \
  --auth-mode login \
  --source scan-results

# Option 2: Deploy with new tag
az container create \
  --resource-group qualys-scanner-rg \
  --name test-scan \
  --image mcr.microsoft.com/dotnet/runtime:8.0-$(date +%s) \
  --restart-policy Never
```

## Security

### Authentication & Authorization
- **Function Identity**: System-assigned managed identity
- **Key Vault Access**: RBAC (Key Vault Secrets User)
- **Subscription Access**: Contributor role (read container metadata)
- **Storage Access**: Built-in connection string (future: migrate to managed identity)

### RBAC Roles Required
| Resource | Role | Scope | Purpose |
|----------|------|-------|---------|
| Subscription | Contributor | Subscription | Read container metadata, manage ACI |
| Key Vault | Key Vault Secrets User | Key Vault | Read Qualys token |
| Storage | Storage Blob Data Contributor | Storage Account | Write scan results |

### Network Security
- **Key Vault**: Public access (limited to Azure services)
- **Storage**: Public access (limited to Azure services)
- **Function**: Outbound to Qualys API (`*.qualys.com`) and CDN (`cdn.qualys.com`)

### Data Protection
- **Secrets**: Stored in Key Vault with soft delete (90 days)
- **Scan Results**: Encrypted at rest (Azure Storage default)
- **Token Rotation**: Redeploy infrastructure with new token

## Cost Optimization

Monthly cost estimate (moderate usage, ~100 scans/month):

| Service | SKU | Cost |
|---------|-----|------|
| Azure Functions | Consumption (Linux) | $1-5 |
| Storage Account | Standard LRS | $1-2 |
| Key Vault | Standard | Free |
| Event Grid | System Topics | Free (first 100k ops) |
| Application Insights | Pay-as-you-go | $0-2 |
| **Total** | | **$2-9/month** |

**No ACI or ACR costs** (binary runs in function runtime)

## Technical Details

### Function Runtime
- **Python Version**: 3.11
- **Programming Model**: v2 (decorator-based)
- **Extension Bundle**: 4.x
- **Timeout**: 30 minutes
- **Retry Policy**: 3 attempts, 5s fixed delay

### Storage Schema
- **Blob Container**: `scan-results` - Full scan JSON by date
- **Table**: `ScanMetadata` - Cache and lookup table

### Event Grid
- **Topic Type**: `Microsoft.Resources.Subscriptions`
- **Event Types**:
  - `Microsoft.Resources.ResourceWriteSuccess`
  - `Microsoft.Resources.ResourceDeleteSuccess`
- **Filters**:
  - `Microsoft.ContainerInstance/containerGroups`
  - `Microsoft.App/containerApps`

### qscanner Binary
- **Source**: `https://cdn.qualys.com/qscanner/<version>/qscanner_<version>_linux_amd64`
- **Storage**: `/home/qscanner` (persistent across warm starts)
- **Auto-update**: Downloads latest on first execution if missing
- **Scan Types**: OS packages, SCA (Software Composition Analysis), secrets

## Advanced Configuration

### Custom Scan Tags

Edit `function_app/function_app.py`:
```python
custom_tags = {
    'container_type': container_type,
    'azure_subscription': event_subscription_id,
    'resource_group': resource_group,
    'environment': 'production',  # Add custom tag
    'team': 'platform'            # Add custom tag
}
```

### Multi-Subscription Deployment

Deploy once per subscription:
```bash
for SUB in sub1 sub2 sub3; do
  az deployment sub create \
    --subscription $SUB \
    --location eastus \
    --template-file infrastructure/main.bicep \
    --parameters qualysPod=US2 qualysAccessToken="<token>"
done
```

For centralized management, use [Azure Lighthouse](https://azure.microsoft.com/en-us/services/azure-lighthouse/).

## Development

### Local Testing

```bash
cd function_app
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\Scripts\activate
pip install -r requirements.txt

# Copy settings
cp local.settings.json.sample local.settings.json
# Edit local.settings.json with your credentials

# Run locally
func start
```

### Project Structure

```
qualys-aci/
├── function_app/
│   ├── function_app.py          # Azure Function (v2 model)
│   ├── qualys_scanner_binary.py # qscanner binary wrapper
│   ├── image_parser.py          # Container image parsing
│   ├── storage_handler.py       # Azure Storage operations
│   ├── host.json                # Function configuration
│   └── requirements.txt         # Python dependencies
├── infrastructure/
│   ├── main.bicep               # Subscription-level deployment
│   └── resources.bicep          # Resource group resources
└── README.md
```

## Contributing

This is an internal tool. For issues or improvements, contact the platform team.

## License

Proprietary - Internal Use Only
