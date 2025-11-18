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
./update.sh
```

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
