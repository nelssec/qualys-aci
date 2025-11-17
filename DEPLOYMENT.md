# Production Deployment Guide

## Prerequisites

- Azure subscription with Contributor role
- Azure CLI 2.50.0+
- Qualys subscription with Container Security module
- Qualys API credentials

Register required resource providers:

```bash
az provider register --namespace Microsoft.ContainerInstance
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.EventGrid
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.KeyVault
az provider register --namespace Microsoft.Web
```

## Deploy Infrastructure

```bash
cd infrastructure

export QUALYS_USERNAME="your-username"
export QUALYS_PASSWORD="your-password"

./deploy.sh \
  -s your-subscription-id \
  -r qualys-scanner-prod \
  -l eastus \
  -n "$QUALYS_USERNAME" \
  -w "$QUALYS_PASSWORD" \
  -e security@example.com \
  -k Y1
```

Options:
- `-s`: Azure subscription ID (required)
- `-r`: Resource group name (required)
- `-l`: Azure region (required)
- `-n`: Qualys username (required)
- `-w`: Qualys password (required)
- `-e`: Notification email (optional)
- `-k`: Function App SKU - Y1 (Consumption) or EP1/EP2/EP3 (Premium)

The deployment creates:
- Storage account for scan results
- Function App with system-assigned managed identity
- Key Vault for Qualys credentials
- Application Insights for monitoring
- Event Grid system topic and subscriptions
- RBAC role assignments

## Deploy Function Code

If not using `--deploy-function` flag in the deploy script:

```bash
cd function_app

# Get function app name from deployment output
FUNCTION_APP=$(az functionapp list \
  --resource-group qualys-scanner-prod \
  --query "[0].name" -o tsv)

# Deploy
func azure functionapp publish $FUNCTION_APP
```

## Configure Private Registry Access

For scanning images from Azure Container Registry:

```bash
# Get Function App managed identity
PRINCIPAL_ID=$(az functionapp identity show \
  --name $FUNCTION_APP \
  --resource-group qualys-scanner-prod \
  --query principalId -o tsv)

# Grant AcrPull to each ACR
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role AcrPull \
  --scope /subscriptions/xxx/resourceGroups/xxx/providers/Microsoft.ContainerRegistry/registries/xxx
```

## Verify Deployment

Test the end-to-end flow:

```bash
# Deploy test container
az container create \
  --resource-group test-rg \
  --name test-nginx \
  --image nginx:latest \
  --cpu 1 \
  --memory 1

# Wait 2-3 minutes for scan to complete

# Check scan results
az storage entity query \
  --account-name <storage-account> \
  --table-name ScanMetadata \
  --filter "Image eq 'docker.io/library/nginx:latest'"
```

View function logs:

```bash
az monitor app-insights query \
  --app $FUNCTION_APP \
  --analytics-query "traces | where timestamp > ago(30m) | order by timestamp desc"
```

## Post-Deployment Configuration

### Configure Alerts

Create alert for critical vulnerabilities:

```bash
az monitor metrics alert create \
  --name critical-vulnerabilities \
  --resource-group qualys-scanner-prod \
  --scopes /subscriptions/xxx/resourceGroups/qualys-scanner-prod/providers/Microsoft.Insights/components/xxx \
  --condition "count exceptions > 0" \
  --description "Alert on critical vulnerabilities found"
```

### Enable Diagnostic Logging

```bash
az monitor diagnostic-settings create \
  --name function-logs \
  --resource /subscriptions/xxx/resourceGroups/qualys-scanner-prod/providers/Microsoft.Web/sites/$FUNCTION_APP \
  --logs '[{"category": "FunctionAppLogs", "enabled": true}]' \
  --workspace /subscriptions/xxx/resourceGroups/qualys-scanner-prod/providers/Microsoft.OperationalInsights/workspaces/xxx
```

### Adjust Scan Timeout

For large images that take longer to scan:

```bash
az functionapp config appsettings set \
  --name $FUNCTION_APP \
  --resource-group qualys-scanner-prod \
  --settings "SCAN_TIMEOUT=3600"
```

Also update function timeout in host.json:

```json
{
  "functionTimeout": "00:30:00"
}
```

## Monitoring

### Check Event Grid Delivery

```bash
az eventgrid system-topic event-subscription show \
  --name aci-container-deployments \
  --resource-group qualys-scanner-prod \
  --system-topic-name qualys-scanner-aci-topic \
  --query provisioningState
```

View metrics:

