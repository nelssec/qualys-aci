# Qualys Container Scanner for Azure ACI/ACA

Event-driven container image scanning for Azure Container Instances and Azure Container Apps using Qualys qscanner.

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

## Deployment

### Prerequisites

- Azure CLI 2.50.0+
- Azure subscription with Contributor role
- Qualys account credentials
- Python 3.11 (for local development)
- For tenant-wide: Management Group permissions

### Option 1: Single Subscription

Monitor container deployments in one subscription.

Configure `infrastructure/main.bicepparam` with your settings, then:

```bash
cd infrastructure

# Create resource group
az group create \
  --name qualys-scanner-rg \
  --location eastus

# Deploy infrastructure
az deployment group create \
  --resource-group qualys-scanner-rg \
  --template-file main.bicep \
  --parameters main.bicepparam \
  --parameters qualysUsername='your-username' \
  --parameters qualysPassword='your-password'

# Deploy function code
cd ../function_app
FUNCTION_APP=$(az deployment group show \
  --resource-group qualys-scanner-rg \
  --name main \
  --query properties.outputs.functionAppName.value -o tsv)
func azure functionapp publish $FUNCTION_APP
```

### Option 2: Tenant-Wide Monitoring

Monitor ALL subscriptions in your tenant.

```bash
# Step 1: Deploy Function App (same as Option 1)
cd infrastructure
az group create --name qualys-scanner-rg --location eastus
az deployment group create \
  --resource-group qualys-scanner-rg \
  --template-file main.bicep \
  --parameters main.bicepparam \
  --parameters qualysUsername='your-username' \
  --parameters qualysPassword='your-password'

# Step 2: Deploy function code
cd ../function_app
FUNCTION_APP=$(az deployment group show \
  --resource-group qualys-scanner-rg \
  --name main \
  --query properties.outputs.functionAppName.value -o tsv)
func azure functionapp publish $FUNCTION_APP

# Step 3: Get tenant root management group
TENANT_ROOT=$(az account management-group list \
  --query "[?displayName=='Tenant Root Group'].name" -o tsv)

# Step 4: Configure and deploy tenant-wide Event Grid
cd ../infrastructure
# Edit tenant-wide.bicepparam with your function app details
az deployment mg create \
  --management-group-id $TENANT_ROOT \
  --location eastus \
  --template-file tenant-wide.bicep \
  --parameters tenant-wide.bicepparam
```

See `DEPLOYMENT.md` for complete deployment guide.

The deployment creates:
- Function App (Python 3.11, Consumption or Premium plan)
- Storage account for scan results
- Key Vault for credentials
- Application Insights
- Event Grid subscriptions (subscription or management group scoped)
- RBAC assignments (Key Vault access, Contributor for ACI management)

### Configuration

Environment variables set by deployment:

| Variable | Description |
|----------|-------------|
| QUALYS_USERNAME | Qualys account username (from Key Vault) |
| QUALYS_PASSWORD | Qualys account password (from Key Vault) |
| AZURE_SUBSCRIPTION_ID | Subscription where scan containers run |
| QSCANNER_RESOURCE_GROUP | Resource group for scan containers |
| QSCANNER_IMAGE | Docker image (qualys/qscanner:latest) |
| SCAN_TIMEOUT | Maximum scan duration (default: 1800s) |
| STORAGE_CONNECTION_STRING | Azure Storage for results |
| NOTIFICATION_EMAIL | Email for high-severity alerts |

## How It Works

### Scan Process

1. User deploys container to ACI or ACA
2. Azure Resource Manager emits deployment event
3. Event Grid routes event to Function App
4. Function extracts container image details from event
5. Function creates ACI container with qscanner image
6. qscanner pulls and scans the target image
7. Function retrieves scan results from container logs
8. Results stored in Blob Storage (full JSON) and Table Storage (metadata)
9. Function deletes scan container
10. If critical/high vulnerabilities found, alert sent

### Scan Deduplication

Images are cached for 24 hours by default. If the same image is deployed multiple times within the cache period, only the first deployment triggers a scan. This prevents duplicate scans and reduces costs.

### Cost Estimate

Based on 100 container deployments per day:

