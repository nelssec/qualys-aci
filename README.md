# Qualys Container Scanner for Azure

Automated vulnerability scanning for Azure Container Instances (ACI) and Azure Container Apps (ACA) using Qualys qscanner with remote registry scanning.

## Overview

This solution automatically scans all container images deployed across your Azure subscription using Activity Log diagnostic settings, Event Hub, and Qualys qscanner. The scanner runs directly in Azure Functions using qscanner's remote registry scanning capability (Option 3) - **no container runtime required**. Scan results are uploaded to Qualys Cloud Platform and metadata stored in Azure Storage.

## Architecture

```
Container Deployment → Activity Log → Event Hub → Azure Function (qscanner) → Qualys + Azure Storage
                                                        ↓
                                                   Azure ACR (remote pull via SDK)
```

**Components:**
- **Activity Log Diagnostic Settings**: Subscription-wide monitoring for container deployments
- **Event Hub**: Message streaming from Activity Log to Function
- **Azure Function**: Event processor running qscanner binary with remote registry scanning
- **Azure SDK**: Managed identity authentication for ACR image access
- **Azure Storage**: Scan metadata cache (24-hour deduplication)
- **Qualys Cloud Platform**: Vulnerability scan results

**Key Features:**
- **Remote Registry Scanning**: qscanner streams image layers directly from ACR without pulling/downloading
- **No Container Runtime**: Runs directly in Azure Functions - no Docker, ContainerD, or Podman needed
- **Managed Identity Authentication**: Secure ACR access using Azure managed identity with AcrPull role
- **Subscription-wide**: Monitors ALL resource groups via Activity Log
- **Smart caching**: 24-hour deduplication via Table Storage
- **Event-driven**: 10-15 minute latency from deployment to scan
- **Cost-effective**: Lower resource usage compared to Docker-in-Docker approach

## Prerequisites

