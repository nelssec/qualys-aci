#!/bin/bash
# Check RBAC role assignments for Function App managed identity

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"

echo "Checking RBAC Role Assignments"
echo "=============================="
echo ""

# Get Function App managed identity
FUNCTION_APP=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv)
if [ -z "$FUNCTION_APP" ]; then
  echo "ERROR: No function app found"
  exit 1
fi

PRINCIPAL_ID=$(az functionapp show \
  --resource-group "$RG" \
  --name "$FUNCTION_APP" \
  --query "identity.principalId" -o tsv)

if [ -z "$PRINCIPAL_ID" ]; then
  echo "ERROR: Function app has no managed identity"
  exit 1
fi

echo "Function App: $FUNCTION_APP"
echo "Managed Identity Principal ID: $PRINCIPAL_ID"
echo ""

# Check resource group level roles
echo "1. Resource Group Roles:"
az role assignment list \
  --assignee "$PRINCIPAL_ID" \
  --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG" \
  --query "[].{Role:roleDefinitionName, Scope:scope}" \
  -o table

echo ""

# Check Key Vault roles
KV_NAME=$(az keyvault list --resource-group "$RG" --query "[0].name" -o tsv)
if [ -n "$KV_NAME" ]; then
  echo "2. Key Vault Roles ($KV_NAME):"
  az role assignment list \
    --assignee "$PRINCIPAL_ID" \
    --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/$KV_NAME" \
    --query "[].{Role:roleDefinitionName, Scope:scope}" \
    -o table
  echo ""
fi

# Check ACR roles
ACR_NAME=$(az acr list --resource-group "$RG" --query "[0].name" -o tsv)
if [ -n "$ACR_NAME" ]; then
  echo "3. Container Registry Roles ($ACR_NAME):"
  az role assignment list \
    --assignee "$PRINCIPAL_ID" \
    --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME" \
    --query "[].{Role:roleDefinitionName, Scope:scope}" \
    -o table
  echo ""
fi

# Summary
echo ""
echo "Expected Roles:"
echo "  - Contributor (Resource Group) - Required to create/delete ACI containers"
echo "  - Key Vault Secrets User (Key Vault) - Required to read Qualys token"
echo "  - AcrPull (ACR) - Required to pull qscanner image"
echo ""

# Check if all required roles are present
HAS_CONTRIBUTOR=$(az role assignment list \
  --assignee "$PRINCIPAL_ID" \
  --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG" \
  --query "[?roleDefinitionName=='Contributor'].roleDefinitionName" -o tsv)

HAS_KV_SECRETS_USER=$(az role assignment list \
  --assignee "$PRINCIPAL_ID" \
  --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/$KV_NAME" \
  --query "[?roleDefinitionName=='Key Vault Secrets User'].roleDefinitionName" -o tsv)

HAS_ACR_PULL=$(az role assignment list \
  --assignee "$PRINCIPAL_ID" \
  --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME" \
  --query "[?roleDefinitionName=='AcrPull'].roleDefinitionName" -o tsv)

ERRORS=0

if [ -z "$HAS_CONTRIBUTOR" ]; then
  echo "ERROR: Missing Contributor role on resource group"
  ERRORS=$((ERRORS+1))
else
  echo "OK: Contributor role assigned"
fi

if [ -z "$HAS_KV_SECRETS_USER" ]; then
  echo "ERROR: Missing Key Vault Secrets User role"
  ERRORS=$((ERRORS+1))
else
  echo "OK: Key Vault Secrets User role assigned"
fi

if [ -z "$HAS_ACR_PULL" ]; then
  echo "ERROR: Missing AcrPull role"
  ERRORS=$((ERRORS+1))
else
  echo "OK: AcrPull role assigned"
fi

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "Status: All required roles are properly assigned"
  exit 0
else
  echo "Status: $ERRORS missing role assignment(s)"
  echo ""
  echo "To fix, redeploy infrastructure:"
  echo "  export QUALYS_TOKEN='your-token' && ./deploy.sh"
  exit 1
fi
