# Tenant-Wide Container Scanning

This guide explains how to deploy Qualys container scanning across your entire Azure tenant.

## Overview

Tenant-wide scanning monitors ALL subscriptions in your Azure tenant for ACI and ACA deployments. When any container is deployed in any subscription, it automatically triggers a scan.

### Architecture

```
Any Subscription → Container Deployment → Management Group Event Grid → Function App → Scan
```

Event Grid subscriptions are created at the Management Group level, which allows monitoring all child subscriptions.

## Deployment

### Step 1: Deploy Function App

Deploy the scanner infrastructure to a central subscription:

```bash
cd infrastructure

export QUALYS_USERNAME="your-username"
export QUALYS_PASSWORD="your-password"

./deploy.sh \
  -s central-subscription-id \
  -r qualys-scanner-rg \
  -l eastus \
  -n "$QUALYS_USERNAME" \
  -w "$QUALYS_PASSWORD" \
  -e security@example.com
```

This creates the Function App, Storage, Key Vault, and Application Insights in a central subscription.

### Step 2: Get Management Group ID

For entire tenant:

```bash
TENANT_ROOT=$(az account management-group list \
  --query "[?displayName=='Tenant Root Group'].name" -o tsv)

echo "Tenant Root Management Group: $TENANT_ROOT"
```

For specific business unit:

```bash
az account management-group list

# Use a specific management group ID
MGMT_GROUP="production-workloads"
```

### Step 3: Deploy Tenant-Wide Event Grid

```bash
FUNCTION_APP=$(az functionapp list \
  --resource-group qualys-scanner-rg \
  --subscription central-subscription-id \
  --query "[0].name" -o tsv)

./deploy-tenant-wide.sh \
  -m "$TENANT_ROOT" \
  -s central-subscription-id \
  -r qualys-scanner-rg \
  -f "$FUNCTION_APP"
```

This creates Event Grid subscriptions at the management group level that monitor ALL subscriptions.

## How It Works

### Event Flow

1. User deploys container to ACI or ACA in ANY subscription
2. Azure emits deployment event
3. Management Group scoped Event Grid captures event
4. Event forwarded to Function App
5. Function extracts subscription ID from event
6. Scanner creates ACI container in the central subscription
7. Scan results stored with source subscription metadata

### Cross-Subscription Scanning

The function automatically handles cross-subscription scenarios:

```python
# Event contains source subscription ID
event_subscription_id = event_data.get('subscriptionId')

# Scanner uses central subscription for scan containers
scanner = QScannerACI(subscription_id=central_subscription_id)

# Results tagged with source subscription
custom_tags = {
    'source_subscription': event_subscription_id,
    'container_type': 'ACI',
    'resource_group': resource_group
}
```

## Permissions Required

### Function App Managed Identity

Grant the Function App permissions across subscriptions:

For tenant-wide scanning, the managed identity needs:
- Contributor on the resource group where scan containers run
- Key Vault Secrets User for credentials

For cross-subscription ACR access:

```bash
PRINCIPAL_ID=$(az functionapp identity show \
  --name $FUNCTION_APP \
  --resource-group qualys-scanner-rg \
  --query principalId -o tsv)

# Grant AcrPull across all subscriptions with ACR
for SUB in $(az account list --query "[].id" -o tsv); do
  for ACR in $(az acr list --subscription $SUB --query "[].id" -o tsv); do
    az role assignment create \
      --assignee $PRINCIPAL_ID \
      --role AcrPull \
      --scope $ACR
  done
done
```

### Deployment User

The user deploying tenant-wide Event Grid needs:
- Read access on target management group
- Ability to create Event Grid subscriptions at management group scope

Typically requires one of:
- Owner or Contributor at management group level
- Custom role with Microsoft.EventGrid/eventSubscriptions/write permission

## Monitoring

### View Covered Subscriptions

```bash
az account management-group show \
  --name $TENANT_ROOT \
  --expand \
  --recurse \
  --query "children[?type=='Microsoft.Management/managementGroups/subscriptions'].{Name:displayName, ID:name}"
```

### Verify Event Grid Subscriptions