```bash
az monitor metrics list \
  --resource <event-grid-topic-id> \
  --metric DeliverySuccessCount,DeliveryFailedCount \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
```

### View Active Scans

```bash
az container list \
  --resource-group qualys-scanner-prod \
  --query "[?tags.purpose=='qscanner'].{Name:name, State:instanceView.state}"
```

### Query Scan Results

Application Insights:

```kusto
traces
| where customDimensions.EventType == "ContainerScan"
| where timestamp > ago(24h)
| summarize count() by tostring(customDimensions.Image)
```

Storage Table:

```bash
az storage entity query \
  --account-name <storage-account> \
  --table-name ScanMetadata \
  --filter "Timestamp ge datetime'$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)'"
```

## Troubleshooting

### Function Not Triggering

Check Event Grid subscription:

```bash
az eventgrid system-topic event-subscription show \
  --name aci-container-deployments \
  --resource-group qualys-scanner-prod \
  --system-topic-name qualys-scanner-aci-topic
```

Verify function system key is configured:

```bash
az functionapp keys list \
  --name $FUNCTION_APP \
  --resource-group qualys-scanner-prod
```

### Scan Container Fails

Check function logs for errors:

```bash
az monitor app-insights query \
  --app $FUNCTION_APP \
  --analytics-query "exceptions | where timestamp > ago(1h) | project timestamp, problemId, outerMessage"
```

Common issues:
- Invalid Qualys credentials: Verify secrets in Key Vault
- ACI quota exceeded: Request quota increase
- Network issues: Check NSG rules if using VNet

### Container Fails to Pull Image

For private registries, ensure managed identity has access:

```bash
# Check role assignments
az role assignment list \
  --assignee $PRINCIPAL_ID \
  --scope <acr-resource-id>
```

Verify registry allows Azure service access:

```bash
az acr show \
  --name <registry-name> \
  --query networkRuleSet
```

### Scan Timeout

Increase timeout for large images:

```bash
# Function app setting
az functionapp config appsettings set \
  --name $FUNCTION_APP \
  --settings "SCAN_TIMEOUT=3600"

# Also update host.json functionTimeout
```

## Cost Optimization

- Use Consumption plan (Y1) for low-to-medium volume
- Scan cache period set to 24 hours to avoid duplicate scans
- Delete old scan results from storage after retention period

Monitor costs:

```bash
az consumption usage list \
  --start-date 2024-01-01 \
  --end-date 2024-01-31 \
  --query "[?contains(instanceName, 'qscanner')]"
```

## Scaling Considerations

Function App automatically scales based on Event Grid queue depth. For high volume:

- Use Premium plan (EP1+) for faster cold starts
- Consider VNet integration for network isolation
- Increase ACI quota if hitting limits

Premium plan configuration:

```bash
./deploy.sh \
  -s subscription-id \
  -r qualys-scanner-prod \
  -l eastus \
  -k EP1 \
  -n "$QUALYS_USERNAME" \
  -w "$QUALYS_PASSWORD"
```

## Security Hardening

For production deployments:

1. Enable VNet integration (Premium plan required):

```bash
az functionapp vnet-integration add \
  --name $FUNCTION_APP \
  --resource-group qualys-scanner-prod \
  --vnet <vnet-name> \
  --subnet <subnet-name>
```

2. Enable private endpoints for storage:

```bash
az storage account network-rule add \
  --account-name <storage-account> \
  --vnet-name <vnet-name> \
  --subnet <subnet-name>
```

3. Restrict Key Vault network access:

```bash
az keyvault network-rule add \
  --name <keyvault-name> \
  --vnet-name <vnet-name> \
  --subnet <subnet-name>
```

4. Enable Azure Defender:

```bash
az security pricing create \
  --name VirtualMachines \
  --tier Standard
```

## Backup and Disaster Recovery

Storage account uses LRS by default. For geo-redundancy:

```bash
az storage account update \
  --name <storage-account> \
  --resource-group qualys-scanner-prod \
  --sku Standard_GRS
```

Key Vault has soft delete enabled by default with 90-day retention.

Export ARM template for infrastructure:

```bash
az group export \
  --name qualys-scanner-prod \
  --output json > backup-template.json
```

## Rollback Procedure

If deployment fails or issues occur:

```bash
# List deployments
az deployment group list \
  --resource-group qualys-scanner-prod \
  --query "[].{Name:name, Time:properties.timestamp, State:properties.provisioningState}"

# Delete resources and redeploy
az group delete --name qualys-scanner-prod --yes
./deploy.sh # with original parameters
```
