#!/bin/bash
# Single-command deployment script
# Orchestrates Bicep deployment + function code deployment

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"
LOCATION="${LOCATION:-eastus}"
QUALYS_TOKEN="${QUALYS_TOKEN:-}"

if [ -z "$QUALYS_TOKEN" ]; then
  echo "ERROR: QUALYS_TOKEN environment variable not set"
  echo "Usage: export QUALYS_TOKEN='...' && ./deploy.sh"
  exit 1
fi

echo "Deploying Qualys Container Scanner"
echo "Resource Group: $RG"
echo "Location: $LOCATION"
echo ""

# Step 1: Create resource group
echo "[1/4] Creating resource group"
az group create --name "$RG" --location "$LOCATION" --output none

# Step 2: Deploy infrastructure
echo "[2/4] Deploying infrastructure (Function App, Storage, Key Vault, Event Grid Topic)"
az deployment group create \
  --resource-group "$RG" \
  --template-file infrastructure/deploy.bicep \
  --parameters infrastructure/deploy.bicepparam \
  --parameters qualysAccessToken="$QUALYS_TOKEN" \
  --parameters deployEventGridSubscriptions=false \
  --output none

FUNCTION_APP=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv)
echo "Function App: $FUNCTION_APP"
echo ""

# Step 3: Deploy function code
echo "[3/4] Deploying function code"
cd function_app
func azure functionapp publish "$FUNCTION_APP" --python --build remote
cd ..
echo ""

# Step 4: Deploy Event Grid subscriptions
echo "[4/4] Deploying Event Grid subscriptions"
az deployment group create \
  --resource-group "$RG" \
  --template-file infrastructure/deploy.bicep \
  --parameters infrastructure/deploy.bicepparam \
  --parameters qualysAccessToken="$QUALYS_TOKEN" \
  --parameters deployEventGridSubscriptions=true \
  --output none
echo ""

echo "Deployment complete"
echo ""
echo "Function App: $FUNCTION_APP"
echo "Key Vault: $(az keyvault list --resource-group $RG --query "[0].name" -o tsv)"
echo "Storage: $(az storage account list --resource-group $RG --query "[0].name" -o tsv)"
echo "ACR: $(az acr list --resource-group $RG --query "[0].name" -o tsv)"
echo ""
echo "Container deployments in this resource group will now be automatically scanned."
echo "Test with: ./test-automation.sh"
