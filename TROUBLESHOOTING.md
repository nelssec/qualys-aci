# Troubleshooting Guide

## Viewing Scan Results

### 1. Check Azure Storage (Local Results)

Scan results are stored in Azure Storage regardless of Qualys dashboard visibility:

```bash
./view-scan-results.sh
```

This shows:
- Blob storage: Full JSON scan results
- Table storage: Scan metadata and summary

### 2. Check Application Insights Logs

View function execution and scan logs:

```bash
./view-logs.sh
```

Common log queries:
- EventProcessor function execution
- QScanner container creation and completion
- Errors and warnings

### 3. Check Qualys Dashboard

Results should appear in Qualys Cloud Platform:

1. Login to Qualys Cloud Platform for your POD (e.g., US2)
2. Navigate to Container Security
3. Look for scans with source "qscanner-aci"

If scans don't appear in Qualys:

**Verify Token:**
```bash
RG="qualys-scanner-rg"
KV_NAME=$(az keyvault list --resource-group "$RG" --query "[0].name" -o tsv)

# Check token exists
az keyvault secret show --vault-name "$KV_NAME" --name "QualysAccessToken" --query "value" -o tsv | head -c 20
echo "..."
```

**Update Token:**
```bash
export QUALYS_TOKEN="your-token-here"
./update-token.sh
```

Note: Requires Key Vault Secrets Officer role. If you get permission errors, see "Key Vault Permission Denied" section below.

**Verify POD Setting:**
```bash
# Check POD parameter in deployment
az functionapp config appsettings list \
  --resource-group "$RG" \
  --name $(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv) \
  --query "[?name=='QUALYS_POD'].value" -o tsv
```

Expected: US1, US2, US3, EU1, EU2, etc.

### 4. Manual Test with Log Capture

Run a test scan and capture full logs:

```bash
RG="qualys-scanner-rg"
TEST_CONTAINER="test-scan-$(date +%s)"

# Deploy test container
az container create \
  --resource-group "$RG" \
  --name "$TEST_CONTAINER" \
  --image "mcr.microsoft.com/azuredocs/aci-helloworld:latest" \
  --cpu 1 --memory 1 --os-type Linux

# Wait for scan to trigger
sleep 60

# Check qscanner container logs
QSCANNER_CONTAINER=$(az container list \
  --resource-group "$RG" \
  --query "[?contains(name, 'qscanner')].name | [0]" -o tsv)

if [ -n "$QSCANNER_CONTAINER" ]; then
  echo "QScanner logs:"
  az container logs \
    --resource-group "$RG" \
    --name "$QSCANNER_CONTAINER" \
    --container-name "qscanner"
fi

# Cleanup
az container delete --resource-group "$RG" --name "$TEST_CONTAINER" --yes
```

## Common Issues

### Key Vault Permission Denied

If you get permission errors when trying to update the Qualys token in Key Vault:

```
ERROR: Caller is not authorized to perform action on resource
Action: 'Microsoft.KeyVault/vaults/secrets/setSecret/action'
```

The Key Vault uses RBAC authorization. Only users with the "Key Vault Secrets Officer" role can update secrets.

**Options to fix:**

1. Grant yourself the role (requires Owner or User Access Administrator):
```bash
RG="qualys-scanner-rg"
KV_NAME=$(az keyvault list --resource-group "$RG" --query "[0].name" -o tsv)
USER_ID=$(az ad signed-in-user show --query id -o tsv)

az role assignment create \
  --role "Key Vault Secrets Officer" \
  --assignee "$USER_ID" \
  --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/$KV_NAME"
```

2. Update via Azure Portal:
   - Navigate to Key Vault: Secrets > QualysAccessToken
   - Click "New Version"
   - Paste new token and save

3. Redeploy infrastructure (will update token during deployment):
```bash
export QUALYS_TOKEN='your-new-token'
./deploy.sh
```

The Function App's managed identity already has the "Key Vault Secrets User" role (read-only), which is sufficient for runtime operation. The Secrets Officer role is only needed for manual token updates.

### Scans Being Skipped (Cached)

If you see logs like:
```
Found 2 recent scans for mcr.microsoft.com/azuredocs/aci-helloworld:latest
Image mcr.microsoft.com/azuredocs/aci-helloworld:latest was recently scanned, skipping
```

This is **expected behavior**. The system caches scan results for 24 hours (default) to avoid duplicate scans of the same image.

**To test with a fresh scan:**
```bash
./test-fresh-scan.sh  # Uses nginx image that likely hasn't been scanned
```