- ACI scan containers: ~$3/month (2GB RAM, 1 CPU, 2 min avg)
- Function App (Consumption): ~$2/month
- Storage: ~$2/month
- Total: ~$7/month

Actual costs depend on image size and scan frequency.

## Monitoring

### View Scans

Application Insights query for recent scans:

```kusto
traces
| where customDimensions.EventType == "ContainerScan"
| project timestamp, image=customDimensions.Image,
          critical=customDimensions.VulnCritical,
          high=customDimensions.VulnHigh
| order by timestamp desc
```

### View Failures

```kusto
exceptions
| where timestamp > ago(24h)
| where customDimensions contains "QScannerACI"
| project timestamp, problemId, outerMessage
```

### Active Scan Containers

```bash
az container list \
  --resource-group qualys-scanner-rg \
  --query "[?starts_with(name, 'qscanner-')].{Name:name, State:instanceView.state}"
```

## Troubleshooting

### Function not triggering

Check Event Grid subscription:

```bash
az eventgrid system-topic event-subscription show \
  --name aci-container-deployments \
  --resource-group qualys-scanner-rg \
  --system-topic-name qualys-scanner-aci-topic
```

Verify events are being delivered:

```bash
az monitor metrics list \
  --resource <event-grid-topic-id> \
  --metric DeliverySuccessCount,DeliveryFailedCount
```

### Scan container fails

Check Function App logs:

```bash
az monitor app-insights query \
  --app qualys-scanner-func-xxx \
  --analytics-query "exceptions | where timestamp > ago(1h)"
```

Common issues:
- Invalid Qualys credentials (check Key Vault secrets)
- Insufficient ACI quota (request quota increase)
- Image pull failures (verify registry access)

### Private registry access

For Azure Container Registry, grant the Function App's managed identity AcrPull role:

```bash
PRINCIPAL_ID=$(az functionapp identity show \
  --name qualys-scanner-func-xxx \
  --resource-group qualys-scanner-rg \
  --query principalId -o tsv)

az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role AcrPull \
  --scope /subscriptions/xxx/resourceGroups/xxx/providers/Microsoft.ContainerRegistry/registries/xxx
```

## Development

### Local Testing

```bash
cd function_app
pip install -r requirements.txt

# Copy and configure local settings
cp local.settings.json.sample local.settings.json
# Edit local.settings.json with your credentials

# Start function runtime
func start
```

Test with sample event:

```bash
curl -X POST http://localhost:7071/api/EventProcessor \
  -H "Content-Type: application/json" \
  -d @test_events/aci_deployment.json
```

### Project Structure

```
function_app/
  EventProcessor/          # Event Grid triggered function
    __init__.py           # Main event handler
    function.json         # Function bindings
  qualys_scanner_aci.py   # ACI-based scanner
  image_parser.py         # Container image name parser
  storage_handler.py      # Azure Storage operations
  requirements.txt        # Python dependencies

infrastructure/
  main.bicep             # Azure resources
  deploy.sh              # Deployment script

test_events/             # Sample Event Grid events
config/                  # Configuration samples
```

## Scan Results

### Storage Structure

Blob container `scan-results`:
```
docker.io_library_nginx_latest/
  scan-20240115123456.json
  scan-20240116234567.json
myacr.azurecr.io_app_v1.0/
  scan-20240115145623.json
```

Table `ScanMetadata`:
- PartitionKey: Sanitized image name
- RowKey: Scan ID
- Columns: Image, Timestamp, VulnCritical, VulnHigh, VulnMedium, VulnLow, CompliancePassed, ComplianceFailed, BlobPath

### Custom Tags

Each scan includes tags for correlation:
- `image`: Full image identifier
- `container_type`: ACI or ACA
- `azure_subscription`: Subscription ID
- `resource_group`: Resource group name
- `event_id`: Event Grid event ID
- `scan_time`: ISO 8601 timestamp

Query scans in Qualys portal using these tags to correlate with Azure deployments.

## Security

- Qualys credentials stored in Key Vault, referenced via Key Vault references in Function App settings
- Function App uses system-assigned managed identity for all Azure resource access
- Scan containers are ephemeral and deleted after completion
- Storage account disables public blob access
- All traffic uses TLS 1.2+
- RBAC used throughout (no access keys where possible)

## License

MIT License - see LICENSE file
