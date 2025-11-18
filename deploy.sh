#!/bin/bash
# Single-command deployment script
# Orchestrates Bicep deployment + function code deployment

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"
LOCATION="${LOCATION:-eastus}"
QUALYS_TOKEN="${QUALYS_TOKEN:-}"
QUALYS_POD="${QUALYS_POD:-US2}"
FUNCTION_SKU="${FUNCTION_SKU:-EP1}"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-}"
SCAN_CACHE_HOURS="${SCAN_CACHE_HOURS:-24}"

if [ -z "$QUALYS_TOKEN" ]; then
  echo "ERROR: QUALYS_TOKEN environment variable not set"
  echo "Usage: export QUALYS_TOKEN='...' && ./deploy.sh"
  exit 1
fi

echo "Deploying Qualys Container Scanner"
echo "Resource Group: $RG"
echo "Location: $LOCATION"
echo "Qualys POD: $QUALYS_POD"
echo "Function SKU: $FUNCTION_SKU"
echo ""

# Step 1: Create resource group
echo "[1/4] Creating resource group"
az group create --name "$RG" --location "$LOCATION" --output none

# Step 2: Deploy infrastructure
echo "[2/4] Deploying infrastructure (Function App, Storage, Key Vault, Event Grid Topic)"
az deployment group create \
  --resource-group "$RG" \
  --template-file infrastructure/main.bicep \
  --parameters location="$LOCATION" \
  --parameters qualysPod="$QUALYS_POD" \
  --parameters qualysAccessToken="$QUALYS_TOKEN" \
  --parameters functionAppSku="$FUNCTION_SKU" \
  --parameters notificationEmail="$NOTIFICATION_EMAIL" \
  --parameters scanCacheHours="$SCAN_CACHE_HOURS" \
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
EVENT_GRID_TOPIC=$(az eventgrid system-topic list --resource-group "$RG" --query "[0].name" -o tsv)
az deployment group create \
  --resource-group "$RG" \
  --template-file infrastructure/eventgrid.bicep \
  --parameters functionAppName="$FUNCTION_APP" \
  --parameters eventGridTopicName="$EVENT_GRID_TOPIC" \
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
