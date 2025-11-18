#!/bin/bash
# Single-command deployment script
# Orchestrates Bicep deployment + function code deployment

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"
LOCATION="${LOCATION:-eastus}"
QUALYS_ACCESS_TOKEN="${QUALYS_ACCESS_TOKEN:-}"
QUALYS_POD="${QUALYS_POD:-US2}"
FUNCTION_SKU="${FUNCTION_SKU:-EP1}"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-}"
SCAN_CACHE_HOURS="${SCAN_CACHE_HOURS:-24}"

if [ -z "$QUALYS_ACCESS_TOKEN" ]; then
  echo "ERROR: QUALYS_ACCESS_TOKEN environment variable not set"
  echo "Usage: export QUALYS_ACCESS_TOKEN='...' && ./deploy.sh"
  exit 1
fi

echo "Deploying Qualys Container Scanner"
echo "Resource Group: $RG"
echo "Location: $LOCATION"
echo "Qualys POD: $QUALYS_POD"
echo "Function SKU: $FUNCTION_SKU"
echo ""

echo "[1/4] Creating resource group"
az group create --name "$RG" --location "$LOCATION" --output none

echo "[2/4] Deploying infrastructure"
az deployment group create \
  --resource-group "$RG" \
  --template-file infrastructure/main.bicep \
  --parameters location="$LOCATION" \
  --parameters qualysPod="$QUALYS_POD" \
  --parameters qualysAccessToken="$QUALYS_ACCESS_TOKEN" \
  --parameters functionAppSku="$FUNCTION_SKU" \
  --parameters notificationEmail="$NOTIFICATION_EMAIL" \
  --parameters scanCacheHours="$SCAN_CACHE_HOURS" \
  --output none

FUNCTION_APP=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv)
echo "Function App: $FUNCTION_APP"
echo ""

echo "[3/4] Deploying function code"
echo "This may take 5-10 minutes..."
cd function_app

if timeout 600 func azure functionapp publish "$FUNCTION_APP" --python --build remote 2>&1; then
  echo "Function code deployed successfully"
else
  EXIT_CODE=$?
  if [ $EXIT_CODE -eq 124 ]; then
    echo ""
    echo "WARNING: Deployment timed out waiting for SCM, but may have succeeded in background"
    echo "Waiting 30 seconds for deployment to complete..."
    sleep 30

    STATE=$(az functionapp show --resource-group "$RG" --name "$FUNCTION_APP" --query "state" -o tsv)
    if [ "$STATE" = "Running" ]; then
      echo "Function app is running - deployment likely succeeded"
    else
      echo "Function app state: $STATE - you may need to restart it"
      echo "Run: az functionapp restart --resource-group $RG --name $FUNCTION_APP"
    fi
  else
    echo "ERROR: Function deployment failed with exit code $EXIT_CODE"
    cd ..
    exit 1
  fi
fi

cd ..
echo ""

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
echo "Subscription-wide monitoring is now active."
echo "All container deployments across this subscription will be automatically scanned."
echo ""
echo "Test by deploying a container:"
echo "  az container create --resource-group $RG --name test-scan --image mcr.microsoft.com/dotnet/runtime:8.0 --os-type Linux --restart-policy Never"