```bash
az eventgrid event-subscription list \
  --source-resource-id /providers/Microsoft.Management/managementGroups/$TENANT_ROOT
```

### Track Scans Across Subscriptions

Application Insights query:

```kusto
traces
| where customDimensions.EventType == "ContainerScan"
| extend SourceSubscription = tostring(customDimensions.azure_subscription)
| summarize ScanCount = count() by SourceSubscription
| order by ScanCount desc
```

Storage Table query for specific subscription:

```bash
az storage entity query \
  --account-name <storage-account> \
  --table-name ScanMetadata \
  --filter "PartitionKey eq 'subscription-id'"
```

## Cost Considerations

Tenant-wide scanning costs scale with deployment frequency:

- Function executions: Free tier covers 1M requests/month
- ACI scan containers: ~$0.001 per scan
- Storage: Scales with number of unique images scanned
- Event Grid: $0.60 per million operations

Example for tenant with 10 subscriptions, 100 deployments/day total:
- ACI scans: 100 * 30 * $0.001 = $3/month
- Function: Covered by free tier
- Storage: ~$5/month
- Total: ~$8/month

Costs remain similar to single-subscription deployment because scans happen on-demand.

## Filtering

### Monitor Specific Subscriptions Only

Instead of tenant root, use a management group containing only target subscriptions:

```bash
./deploy-tenant-wide.sh \
  -m "production-subscriptions-mg" \
  -s central-subscription-id \
  -r qualys-scanner-rg \
  -f $FUNCTION_APP
```

### Exclude Subscriptions

Create a management group structure that excludes certain subscriptions, or add filtering in the function:

```python
# In EventProcessor/__init__.py
EXCLUDED_SUBSCRIPTIONS = os.environ.get('EXCLUDED_SUBSCRIPTIONS', '').split(',')

if event_subscription_id in EXCLUDED_SUBSCRIPTIONS:
    logging.info(f'Skipping scan for excluded subscription: {event_subscription_id}')
    return
```

## Troubleshooting

### Events Not Received from Some Subscriptions

Check Event Grid subscription status:

```bash
az eventgrid event-subscription show \
  --name qualys-scanner-aci-tenant-wide \
  --source-resource-id /providers/Microsoft.Management/managementGroups/$TENANT_ROOT
```

Verify management group hierarchy includes the subscription:

```bash
az account management-group show --name $TENANT_ROOT --expand --recurse
```

### Permission Errors Creating Scan Containers

Function App needs Contributor role on the resource group where it creates scan containers. This is in the central subscription, not source subscriptions.

Verify:

```bash
az role assignment list \
  --assignee $PRINCIPAL_ID \
  --scope /subscriptions/central-subscription-id/resourceGroups/qualys-scanner-rg
```

### Cannot Access Private Registry in Different Subscription

Grant AcrPull to Function App identity on the specific ACR:

```bash
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role AcrPull \
  --scope /subscriptions/other-subscription-id/resourceGroups/rg/providers/Microsoft.ContainerRegistry/registries/acr
```

## Migration from Single Subscription

If you already have single-subscription deployment:

1. Keep existing Function App deployment
2. Deploy tenant-wide Event Grid subscriptions
3. The function automatically handles events from any subscription
4. Optionally remove single-subscription Event Grid subscriptions

```bash
# Remove subscription-scoped Event Grid
az eventgrid system-topic event-subscription delete \
  --name aci-container-deployments \
  --resource-group qualys-scanner-rg \
  --system-topic-name qscan-aci-topic
```

## Best Practices

1. Deploy Function App to a dedicated management subscription
2. Use tenant root management group for complete coverage
3. Grant ACR access proactively across subscriptions
4. Set up alerts for scan failures
5. Monitor Event Grid delivery metrics
6. Implement tag-based filtering for large tenants
7. Use Premium Function plan for high-volume tenants

## Security

- Event Grid subscriptions use Function system keys for authentication
- Function App managed identity for all resource access
- Scan containers run in central subscription, isolated from source workloads
- Cross-subscription access uses RBAC (no credentials exchanged)
- All events and scans logged to Application Insights