**To force rescan an image:**
1. Wait 24 hours for cache to expire
2. Deploy with a different tag: `image:v2` instead of `image:v1`
3. Deploy with digest: `image@sha256:...`
4. Change `SCAN_CACHE_HOURS` environment variable in Function App

Cache is stored in Azure Table Storage (`ScanMetadata` table). You can view cached scans:
```bash
./view-scan-results.sh
```

### QScanner Containers in Logs

You may see Event Grid events for containers starting with "qscanner-" in the logs. These are automatically filtered out by the EventProcessor to prevent infinite loops. The EventProcessor skips any container with a name starting with "qscanner-" since these are the scanner containers themselves, not containers to be scanned.

Expected log message: `Skipping qscanner container: qscanner-*`

### Scans Not Triggering

Check Event Grid subscription:
```bash
RG="qualys-scanner-rg"
EVENT_GRID_TOPIC=$(az eventgrid system-topic list --resource-group "$RG" --query "[0].name" -o tsv)

az eventgrid system-topic event-subscription list \
  --resource-group "$RG" \
  --system-topic-name "$EVENT_GRID_TOPIC" \
  --output table
```

Expected: 2 subscriptions (aci-deployment, aca-deployment)

### Function Not Executing

Check function app status:
```bash
RG="qualys-scanner-rg"
FUNCTION_APP=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv)

az functionapp show \
  --resource-group "$RG" \
  --name "$FUNCTION_APP" \
  --query "{State:state, RuntimeVersion:siteConfig.linuxFxVersion}" \
  --output table
```

Expected: State=Running, RuntimeVersion contains Python

### QScanner Image Not Found

Verify qscanner image exists in ACR:
```bash
RG="qualys-scanner-rg"
ACR_NAME=$(az acr list --resource-group "$RG" --query "[0].name" -o tsv)

az acr repository show \
  --name "$ACR_NAME" \
  --repository "qualys/qscanner" \
  --output table
```

If missing, import from Docker Hub:
```bash
az acr import \
  --name "$ACR_NAME" \
  --source docker.io/qualys/qscanner:latest \
  --image qualys/qscanner:latest
```

### Results Not in Qualys Dashboard

Scan results are always stored locally in Azure Storage even if Qualys dashboard upload fails.

Possible reasons for missing dashboard results:
1. Invalid or expired Qualys token
2. Incorrect POD setting
3. Network connectivity issues from Azure to Qualys
4. Qualys API limits or quotas

Check qscanner logs for authentication errors:
```bash
# After running test scan
QSCANNER_CONTAINER=$(az container list \
  --resource-group "$RG" \
  --query "[?contains(name, 'qscanner')].name | [0]" -o tsv)

az container logs \
  --resource-group "$RG" \
  --name "$QSCANNER_CONTAINER" \
  --container-name "qscanner" | grep -i "error\|auth\|fail"
```

## Performance Tuning

### Scan Timeout

Default: 600 seconds (10 minutes)

Increase for large images:
```bash
# Update function app setting
az functionapp config appsettings set \
  --resource-group "$RG" \
  --name "$FUNCTION_APP" \
  --settings "SCAN_TIMEOUT=1200"
```

### Resource Allocation

QScanner containers use:
- CPU: 2 cores (minimum requirement)
- Memory: 4GB (minimum requirement)

These are configured in qualys_scanner_aci.py:154-158

## Log Queries

### All Scan Activity (30 minutes)
```bash
APP_INSIGHTS_ID=$(az monitor app-insights component list \
  --resource-group "$RG" \
  --query "[0].appId" -o tsv)

az monitor app-insights query \
  --app "$APP_INSIGHTS_ID" \
  --analytics-query "traces
    | where timestamp > ago(30m)
    | where message contains 'scan' or message contains 'qscanner'
    | project timestamp, message
    | order by timestamp desc"
```

### Failed Scans
```bash
az monitor app-insights query \
  --app "$APP_INSIGHTS_ID" \
  --analytics-query "traces
    | where timestamp > ago(24h)
    | where severityLevel >= 3
    | project timestamp, message, severityLevel
    | order by timestamp desc"
```

### Container Creation Events
```bash
az monitor app-insights query \
  --app "$APP_INSIGHTS_ID" \
  --analytics-query "traces
    | where timestamp > ago(30m)
    | where operation_Name == 'EventProcessor'
    | where message contains 'container'
    | project timestamp, message
    | order by timestamp desc"
```
