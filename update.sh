#!/bin/bash
# Update existing deployment without recreating infrastructure
# Use this when infrastructure already exists

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"

echo "Updating Qualys Container Scanner"
echo "Resource Group: $RG"
echo ""

# Check if resources exist
FUNCTION_APP=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv 2>/dev/null || echo "")
if [ -z "$FUNCTION_APP" ]; then
  echo "ERROR: No function app found in $RG"
  echo "Run ./deploy.sh for initial deployment"
  exit 1
fi

echo "Function App: $FUNCTION_APP"
echo ""

# Step 1: Deploy function code
echo "[1/2] Deploying function code"
cd function_app
func azure functionapp publish "$FUNCTION_APP" --python --build remote
cd ..
echo ""

# Step 2: Deploy Event Grid subscriptions (idempotent)
echo "[2/2] Deploying Event Grid subscriptions"
EVENT_GRID_TOPIC=$(az eventgrid system-topic list --resource-group "$RG" --query "[0].name" -o tsv)
az deployment group create \
  --resource-group "$RG" \
  --template-file infrastructure/eventgrid.bicep \
  --parameters functionAppName="$FUNCTION_APP" \
  --parameters eventGridTopicName="$EVENT_GRID_TOPIC" \
  --output none
echo ""

echo "Update complete"
echo ""
echo "Test with: ./test-automation.sh"
