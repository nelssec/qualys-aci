# Multi-Tenant Deployment Considerations

This document covers multi-tenant and multi-subscription deployment scenarios for the Qualys Container Scanner.

## Terminology

- **Subscription**: An Azure subscription that may contain containerized workloads
- **Tenant**: An Azure Active Directory (Azure AD) tenant that owns one or more subscriptions
- **Multi-Subscription**: Multiple Azure subscriptions within the same or different Azure AD tenants
- **Multi-Tenant**: Multiple Azure AD tenants, each potentially containing multiple subscriptions

## Supported Configurations

### Single Tenant, Single Subscription

This is the standard deployment mode using `deploy.sh` or `main.bicep`.

**Configuration:**
- All resources in one subscription
- All resources in one Azure AD tenant
- Function app uses system-assigned managed identity with Reader and AcrPull roles

**Works with:**
- Any ACR in the same subscription
- Any ACI/ACA in the same subscription

### Single Tenant, Multi-Subscription

This is the enterprise deployment mode using `deploy-multi.sh` and `add-spoke.sh`.

**Configuration:**
- Central subscription with function app, Event Hub, storage
- One or more spoke subscriptions sending Activity Log to central Event Hub
- All subscriptions in the same Azure AD tenant
- Function app managed identity granted Reader and AcrPull in all subscriptions

**Works with:**
- Any ACR in any configured subscription
- Any ACI/ACA in any configured subscription
- All subscriptions must be in the same tenant

## Multi-Tenant Limitations

The current implementation has limitations when dealing with resources across different Azure AD tenants.

### Authentication Scope

The function app uses a system-assigned managed identity that belongs to a single Azure AD tenant. This identity can only authenticate to resources in subscriptions that belong to the same tenant.

**Scenario:** Central subscription in Tenant A, spoke subscription in Tenant B

**Problem:**
1. Function app managed identity is created in Tenant A
2. Spoke subscription ACRs belong to Tenant B
3. Managed identity from Tenant A cannot authenticate to ACRs in Tenant B
4. Scans will fail with authentication errors

### Current Tenant Configuration

The deployment sets `AZURE_TENANT_ID` to the tenant ID of the subscription where the function app is deployed:

```bicep
{
  name: 'AZURE_TENANT_ID'
  value: subscription().tenantId
}
```

This works fine when all subscriptions are in the same tenant. For true multi-tenant support, additional configuration is required.

## Cross-Tenant Workarounds

If you need to scan containers across multiple Azure AD tenants, consider these approaches:

### Option 1: Service Principal with Multi-Tenant Access

Instead of using managed identity, configure a service principal with permissions in multiple tenants:

1. Create a multi-tenant application registration in the primary tenant
2. Grant the service principal Reader and AcrPull roles in each subscription (across tenants)
3. Configure the function app with service principal credentials instead of managed identity
4. Update the scanner code to use ClientSecretCredential instead of DefaultAzureCredential

**Drawbacks:**
- Requires managing service principal credentials (secrets or certificates)
- Increases security complexity
- Not currently implemented in this codebase

### Option 2: Lighthouse Delegation

Use Azure Lighthouse to delegate resource management across tenants:

1. Configure Azure Lighthouse delegation from spoke tenants to the central tenant
2. Grant the function app's managed identity delegated access via Lighthouse
3. Update RBAC assignments through Lighthouse

**Drawbacks:**
- Requires Lighthouse setup for each tenant relationship
- Additional administrative overhead
- May not be suitable for all organizational structures

### Option 3: Deploy Per Tenant

Deploy a separate scanner instance in each Azure AD tenant:

1. Deploy central.bicep in Tenant A for subscriptions in Tenant A
2. Deploy central.bicep in Tenant B for subscriptions in Tenant B
3. Each scanner monitors only subscriptions within its tenant
4. Aggregate results in Qualys dashboard using custom tags

**Advantages:**
- Simple deployment model
- No cross-tenant authentication issues
- Each tenant maintains control over their scanner

**Drawbacks:**
- Multiple function apps to manage
- Duplicate infrastructure costs
- Separate deployment and maintenance processes

## Recommended Approach

For most organizations, we recommend:

1. **Single tenant**: Use the standard multi-subscription deployment
2. **Multiple tenants**: Deploy a separate scanner instance per tenant (Option 3)
3. **Rare cross-tenant needs**: Implement service principal authentication (Option 1)

The per-tenant deployment model provides the best balance of simplicity, security, and maintainability.

## Validation

To verify your deployment works across your subscriptions, check these items:

### Verify Tenant Alignment

```bash
# Check central subscription tenant
az account show --subscription <central-sub-id> --query tenantId -o tsv

# Check spoke subscription tenant
az account show --subscription <spoke-sub-id> --query tenantId -o tsv
```

Both should return the same tenant ID.

### Verify Managed Identity Access

```bash
# Get function app principal ID
PRINCIPAL_ID=$(az functionapp show \
  --resource-group qualys-scanner-rg \
  --name <function-app-name> \
  --query identity.principalId -o tsv)

# Check role assignments in spoke subscription
az account set --subscription <spoke-sub-id>
az role assignment list --assignee $PRINCIPAL_ID \
  --query "[].{Role:roleDefinitionName, Scope:scope}" -o table
```

You should see Reader and AcrPull roles assigned.

### Test Cross-Subscription Scanning

Deploy a test container in a spoke subscription:

```bash
az account set --subscription <spoke-sub-id>
az container create \
  --resource-group test-rg \
  --name test-scan-$(date +%s) \
  --image mcr.microsoft.com/dotnet/runtime:8.0 \
  --os-type Linux \
  --cpu 1 --memory 1 \
  --restart-policy Never
```

Monitor the function logs to confirm the scan executes successfully:

```bash
az monitor app-insights query \
  --app <app-insights-id> \
  --analytics-query "traces | where timestamp > ago(10m) | where message contains 'SCAN' | order by timestamp desc" \
  --offset 1h
```

## Future Enhancements

Potential improvements for better multi-tenant support:

1. Add tenant ID mapping in Table Storage to support per-subscription tenant configuration
2. Implement service principal authentication as an alternative to managed identity
3. Add Azure Lighthouse integration for cross-tenant delegation
4. Create deployment scripts that automatically detect and warn about tenant mismatches
5. Support for tenant-specific Qualys credentials if using multiple Qualys subscriptions

If you need any of these enhancements, please open an issue with your specific use case.
