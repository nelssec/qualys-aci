#!/bin/bash
# Debug script: Setup and verify automated container scanning
# Updates Qualys token and verifies automation configuration

set -e

RG="qualys-scanner-rg"

if [ -z "$QUALYS_TOKEN" ]; then
  echo "ERROR: QUALYS_TOKEN environment variable not set"
  echo "Usage: export QUALYS_TOKEN='...' && ./setup-automation.sh"
  exit 1
fi

echo "Updating Qualys Token in Key Vault"
KV_NAME=$(az keyvault list --resource-group $RG --query "[0].name" -o tsv)
az keyvault secret set \
  --vault-name "$KV_NAME" \
  --name "QualysAccessToken" \
  --value "$QUALYS_TOKEN" \
  --output none
echo "Token updated: $KV_NAME"
echo ""

echo "Verifying Function App Configuration"
FUNCTION_APP=$(az functionapp list --resource-group $RG --query "[0].name" -o tsv)
QUALYS_POD=$(az functionapp config appsettings list \
  --resource-group $RG \
  --name "$FUNCTION_APP" \
  --query "[?name=='QUALYS_POD'].value" -o tsv)

QSCANNER_IMAGE=$(az functionapp config appsettings list \
  --resource-group $RG \
  --name "$FUNCTION_APP" \
  --query "[?name=='QSCANNER_IMAGE'].value" -o tsv)

echo "Function App: $FUNCTION_APP"
echo "QUALYS_POD: $QUALYS_POD"
echo "QSCANNER_IMAGE: $QSCANNER_IMAGE"

if [ -z "$QUALYS_POD" ]; then
  echo "WARNING: QUALYS_POD not set"
fi
echo ""

echo "Checking Event Grid Setup"
EVENT_GRID_TOPIC=$(az eventgrid system-topic list --resource-group $RG --query "[0].name" -o tsv)
SUBSCRIPTIONS=$(az eventgrid system-topic event-subscription list \
  --resource-group $RG \
  --system-topic-name "$EVENT_GRID_TOPIC" \
  --query "length([])" -o tsv)

echo "Event Grid Topic: $EVENT_GRID_TOPIC"
echo "Subscriptions: $SUBSCRIPTIONS"

if [ "$SUBSCRIPTIONS" = "0" ]; then
  echo "WARNING: No Event Grid subscriptions found"
  echo "Run: ./deploy-eventgrid.sh"
else
  az eventgrid system-topic event-subscription list \
    --resource-group $RG \
    --system-topic-name "$EVENT_GRID_TOPIC" \
    --query "[].{Name:name, State:provisioningState}" \
    --output table
fi
echo ""

echo "Deploying Function Code"
./deploy-function.sh

echo ""
echo "Setup complete. Test with: ./test-automation.sh"
