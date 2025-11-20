#!/bin/bash
# Multi-subscription deployment for Qualys Container Scanner
# Step 1: Deploy central hub
# Step 2: Add spoke subscriptions

set -e

# Configuration
CENTRAL_SUB="${CENTRAL_SUBSCRIPTION_ID:-}"
RG="${RESOURCE_GROUP:-qualys-scanner-rg}"
LOCATION="${LOCATION:-eastus}"
QUALYS_ACCESS_TOKEN="${QUALYS_ACCESS_TOKEN:-}"
QUALYS_POD="${QUALYS_POD:-US2}"
OUTPUTS_FILE=".deployment-outputs.json"

if [ -z "$QUALYS_ACCESS_TOKEN" ]; then
  echo "ERROR: QUALYS_ACCESS_TOKEN environment variable not set"
  echo "Usage: export QUALYS_ACCESS_TOKEN='...' && export CENTRAL_SUBSCRIPTION_ID='...' && ./deploy-multi.sh"
  exit 1
fi

if [ -z "$CENTRAL_SUB" ]; then
  echo "ERROR: CENTRAL_SUBSCRIPTION_ID environment variable not set"
  echo "This should be the subscription where you want to deploy the central scanner"
  echo "Usage: export CENTRAL_SUBSCRIPTION_ID='...' && ./deploy-multi.sh"
  exit 1
fi

echo "============================================"
echo "Qualys Multi-Subscription Scanner Deployment"
echo "============================================"
echo ""
echo "Central Subscription: $CENTRAL_SUB"
echo "Resource Group: $RG"
echo "Location: $LOCATION"
echo "Qualys POD: $QUALYS_POD"
echo ""

# Deploy central hub
echo "[1/2] Deploying central hub..."
echo "Switching to central subscription: $CENTRAL_SUB"
az account set --subscription "$CENTRAL_SUB"

echo "Deploying infrastructure..."
DEPLOYMENT_OUTPUT=$(az deployment sub create \
  --location "$LOCATION" \
  --template-file infrastructure/central.bicep \
  --parameters location="$LOCATION" \
  --parameters resourceGroupName="$RG" \
  --parameters qualysPod="$QUALYS_POD" \
  --parameters qualysAccessToken="$QUALYS_ACCESS_TOKEN" \
  --query 'properties.outputs' \
  --output json)

if [ $? -ne 0 ]; then
  echo "ERROR: Central hub deployment failed"
  exit 1
fi

# Save outputs for spoke deployments
echo "$DEPLOYMENT_OUTPUT" > "$OUTPUTS_FILE"

# Extract key values
FUNCTION_APP=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.functionAppName.value')
FUNCTION_PRINCIPAL_ID=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.functionAppPrincipalId.value')
EVENT_HUB_NAMESPACE=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.eventHubNamespace.value')
EVENT_HUB_CONN_STRING=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.diagnosticsSendConnectionString.value')

echo ""
echo "Central hub deployed successfully!"
echo "  Function App: $FUNCTION_APP"
echo "  Event Hub Namespace: $EVENT_HUB_NAMESPACE"
echo ""

# Deploy function code
echo "[2/2] Deploying function code..."
cd function_app

if func azure functionapp publish "$FUNCTION_APP" --python --build remote 2>&1; then
  echo "Function code deployed successfully"
else
  EXIT_CODE=$?
  echo "WARNING: Function deployment returned exit code $EXIT_CODE"
  sleep 10
  STATE=$(az functionapp show --resource-group "$RG" --name "$FUNCTION_APP" --query "state" -o tsv)
  if [ "$STATE" = "Running" ]; then
    echo "Function app is running - continuing"
  else
    echo "ERROR: Function app state: $STATE"
    cd ..
    exit 1
  fi
fi

cd ..

echo ""
echo "============================================"
echo "Central Hub Deployment Complete"
echo "============================================"
echo ""
echo "Function App: $FUNCTION_APP"
echo "Key Vault: $(az keyvault list --resource-group $RG --query "[0].name" -o tsv)"
echo "Storage: $(az storage account list --resource-group $RG --query "[0].name" -o tsv)"
echo ""
echo "The central subscription ($CENTRAL_SUB) is now configured."
echo ""
echo "============================================"
echo "Next Steps: Add Spoke Subscriptions"
echo "============================================"
echo ""
echo "To add additional subscriptions, run this for EACH spoke subscription:"
echo ""
echo "  export SPOKE_SUBSCRIPTION_ID='<spoke-subscription-id>'"
echo "  ./add-spoke.sh"
echo ""
echo "Or manually deploy using:"
echo ""
echo "  az account set --subscription <spoke-sub-id>"
echo "  az deployment sub create \\"
echo "    --location $LOCATION \\"
echo "    --template-file infrastructure/spoke.bicep \\"
echo "    --parameters centralSubscriptionId='$CENTRAL_SUB' \\"
echo "    --parameters centralResourceGroupName='$RG' \\"
echo "    --parameters eventHubNamespace='$EVENT_HUB_NAMESPACE' \\"
echo "    --parameters eventHubSendConnectionString='<redacted>' \\"
echo "    --parameters functionAppPrincipalId='$FUNCTION_PRINCIPAL_ID'"
echo ""
echo "Deployment outputs saved to: $OUTPUTS_FILE"
echo ""
echo "Monitor logs:"
echo "  func azure functionapp logstream $FUNCTION_APP"
echo ""
