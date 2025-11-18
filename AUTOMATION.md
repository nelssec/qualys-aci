# Automated Container Scanning

## Overview

This system automatically scans all container deployments in your Azure subscription using Qualys qscanner.

## How It Works

```
Container Deployment → Event Grid → Azure Function → QScanner (ACI) → Qualys
```

1. Deploy a container (ACI or ACA) to your Azure resource group
2. Event Grid detects the deployment and triggers the EventProcessor function
3. EventProcessor function extracts container images and initiates scans
4. QScanner runs in a temporary ACI container to scan the image
5. Results are uploaded to Qualys and stored in Azure Storage

## Architecture Components

### 1. Event Grid System Topic
- Monitors the resource group for container deployments
- Triggers on `Microsoft.Resources.ResourceWriteSuccess` events
- Filters for ACI and ACA container resources

### 2. EventProcessor Azure Function
- **Location**: `function_app/EventProcessor/__init__.py`
- **Trigger**: Event Grid events
- **Function**:
  - Filters for container deployment events
  - Extracts container images from deployed containers
  - Calls QScannerACI to scan each image
  - Stores results in Azure Storage

### 3. QScannerACI
- **Location**: `function_app/qualys_scanner_aci.py`
- **Function**:
  - Creates temporary ACI containers to run qscanner
  - Passes Qualys token and configuration
  - Monitors scan execution
  - Parses and returns results
  - Cleans up resources after scan

### 4. Storage Handler
- **Location**: `function_app/storage_handler.py`
- **Function**:
  - Stores scan results in Azure Blob Storage
  - Tracks scan metadata in Azure Table Storage
  - Implements caching to avoid duplicate scans

## Deployment

Deploy infrastructure and configure token:

```bash
az group create --name qualys-scanner-rg --location eastus

az deployment group create \
  --resource-group qualys-scanner-rg \
  --template-file infrastructure/main.bicep \
  --parameters infrastructure/main.bicepparam \
  --parameters qualysAccessToken='your-token-here'

cd function_app
func azure functionapp publish $(az functionapp list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) --python --build remote
cd ..

az deployment group create \
  --resource-group qualys-scanner-rg \
  --template-file infrastructure/eventgrid.bicep \
  --parameters functionAppName=$(az functionapp list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) \
  --parameters eventGridTopicName=$(az eventgrid system-topic list --resource-group qualys-scanner-rg --query "[0].name" -o tsv)
```

See DEPLOYMENT.md for detailed instructions.

## Updating Token

Update the Qualys token in Key Vault:

```bash
RG="qualys-scanner-rg"
KV_NAME=$(az keyvault list --resource-group $RG --query "[0].name" -o tsv)
az keyvault secret set --vault-name "$KV_NAME" --name "QualysAccessToken" --value "your-token"
```

## Verification

Check Event Grid subscriptions:

```bash
az eventgrid system-topic event-subscription list \
  --resource-group qualys-scanner-rg \
  --system-topic-name $(az eventgrid system-topic list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) \
  --output table
```

Test with a container deployment:

```bash
./test-automation.sh
```

## Configuration

All configuration is managed via environment variables in the Function App:

| Variable | Description | Example |
|----------|-------------|---------|
| `QUALYS_ACCESS_TOKEN` | Qualys API token (from Key Vault) | `@Microsoft.KeyVault(...)` |
| `QUALYS_POD` | Qualys POD identifier | `US2`, `US3`, `EU1` |
| `QSCANNER_IMAGE` | QScanner container image | `qscanacr....azurecr.io/qualys/qscanner:latest` |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID | Auto-set during deployment |
| `QSCANNER_RESOURCE_GROUP` | Resource group for qscanner containers | `qualys-scanner-rg` |
| `SCAN_TIMEOUT` | Timeout for scans in seconds | `1800` (30 minutes) |
| `SCAN_CACHE_HOURS` | Hours to cache scan results | `24` |
| `NOTIFY_SEVERITY_THRESHOLD` | Minimum severity for alerts | `HIGH`, `CRITICAL` |
| `NOTIFICATION_EMAIL` | Email for vulnerability alerts | Optional |

## Viewing Results

### In Qualys Dashboard

1. Log in to your Qualys portal
2. Navigate to Container Security or CI/CD Security
3. Look for scans tagged with:
   - container_type: ACI or ACA
   - azure_subscription: Your subscription ID
   - resource_group: The resource group name

Note: Scans may take 2-5 minutes to appear in the Qualys dashboard after upload.

### In Azure Storage

Scan results are stored in Azure Blob Storage:

```bash
RG="qualys-scanner-rg"
STORAGE_ACCOUNT=$(az storage account list --resource-group $RG --query "[0].name" -o tsv)

# List recent scan results
az storage blob list \
  --account-name $STORAGE_ACCOUNT \
  --container-name scan-results \
  --query "[].{Name:name, Size:properties.contentLength, LastModified:properties.lastModified}" \
  --output table
```

### In Application Insights

View function execution logs:

```bash
RG="qualys-scanner-rg"
APP_INSIGHTS=$(az monitor app-insights component list --resource-group $RG --query "[0].name" -o tsv)

# View recent EventProcessor executions
az monitor app-insights query \
  --app "$APP_INSIGHTS" \
  --analytics-query "traces
    | where timestamp > ago(1h)
    | where operation_Name == 'EventProcessor'
    | project timestamp, severityLevel, message
    | order by timestamp desc" \
  --output table
```

