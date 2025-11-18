#!/bin/bash
# Update Qualys token in Key Vault
# Requires Key Vault Secrets Officer role on the Key Vault

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"
QUALYS_ACCESS_TOKEN="${QUALYS_ACCESS_TOKEN:-}"

if [ -z "$QUALYS_ACCESS_TOKEN" ]; then
  echo "ERROR: QUALYS_ACCESS_TOKEN environment variable not set"
  echo "Usage: export QUALYS_ACCESS_TOKEN='...' && ./update-token.sh"
  exit 1
fi

echo "Updating Qualys Token in Key Vault"
echo "Resource Group: $RG"
echo ""

KV_NAME=$(az keyvault list --resource-group "$RG" --query "[0].name" -o tsv)
if [ -z "$KV_NAME" ]; then
  echo "ERROR: No Key Vault found in $RG"
  exit 1
fi

echo "Key Vault: $KV_NAME"
echo ""

# Check if user has permission
USER_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")
if [ -z "$USER_ID" ]; then
  echo "ERROR: Cannot determine current user identity"
  exit 1
fi

# Try to update the token
echo "Updating token..."
if az keyvault secret set \
  --vault-name "$KV_NAME" \
  --name "QualysAccessToken" \
  --value "$QUALYS_ACCESS_TOKEN" \
  --output none 2>/dev/null; then
  echo "Token updated successfully"
else
  echo ""
  echo "ERROR: Permission denied to update Key Vault secret"
  echo ""
  echo "To grant yourself permission, run:"
  echo ""
  echo "  az role assignment create \\"
  echo "    --role \"Key Vault Secrets Officer\" \\"
  echo "    --assignee $USER_ID \\"
  echo "    --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/$KV_NAME"
  echo ""
  echo "Alternative: Update via Azure Portal:"
  echo "  1. Navigate to Key Vault: $KV_NAME"
  echo "  2. Go to Secrets > QualysAccessToken"
  echo "  3. Create new version with updated token"
  echo ""
  echo "Alternative: Redeploy infrastructure (this will update the token):"
  echo "  export QUALYS_ACCESS_TOKEN='your-token'"
  echo "  ./deploy.sh"
  exit 1
fi

echo ""
echo "Restarting function app to pick up new token..."
FUNCTION_APP=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv)
az functionapp restart --resource-group "$RG" --name "$FUNCTION_APP" --output none

echo "Done"
