# Deployment Guide

This guide provides detailed instructions for deploying the Qualys Azure Container Scanner in production.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Pre-Deployment Checklist](#pre-deployment-checklist)
3. [Deployment Steps](#deployment-steps)
4. [Post-Deployment Configuration](#post-deployment-configuration)
5. [Verification](#verification)
6. [Troubleshooting](#troubleshooting)

## Prerequisites

### Azure Requirements

- Azure subscription with Owner or Contributor role
- Azure CLI version 2.50.0 or higher
- Permissions to create:
  - Resource Groups
  - Storage Accounts
  - Function Apps
  - Key Vaults
  - Event Grid subscriptions
  - Role assignments

### Qualys Requirements

- Active Qualys subscription with Container Security module
- API credentials (username and password)
- API endpoint URL (varies by region):
  - US Platform 1: `https://qualysapi.qualys.com`
  - US Platform 2: `https://qualysapi.qg2.apps.qualys.com`
  - US Platform 3: `https://qualysapi.qg3.apps.qualys.com`
  - US Platform 4: `https://qualysapi.qg4.apps.qualys.com`
  - EU Platform 1: `https://qualysapi.qualys.eu`
  - EU Platform 2: `https://qualysapi.qg2.apps.qualys.eu`
  - India Platform: `https://qualysapi.qg1.apps.qualys.in`

### Local Development Tools

- Python 3.9 or higher (for local testing)
- Azure Functions Core Tools v4
- Git
- jq (for parsing JSON outputs)

## Pre-Deployment Checklist

- [ ] Verify Azure subscription has required resource providers registered:
  ```bash
  az provider register --namespace Microsoft.ContainerInstance
  az provider register --namespace Microsoft.App
  az provider register --namespace Microsoft.EventGrid
  az provider register --namespace Microsoft.Storage
  az provider register --namespace Microsoft.KeyVault
  az provider register --namespace Microsoft.Web
  ```

- [ ] Verify Qualys API credentials:
  ```bash
  curl -u "username:password" https://qualysapi.qualys.com/api/2.0/fo/about/
  ```

- [ ] Choose deployment region (must support all required services)
- [ ] Determine Function App SKU (Consumption Y1 for dev/test, Elastic Premium for production)
- [ ] Configure notification email addresses
- [ ] Review security and compliance requirements

## Deployment Steps

### Step 1: Clone Repository

```bash
git clone <repository-url>
cd qualys-aci
```

### Step 2: Configure Settings

```bash
# Copy sample configuration
cp config/config.sample.json config/config.json

# Edit configuration with your settings
vim config/config.json
```

### Step 3: Set Environment Variables

```bash
# Export Qualys credentials
export QUALYS_USERNAME="your-qualys-username"
export QUALYS_PASSWORD="your-qualys-password"
export QUALYS_API_URL="https://qualysapi.qualys.com"

# Optional: Set notification email
export NOTIFICATION_EMAIL="security@example.com"
```

### Step 4: Deploy Infrastructure

#### Option A: Quick Deployment (Consumption Plan)

```bash
cd infrastructure
./deploy.sh \
  -s "your-subscription-id" \
  -r "qualys-scanner-prod" \
  -l "eastus" \
  -e "security@example.com" \
  --deploy-function
```

#### Option B: Production Deployment (Elastic Premium)

```bash
cd infrastructure
./deploy.sh \
  -s "your-subscription-id" \
  -r "qualys-scanner-prod" \
  -l "eastus" \
  -k "EP1" \
  -e "security@example.com" \
  --deploy-function
```

#### Option C: Manual Deployment with Bicep

```bash
cd infrastructure

# Create resource group
az group create \
  --name "qualys-scanner-prod" \
  --location "eastus"

# Deploy infrastructure
az deployment group create \
  --name "qualys-scanner-$(date +%Y%m%d)" \
  --resource-group "qualys-scanner-prod" \
  --template-file main.bicep \
  --parameters \
    qualysApiUrl="$QUALYS_API_URL" \
    qualysUsername="$QUALYS_USERNAME" \
    qualysPassword="$QUALYS_PASSWORD" \
    notificationEmail="$NOTIFICATION_EMAIL" \
    functionAppSku="EP1"
```

### Step 5: Deploy Function Code

If you didn't use `--deploy-function` flag:

```bash
cd function_app

# Install Azure Functions Core Tools if needed
npm install -g azure-functions-core-tools@4

# Get function app name from deployment
FUNCTION_APP_NAME=$(az functionapp list \
  --resource-group qualys-scanner-prod \
  --query "[0].name" -o tsv)

# Deploy function code
func azure functionapp publish $FUNCTION_APP_NAME
```

### Step 6: Configure Private Registry Access (Optional)

If scanning images from Azure Container Registry:

```bash
# Get function app principal ID
PRINCIPAL_ID=$(az functionapp identity show \
  --name $FUNCTION_APP_NAME \
  --resource-group qualys-scanner-prod \
  --query principalId -o tsv)

# Grant AcrPull role to ACR
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "AcrPull" \
  --scope "/subscriptions/<sub-id>/resourceGroups/<acr-rg>/providers/Microsoft.ContainerRegistry/registries/<acr-name>"
```

## Post-Deployment Configuration

### 1. Verify Event Grid Subscriptions

```bash
# List Event Grid subscriptions
az eventgrid system-topic event-subscription list \
  --resource-group qualys-scanner-prod \
  --system-topic-name qualys-scanner-aci-topic

# Check subscription status
az eventgrid system-topic event-subscription show \
  --name aci-container-deployments \
  --resource-group qualys-scanner-prod \
  --system-topic-name qualys-scanner-aci-topic
```

### 2. Configure Application Insights Alerts

```bash
# Create alert for failed scans
az monitor metrics alert create \
  --name "qualys-scan-failures" \
  --resource-group qualys-scanner-prod \
  --scopes "/subscriptions/<sub-id>/resourceGroups/qualys-scanner-prod/providers/Microsoft.Insights/components/<app-insights-name>" \
  --condition "count exceptions > 5" \
  --window-size 5m \
  --evaluation-frequency 1m \
  --action email security@example.com
```

### 3. Enable Diagnostic Logs

```bash
# Enable Function App diagnostic logs
az monitor diagnostic-settings create \
  --name "function-diagnostics" \
  --resource "/subscriptions/<sub-id>/resourceGroups/qualys-scanner-prod/providers/Microsoft.Web/sites/$FUNCTION_APP_NAME" \
  --logs '[{"category": "FunctionAppLogs", "enabled": true}]' \
  --metrics '[{"category": "AllMetrics", "enabled": true}]' \
  --workspace "/subscriptions/<sub-id>/resourceGroups/qualys-scanner-prod/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>"
```

### 4. Configure Network Security (Production)

For enhanced security in production:

```bash
# Enable VNet integration (Premium plans only)
az functionapp vnet-integration add \
  --name $FUNCTION_APP_NAME \
  --resource-group qualys-scanner-prod \
  --vnet <vnet-name> \
  --subnet <subnet-name>

# Enable private endpoints for storage
az storage account network-rule add \
  --resource-group qualys-scanner-prod \
  --account-name <storage-account-name> \
  --vnet-name <vnet-name> \
  --subnet <subnet-name>
```

## Verification

### 1. Test with Sample Container Deployment

```bash
# Deploy test ACI container
az container create \
  --resource-group test-rg \
  --name test-nginx \
  --image nginx:latest \
  --cpu 1 \
  --memory 1

# Wait 30 seconds for event processing

# Check function execution logs
az monitor app-insights query \
  --app $FUNCTION_APP_NAME \
  --analytics-query "traces | where message contains 'nginx' | order by timestamp desc | take 10"
```

### 2. Verify Scan Results Storage

```bash
# Get storage account name
STORAGE_ACCOUNT=$(az storage account list \
  --resource-group qualys-scanner-prod \
  --query "[0].name" -o tsv)

# List scan results
az storage blob list \
  --account-name $STORAGE_ACCOUNT \
  --container-name scan-results \
  --output table

# Query scan metadata
az storage entity query \
  --account-name $STORAGE_ACCOUNT \
  --table-name ScanMetadata \
  --filter "Timestamp ge datetime'$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)'"
```

### 3. Check Event Grid Metrics

```bash
# View Event Grid delivery metrics
az monitor metrics list \
  --resource "/subscriptions/<sub-id>/resourceGroups/qualys-scanner-prod/providers/Microsoft.EventGrid/systemTopics/qualys-scanner-aci-topic" \
  --metric "DeliverySuccessCount,DeliveryFailedCount" \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ)
```

## Troubleshooting

### Function App Not Receiving Events

**Issue**: Event Grid events not triggering function

**Solutions**:
1. Verify Event Grid subscription is active:
   ```bash
   az eventgrid system-topic event-subscription show \
     --name aci-container-deployments \
     --resource-group qualys-scanner-prod \
     --system-topic-name qualys-scanner-aci-topic \
     --query provisioningState
   ```

2. Check function app system key:
   ```bash
   az functionapp keys list \
     --name $FUNCTION_APP_NAME \
     --resource-group qualys-scanner-prod
   ```

3. Review Event Grid delivery failures:
   ```bash
   az monitor metrics list \
     --resource "<event-grid-topic-id>" \
     --metric "DeliveryFailedCount"
   ```

### Qualys API Authentication Errors

**Issue**: 401 Unauthorized errors from Qualys API

**Solutions**:
1. Verify credentials in Key Vault:
   ```bash
   az keyvault secret show \
     --vault-name <keyvault-name> \
     --name QualysUsername

   az keyvault secret show \
     --vault-name <keyvault-name> \
     --name QualysPassword
   ```

2. Test Qualys API directly:
   ```bash
   curl -u "$QUALYS_USERNAME:$QUALYS_PASSWORD" \
     "$QUALYS_API_URL/api/2.0/fo/about/"
   ```

3. Check Key Vault access policies:
   ```bash
   az keyvault show \
     --name <keyvault-name> \
     --query "properties.accessPolicies"
   ```

### Scan Timeouts

**Issue**: Scans timing out before completion

**Solutions**:
1. Increase scan timeout in function app settings:
   ```bash
   az functionapp config appsettings set \
     --name $FUNCTION_APP_NAME \
     --resource-group qualys-scanner-prod \
     --settings "SCAN_TIMEOUT=3600"
   ```

2. Increase function timeout (Premium plans):
   ```bash
   # Edit host.json
   {
     "functionTimeout": "00:30:00"
   }
   ```

### Storage Access Errors

**Issue**: Unable to save scan results to storage

**Solutions**:
1. Verify storage account firewall rules:
   ```bash
   az storage account show \
     --name <storage-account-name> \
     --query "networkRuleSet"
   ```

2. Check function app managed identity has storage permissions:
   ```bash
   az role assignment list \
     --assignee <function-app-principal-id> \
     --scope "/subscriptions/<sub-id>/resourceGroups/qualys-scanner-prod/providers/Microsoft.Storage/storageAccounts/<storage-account-name>"
   ```

## Monitoring and Maintenance

### Daily Checks

```bash
# Check function execution count
az monitor metrics list \
  --resource "/subscriptions/<sub-id>/resourceGroups/qualys-scanner-prod/providers/Microsoft.Web/sites/$FUNCTION_APP_NAME" \
  --metric "FunctionExecutionCount" \
  --start-time $(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)

# Review error logs
az monitor app-insights query \
  --app $FUNCTION_APP_NAME \
  --analytics-query "exceptions | where timestamp > ago(24h) | summarize count() by problemId"
```

### Weekly Reviews

- Review scan results for trending vulnerabilities
- Check storage utilization
- Review and update security policies
- Verify backup and retention policies

### Monthly Tasks

- Update function app dependencies
- Review and optimize costs
- Update Qualys scanner configurations
- Test disaster recovery procedures

## Rollback Procedure

If issues occur after deployment:

```bash
# List deployments
az deployment group list \
  --resource-group qualys-scanner-prod \
  --query "[].{name:name, timestamp:properties.timestamp}" \
  --output table

# Rollback to previous deployment
az deployment group create \
  --name "rollback-$(date +%Y%m%d)" \
  --resource-group qualys-scanner-prod \
  --mode Complete \
  --template-file <previous-deployment-template>
```

## Support

For issues or questions:
- Review logs in Application Insights
- Check Azure status page: https://status.azure.com
- Qualys support: https://www.qualys.com/support/
- GitHub Issues: <repository-issues-url>