## Troubleshooting

### Scans not triggering

1. **Check Event Grid subscriptions**:
   ```bash
   az eventgrid system-topic event-subscription list \
     --resource-group qualys-scanner-rg \
     --system-topic-name $(az eventgrid system-topic list --resource-group qualys-scanner-rg --query "[0].name" -o tsv)
   ```

   If no subscriptions exist, run `./deploy-eventgrid.sh`

2. **Check Function App logs**:
   ```bash
   az functionapp log tail \
     --resource-group qualys-scanner-rg \
     --name $(az functionapp list --resource-group qualys-scanner-rg --query "[0].name" -o tsv)
   ```

3. **Deploy test container** to generate an event:
   ```bash
   az container create \
     --resource-group qualys-scanner-rg \
     --name test-scan-$(date +%s) \
     --image nginx:latest \
     --cpu 1 --memory 1
   ```

### Scans failing

1. **Check Qualys token**:
   ```bash
   # Verify token is set in Key Vault
   az keyvault secret show \
     --vault-name $(az keyvault list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) \
     --name QualysAccessToken \
     --query "value" -o tsv
   ```

   Update if needed:
   ```bash
   export QUALYS_TOKEN="your-token"
   ./setup-automation.sh
   ```

2. **Check QUALYS_POD setting**:
   ```bash
   az functionapp config appsettings list \
     --resource-group qualys-scanner-rg \
     --name $(az functionapp list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) \
     --query "[?name=='QUALYS_POD'].value" -o tsv
   ```

   Set if empty:
   ```bash
   az functionapp config appsettings set \
     --resource-group qualys-scanner-rg \
     --name $(az functionapp list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) \
     --settings QUALYS_POD=US2
   ```

3. **Check qscanner container logs**:
   ```bash
   # List qscanner containers
   az container list \
     --resource-group qualys-scanner-rg \
     --query "[?contains(name, 'qscanner')].[name, instanceView.state]" \
     --output table

   # View logs from a specific container
   az container logs \
     --resource-group qualys-scanner-rg \
     --name <qscanner-container-name>
   ```

### Scans not appearing in Qualys

1. **Wait a few minutes** - Qualys takes time to process uploaded scans

2. **Check correct POD** - Ensure you're logged into the correct Qualys POD (US2, US3, etc.)

3. **Verify token permissions** - The token needs Container Security API permissions

4. **Check scan upload in logs**:
   ```bash
   az monitor app-insights query \
     --app $(az monitor app-insights component list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) \
     --analytics-query "traces
       | where message contains 'uploaded'
       | project timestamp, message
       | order by timestamp desc
       | take 10" \
     --output table
   ```

## Manual Testing

You can manually trigger a scan using the test script:

```bash
export QUALYS_TOKEN="your-token"
./test-qscanner-manual.sh
```

This runs qscanner in ACI without going through the Event Grid automation, useful for:
- Verifying the Qualys token works
- Testing qscanner configuration changes
- Debugging scan issues

## Scan Caching

To avoid duplicate scans, the system caches results for `SCAN_CACHE_HOURS` (default: 24 hours).

- Scans are cached by image full name (registry/repository:tag)
- Cache metadata is stored in Azure Table Storage
- Recent scans are skipped automatically

To force a rescan, delete the cache entry:

```bash
# List cached scans
az storage entity query \
  --account-name $(az storage account list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) \
  --table-name ScanMetadata \
  --query "items[].{ImageName:RowKey, LastScan:Timestamp}" \
  --output table

# Delete a cache entry (forces rescan)
az storage entity delete \
  --account-name $(az storage account list --resource-group qualys-scanner-rg --query "[0].name" -o tsv) \
  --table-name ScanMetadata \
  --partition-key "scan" \
  --row-key "<image-name>"
```

## Cost Optimization

The system is designed to minimize costs:

1. **Serverless Function App** - Only runs when containers are deployed
2. **On-demand qscanner** - ACI containers are created only for scans and deleted after
3. **Scan caching** - Avoids duplicate scans within the cache period
4. **Minimal storage** - Only scan results are stored

Typical monthly costs:
- Function App (Consumption): ~$1-5
- Storage: ~$1-2
- ACI (per scan): ~$0.01-0.05
- Event Grid: Free (first 100k operations/month)

## Security

- **Token storage**: Qualys token stored securely in Azure Key Vault
- **Managed Identity**: Function App uses managed identity to access Azure resources
- **RBAC**: Minimal permissions assigned (Contributor on resource group, Key Vault Secrets User)
- **Secure variables**: Sensitive env vars passed as secure values to containers
- **No public access**: Storage account and Key Vault accessible only from Azure services

## Next Steps

1. **Run setup**: `export QUALYS_TOKEN="..." && ./setup-automation.sh`
2. **Test automation**: `./test-automation.sh`
3. **Deploy containers**: All future container deployments will be automatically scanned!
4. **Monitor results**: Check Qualys dashboard and Azure Storage for scan results

## Support

- **View logs**: `az functionapp log tail --resource-group qualys-scanner-rg --name <function-app-name>`
- **Check resources**: `./check-resources.sh` (if exists)
- **Manual test**: `export QUALYS_TOKEN="..." && ./test-qscanner-manual.sh`

For issues with Qualys integration, check:
- Token validity and permissions
- Correct POD configuration
- Network connectivity to Qualys API
