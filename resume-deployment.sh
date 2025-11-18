#!/bin/bash
# Resume deployment after timeout
# Completes function code deployment and Event Grid subscriptions

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"

echo "Resuming deployment..."
echo ""

FUNCTION_APP=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv)
if [ -z "$FUNCTION_APP" ]; then
  echo "ERROR: No function app found. Infrastructure may not be deployed."
  exit 1
fi

echo "Function App: $FUNCTION_APP"
echo ""

# Retry function code deployment
echo "[1/2] Deploying function code (retry)"
cd function_app
func azure functionapp publish "$FUNCTION_APP" --python --build remote
cd ..
echo ""

# Deploy Event Grid subscriptions
echo "[2/2] Deploying Event Grid subscriptions"
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
