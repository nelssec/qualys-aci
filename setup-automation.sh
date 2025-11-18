#!/bin/bash
# Setup and verify automated container scanning
# This script updates the Qualys token and verifies the automation is working

set -e

RG="qualys-scanner-rg"

echo "==========================================="
echo "  Qualys Container Scanning Automation"
echo "==========================================="
echo ""

# Check if QUALYS_TOKEN is provided
if [ -z "$QUALYS_TOKEN" ]; then
  echo "ERROR: QUALYS_TOKEN environment variable not set"
  echo ""
  echo "Usage:"
  echo "  export QUALYS_TOKEN='your-token-here'"
  echo "  ./setup-automation.sh"
  exit 1
fi

echo "=== Step 1: Updating Qualys Token in Key Vault ==="
KV_NAME=$(az keyvault list --resource-group $RG --query "[0].name" -o tsv)
echo "Key Vault: $KV_NAME"

echo "Storing QUALYS_ACCESS_TOKEN in Key Vault..."
az keyvault secret set \
  --vault-name "$KV_NAME" \
  --name "QualysAccessToken" \
  --value "$QUALYS_TOKEN" \
  --output none

echo "✓ Token updated successfully"
echo ""

echo "=== Step 2: Verifying Function App Configuration ==="
FUNCTION_APP=$(az functionapp list --resource-group $RG --query "[0].name" -o tsv)
echo "Function App: $FUNCTION_APP"

# Check critical environment variables
echo ""
echo "Checking environment variables..."
QUALYS_POD=$(az functionapp config appsettings list \
  --resource-group $RG \
  --name "$FUNCTION_APP" \
  --query "[?name=='QUALYS_POD'].value" -o tsv)

QSCANNER_IMAGE=$(az functionapp config appsettings list \
  --resource-group $RG \
  --name "$FUNCTION_APP" \
  --query "[?name=='QSCANNER_IMAGE'].value" -o tsv)

echo "  QUALYS_POD: $QUALYS_POD"
echo "  QSCANNER_IMAGE: $QSCANNER_IMAGE"
echo "  QUALYS_ACCESS_TOKEN: [configured from Key Vault]"
echo ""

if [ -z "$QUALYS_POD" ]; then
  echo "WARNING: QUALYS_POD is not set. Scanning will fail."
  echo "Set it with: az functionapp config appsettings set --name $FUNCTION_APP --resource-group $RG --settings QUALYS_POD=US2"
fi

echo "✓ Function App configured"
echo ""

echo "=== Step 3: Checking Event Grid Setup ==="
EVENT_GRID_TOPIC=$(az eventgrid system-topic list --resource-group $RG --query "[0].name" -o tsv)
echo "Event Grid Topic: $EVENT_GRID_TOPIC"

# Check if subscriptions exist
SUBSCRIPTIONS=$(az eventgrid system-topic event-subscription list \
  --resource-group $RG \
  --system-topic-name "$EVENT_GRID_TOPIC" \
  --query "length([])" -o tsv)

if [ "$SUBSCRIPTIONS" = "0" ]; then
  echo ""
  echo "⚠ No Event Grid subscriptions found!"
  echo "Deploying Event Grid subscriptions..."
  ./deploy-eventgrid.sh
else
  echo ""
  echo "Event Grid subscriptions:"
  az eventgrid system-topic event-subscription list \
    --resource-group $RG \
    --system-topic-name "$EVENT_GRID_TOPIC" \
    --query "[].{Name:name, State:provisioningState}" \
    --output table
  echo "✓ Event Grid configured"
fi

echo ""
echo "=== Step 4: Deploying Latest Function Code ==="
echo "Deploying function code to Azure..."
./deploy-function.sh

echo ""
echo "=== Setup Complete! ==="
echo ""
echo "Your container scanning automation is now active!"
echo ""
echo "How it works:"
echo "  1. Deploy any container to this resource group"
echo "  2. Event Grid detects the deployment"
echo "  3. EventProcessor function is triggered automatically"
echo "  4. QScanner runs in ACI and scans the container image"
echo "  5. Results are uploaded to Qualys and stored in Azure Storage"
echo ""
echo "To test the automation:"
echo "  ./test-automation.sh"
echo ""
echo "To view logs:"
echo "  az monitor app-insights query \\"
echo "    --app $(az monitor app-insights component show --resource-group $RG --query '[0].name' -o tsv) \\"
echo "    --analytics-query 'traces | where message contains \"qscanner\" | order by timestamp desc | take 50' \\"
echo "    --output table"
echo ""
