#!/bin/bash
# Automated 3-step deployment for Qualys Container Scanner
# For production customers, use the manual Bicep commands in README.md

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"
LOCATION="${LOCATION:-eastus}"
QUALYS_ACCESS_TOKEN="${QUALYS_ACCESS_TOKEN:-}"
QUALYS_POD="${QUALYS_POD:-US2}"

if [ -z "$QUALYS_ACCESS_TOKEN" ]; then
  echo "ERROR: QUALYS_ACCESS_TOKEN environment variable not set"
  echo "Usage: export QUALYS_ACCESS_TOKEN='...' && ./deploy.sh"
  exit 1
fi

echo "========================================="
echo "Qualys Container Scanner Deployment"
echo "========================================="
echo "Subscription: $(az account show --query name -o tsv)"
echo "Resource Group: $RG"
echo "Location: $LOCATION"
echo "Qualys POD: $QUALYS_POD"
echo ""

# Step 1: Deploy Infrastructure
echo "[1/3] Deploying infrastructure..."
az deployment sub create \
  --location "$LOCATION" \
  --template-file infrastructure/main.bicep \
  --parameters location="$LOCATION" \
  --parameters resourceGroupName="$RG" \
  --parameters qualysPod="$QUALYS_POD" \
  --parameters qualysAccessToken="$QUALYS_ACCESS_TOKEN" \
  --output none

if [ $? -ne 0 ]; then
  echo "ERROR: Infrastructure deployment failed"
  exit 1
fi

FUNCTION_APP=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv)
echo "Function App created: $FUNCTION_APP"
echo ""

# Step 2: Deploy Function Code
echo "[2/3] Deploying function code..."
echo "This may take 5-10 minutes..."
cd function_app

if timeout 600 func azure functionapp publish "$FUNCTION_APP" --python --build remote 2>&1; then
  echo "Function code deployed successfully"
else
  EXIT_CODE=$?
  if [ $EXIT_CODE -eq 124 ]; then
    echo "WARNING: Deployment timed out, checking function app state..."
    sleep 30
    STATE=$(az functionapp show --resource-group "$RG" --name "$FUNCTION_APP" --query "state" -o tsv)
    if [ "$STATE" = "Running" ]; then
      echo "Function app is running - deployment succeeded"
    else
      echo "ERROR: Function app state: $STATE"
      cd ..
      exit 1
    fi
  else
    echo "ERROR: Function deployment failed with exit code $EXIT_CODE"
    cd ..
    exit 1
  fi
fi

cd ..
echo ""

# Step 3: Enable Event Grid Subscriptions
echo "[3/3] Enabling Event Grid subscriptions..."
az deployment sub create \
  --location "$LOCATION" \
  --template-file infrastructure/main.bicep \
  --parameters location="$LOCATION" \
  --parameters resourceGroupName="$RG" \
  --parameters qualysPod="$QUALYS_POD" \
  --parameters qualysAccessToken="$QUALYS_ACCESS_TOKEN" \
  --parameters enableEventGrid=true \
  --output none

if [ $? -ne 0 ]; then
  echo "ERROR: Event Grid deployment failed"
  exit 1
fi

echo ""
echo "========================================="
echo "Deployment Complete!"
echo "========================================="
echo ""
echo "Function App: $FUNCTION_APP"
echo "Key Vault: $(az keyvault list --resource-group $RG --query "[0].name" -o tsv)"
echo "Storage: $(az storage account list --resource-group $RG --query "[0].name" -o tsv)"
echo "ACR: $(az acr list --resource-group $RG --query "[0].name" -o tsv)"
echo ""
echo "Subscription-wide container scanning is now active!"
echo ""
echo "Test by deploying a container:"
echo "  az container create --resource-group $RG --name test-scan \\"
echo "    --image mcr.microsoft.com/dotnet/runtime:8.0 --os-type Linux --restart-policy Never"
echo ""