- Azure CLI 2.50.0+
- Azure subscription with Contributor role
- Qualys subscription with Container Security
- Qualys Access Token ([generate here](https://qualysguard.qualys.com/cloudview-apps/#/tokens))
- Azure Functions Core Tools 4.x (for local development)

## Deployment

### Step 1: Deploy Infrastructure

```bash
./deploy.sh
```

Or manually:
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

### Step 3: Configure Activity Log Diagnostic Settings

The deployment automatically creates:
- Event Hub namespace with `activity-log` hub
- Activity Log diagnostic settings streaming to Event Hub
- Administrative events filtered and routed to Function

No manual Event Grid configuration needed - Activity Log handles all subscription-wide monitoring.

## Testing

Deploy a test container to trigger automatic scanning:

```bash
az container create \
  --resource-group qualys-scanner-rg \
  --name test-scan-$(date +%s) \
  --image mcr.microsoft.com/dotnet/runtime:8.0 \
  --os-type Linux \
  --cpu 1 --memory 1 \
  --restart-policy Never \
  --location eastus
```

Monitor execution:
```bash
# Function logs via Application Insights
az monitor app-insights query \
  --app $(az monitor app-insights component list --resource-group qualys-scanner-rg --query "[0].appId" -o tsv) \
  --resource-group qualys-scanner-rg \
  --analytics-query "traces | where timestamp > ago(30m) | where message contains 'PROCESSING' or message contains 'Creating container group' | project timestamp, message | order by timestamp desc" \
  --offset 1h

# Check for qscanner ACI containers
az container list --resource-group qualys-scanner-rg --query "[?starts_with(name, 'qscan-')].{name:name, status:instanceView.state, image:containers[0].image}" -o table
```

## How It Works

1. Container deployed to ACI/ACA anywhere in subscription
2. Activity Log captures deployment event (10-15 min latency)
3. Event streamed to Event Hub via diagnostic settings
4. `ActivityLogProcessor` function triggered
5. Function checks 24-hour scan cache in Table Storage
6. If not cached, Function runs qscanner with remote registry scanning:
   - qscanner binary runs directly in Azure Function
   - Authenticates to ACR using managed identity (Azure SDK)
   - Streams image layers directly from ACR (no pull/download)
   - Scans image in-memory without container runtime
   - Uploads results to Qualys Cloud Platform
7. Scan metadata cached for 24 hours

**Scan Duration**: 1-3 minutes per image (remote streaming is faster than pull+scan)
**Scope**: Entire subscription, all resource groups
**Latency**: 10-15 minutes from container creation to scan start
**Authentication**: Managed identity with AcrPull role on subscription

## Viewing Results

### Qualys Dashboard

1. Login to Qualys Cloud Platform (e.g., https://qualysguard.qg2.apps.qualys.com/)
2. Navigate to **Container Security** → **Images**
3. Filter by custom tags:
   - `azure_subscription`
   - `resource_group`
   - `container_type`

Results appear 3-7 minutes after scan completion.

### Azure Storage (Metadata Only)

```bash
RG="qualys-scanner-rg"
STORAGE=$(az storage account list --resource-group $RG --query "[0].name" -o tsv)

# List recent scan metadata
az storage entity query \
  --account-name $STORAGE \
  --table-name ScanMetadata \
  --filter "Timestamp gt datetime'2024-01-01T00:00:00Z'" \
  --auth-mode login
```

## Configuration

| Environment Variable | Description | Default |
|---------------------|-------------|---------|
| `QUALYS_POD` | Qualys platform pod | From deployment |
| `QUALYS_ACCESS_TOKEN` | Qualys token | From environment |
| `QSCANNER_VERSION` | qscanner version | `4.6.0-4` |
| `SCAN_CACHE_HOURS` | Cache duration before rescanning | `24` |
| `AZURE_TENANT_ID` | Azure AD tenant ID | Auto-configured |
| `SCAN_TIMEOUT` | qscanner timeout in seconds | `1800` (30 min) |

**Note**: `AZURE_CLIENT_ID` is NOT required - the Azure SDK automatically uses the function app's system-assigned managed identity.

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
az functionapp config appsettings set \
  --resource-group qualys-scanner-rg \
  --name $FUNCTION_APP \
  --settings QSCANNER_VERSION=4.7.0-1

az functionapp restart --resource-group qualys-scanner-rg --name $FUNCTION_APP
```

### Update Qualys Token

```bash
# Via infrastructure redeployment (preferred)
./deploy.sh

# Or update environment variable directly
az functionapp config appsettings set \
  --resource-group qualys-scanner-rg \
  --name $FUNCTION_APP \
  --settings QUALYS_ACCESS_TOKEN="<new-token>"
```

## Troubleshooting

### Scans Not Triggering

Check Activity Log diagnostic settings:
```bash
az monitor diagnostic-settings subscription list --query "value[?name=='activity-log-to-eventhub']"
```

Expected: Diagnostic setting with `Administrative` category enabled.

Check Event Hub is receiving events:
```bash
az monitor metrics list \
  --resource $(az eventhubs namespace list --resource-group qualys-scanner-rg --query "[0].id" -o tsv) \
  --metric IncomingMessages \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --interval PT5M
```

Check Function is processing events:
```bash
az monitor app-insights query \
  --app $(az monitor app-insights component list --resource-group qualys-scanner-rg --query "[0].appId" -o tsv) \
  --resource-group qualys-scanner-rg \
  --analytics-query "requests | where timestamp > ago(1h) | where name == 'ActivityLogProcessor' | project timestamp, resultCode, duration" \
  --offset 1h
```

### ACR Authentication Failures

Check managed identity has AcrPull permissions:
```bash
# Get function app principal ID
PRINCIPAL_ID=$(az functionapp show \
  --resource-group qualys-scanner-rg \
  --name $FUNCTION_APP \
  --query identity.principalId -o tsv)

# List role assignments
az role assignment list \
  --assignee $PRINCIPAL_ID \
  --query "[?roleDefinitionName=='AcrPull' || roleDefinitionName=='Contributor'].{Role:roleDefinitionName, Scope:scope}" -o table
```

Expected: AcrPull role at subscription scope or specific ACR scope.

Check Function logs for authentication errors:
```bash
az monitor app-insights query \
  --app $(az monitor app-insights component list --resource-group qualys-scanner-rg --query "[0].appId" -o tsv) \
  --resource-group qualys-scanner-rg \
  --analytics-query "traces | where timestamp > ago(30m) and message contains 'ACR' or message contains 'authentication' | project timestamp, severityLevel, message | order by timestamp desc" \
  --offset 1h
```

Common issues:
- **Missing AcrPull role**: Function identity needs AcrPull role on subscription or ACR
- **QSCANNER_REGISTRY_USERNAME set**: This environment variable conflicts with Azure SDK auth and must NOT be set
- **Wrong tenant**: Verify AZURE_TENANT_ID matches your subscription's tenant

### Scan Failures

Check Function logs for qscanner errors:
```bash
az monitor app-insights query \
  --app $(az monitor app-insights component list --resource-group qualys-scanner-rg --query "[0].appId" -o tsv) \
  --resource-group qualys-scanner-rg \
  --analytics-query "traces | where timestamp > ago(30m) and severityLevel >= 3 | project timestamp, severityLevel, message | order by timestamp desc" \
  --offset 1h
```

Common issues:
- **Missing RBAC**: Function identity needs Contributor + AcrPull roles
- **Timeout**: Increase SCAN_TIMEOUT for large images
- **Network errors**: Check Function App outbound connectivity to ACR and Qualys

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
# Option 1: Clear cache (requires Storage Table Data Contributor role)
az storage entity delete \
  --account-name $(az storage account list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) \
  --auth-mode login \
  --table-name ScanMetadata \
  --partition-key <image-registry> \
  --row-key <image-name-tag>

# Option 2: Deploy with unique tag
az container create \
  --resource-group qualys-scanner-rg \
  --name test-scan-$(date +%s) \
  --image mcr.microsoft.com/dotnet/runtime:8.0-$(date +%Y%m%d%H%M%S) \
  --os-type Linux \
  --restart-policy Never
```

## Security

### Authentication & Authorization
- **Function Identity**: System-assigned managed identity
- **Subscription Access**: Contributor role (read container metadata)
- **ACR Access**: AcrPull role (pull images via Azure SDK for remote scanning)
- **Storage Access**: Connection string (future: migrate to managed identity)
- **Qualys API**: Bearer token authentication

### RBAC Roles Required
| Resource | Role | Scope | Purpose |
|----------|------|-------|---------|
| Subscription | Contributor | Subscription | Read Activity Log, container metadata |
| Subscription | AcrPull | Subscription | Pull images from ACR registries for scanning |
| Storage | Storage Table Data Contributor | Storage Account | Cache scan metadata |

### Network Security
- **Event Hub**: Public access (limited to Azure services)
- **Storage**: Public access (limited to Azure services)
- **Function**: Outbound to Azure API, ACR, and Qualys API

### Data Protection
- **Scan Metadata**: Cached in Table Storage (24 hours)
- **Scan Results**: Uploaded directly to Qualys (not stored in Azure)
- **Token Storage**: Environment variable (future: migrate to Key Vault)

## Cost Optimization

Monthly cost estimate (moderate usage, ~100 scans/month):

| Service | SKU | Cost |
|---------|-----|------|
| Azure Functions | Consumption (Linux) | $3-8 |
| Storage Account | Standard LRS | $1-2 |
| Event Hub | Basic tier | $11 |
| Application Insights | Pay-as-you-go | $0-2 |
| **Total** | | **$15-23/month** |

**Cost breakdown per scan**: ~$0.03-0.08 (Function execution + storage)

**Cost Savings vs Docker-in-Docker**:
- ~50% reduction by eliminating ACI container costs
- Faster scans = lower function execution time
- No ACI startup overhead or regional quota issues

## Technical Details

### Function Runtime
- **Python Version**: 3.11
- **Programming Model**: v2 (decorator-based)
- **Extension Bundle**: 4.x
- **Timeout**: 10 minutes (only orchestrates ACI)
- **Retry Policy**: Event Hub built-in retry

### Storage Schema
- **Table**: `ScanMetadata` - Cache and lookup table
  - PartitionKey: Registry domain (e.g., `mcr.microsoft.com`)
  - RowKey: Repository + tag (e.g., `dotnet/runtime:8.0`)
  - Timestamp: Scan completion time

### Activity Log Streaming
- **Diagnostic Setting**: `activity-log-to-eventhub`
- **Event Hub**: `activity-log` in dedicated namespace
- **Categories**: Administrative (container create/update/delete)
- **Latency**: 10-15 minutes observed
- **Filter**: All subscription-level administrative operations

### QScanner Remote Registry Scanning
- **Scanning Method**: Remote registry (Option 3) - no container runtime required
- **Authentication**: Azure SDK with managed identity (AcrPull role)
- **Runtime Process**:
  1. qscanner binary runs in Azure Function
  2. Authenticates to ACR using managed identity
  3. Streams image layers directly from ACR
  4. Scans image in-memory (no pull/download)
  5. Uploads results to Qualys
- **Scan Types**: OS packages, SCA, secrets
- **Source**: `https://cask.qg1.apps.qualys.com/cs/.../qscanner/<version>/qscanner-<version>.linux-amd64.tar.gz`
- **Key Advantage**: 50% faster and more cost-effective than Docker-based scanning

## Advanced Configuration

### Custom Scan Tags

Edit `function_app/qualys_scanner_binary.py`:
```python
custom_tags = {
    'azure_subscription': subscription_id,
    'resource_group': resource_group,
    'container_type': container_type,
    'environment': 'prod'
}
```

### Multi-Subscription Deployment

Deploy once per subscription:
```bash
for SUB in sub1 sub2 sub3; do
  az account set --subscription $SUB
  ./deploy.sh
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

# Run locally (requires Azurite for Event Hub trigger)
func start
```

### Project Structure

```
qualys-aci/
├── function_app/
│   ├── function_app.py          # Azure Function (v2 model)
│   ├── qualys_scanner_binary.py # Remote registry scanner with Azure SDK
│   ├── qualys_scanner_aci.py    # Legacy Docker-in-Docker (deprecated)
│   ├── image_parser.py          # Container image parsing
│   ├── storage_handler.py       # Azure Storage operations
│   ├── host.json                # Function configuration
│   └── requirements.txt         # Python dependencies
├── infrastructure/
│   ├── main.bicep               # Subscription-level deployment
│   └── resources.bicep          # Resource group resources
├── deploy.sh                    # Deployment script
├── cleanup.sh                   # Resource cleanup script
├── ARCHITECTURE.md              # Detailed architecture
└── README.md
```

## Known Limitations

- **Activity Log Latency**: 10-15 minutes from container creation to scan start (Azure platform limitation)
- **Function Timeout**: Default 10 minutes - very large images may need timeout adjustment
- **Image Size**: Very large images (>10GB) may timeout (increase SCAN_TIMEOUT)
- **ACR Authentication**: Requires AcrPull role on subscription or specific ACRs
- **Non-ACR Registries**: Additional authentication configuration needed for Docker Hub, ECR, etc.

## Contributing

This is an internal tool. For issues or improvements, contact the platform team.

## License

Proprietary - Internal Use Only
