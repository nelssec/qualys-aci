#!/bin/bash
set -e

HUB_SUB="${HUB_SUBSCRIPTION_ID:-}"
RG="${RESOURCE_GROUP:-qualys-scanner-rg}"
LOCATION="${LOCATION:-eastus}"
QUALYS_API_TOKEN="${QUALYS_API_TOKEN:-}"
QUALYS_GATEWAY_URL="${QUALYS_GATEWAY_URL:-https://gateway.qg2.apps.qualys.com}"
ACR_APPLICATION_ID="${ACR_APPLICATION_ID:-}"
ACR_CLIENT_SECRET="${ACR_CLIENT_SECRET:-}"
OUTPUTS_FILE=".deployment-outputs.json"

if [ -z "$QUALYS_API_TOKEN" ]; then
  echo "ERROR: QUALYS_API_TOKEN environment variable not set"
  echo ""
  echo "Usage:"
  echo "  export QUALYS_API_TOKEN='your-qualys-token'"
  echo "  export ACR_APPLICATION_ID='your-service-principal-app-id'"
  echo "  export ACR_CLIENT_SECRET='your-service-principal-secret'"
  echo "  export HUB_SUBSCRIPTION_ID='your-hub-subscription-id'"
  echo "  ./deploy-hub.sh"
  exit 1
fi

if [ -z "$ACR_APPLICATION_ID" ] || [ -z "$ACR_CLIENT_SECRET" ]; then
  echo "ERROR: Service Principal credentials not set"
  echo ""
  echo "Create a Service Principal with AcrPull role:"
  echo "  az ad sp create-for-rbac --name qualys-acr-scanner --role AcrPull --scopes /subscriptions/\$(az account show --query id -o tsv)"
  echo ""
  echo "Then set:"
  echo "  export ACR_APPLICATION_ID='<appId from output>'"
  echo "  export ACR_CLIENT_SECRET='<password from output>'"
  exit 1
fi

if [ -z "$HUB_SUB" ]; then
  echo "ERROR: HUB_SUBSCRIPTION_ID environment variable not set"
  exit 1
fi

echo "Qualys Hub Deployment"
echo "====================="
echo "Hub Subscription: $HUB_SUB"
echo "Resource Group: $RG"
echo "Location: $LOCATION"
echo "Qualys Gateway: $QUALYS_GATEWAY_URL"
echo ""

echo "[1/2] Deploying hub resources..."
az account set --subscription "$HUB_SUB"

DEPLOYMENT_OUTPUT=$(az deployment sub create \
  --location "$LOCATION" \
  --template-file infrastructure/main.bicep \
  --parameters location="$LOCATION" \
  --parameters resourceGroupName="$RG" \
  --parameters qualysGatewayUrl="$QUALYS_GATEWAY_URL" \
  --parameters qualysApiToken="$QUALYS_API_TOKEN" \
  --parameters acrApplicationId="$ACR_APPLICATION_ID" \
  --parameters acrClientSecret="$ACR_CLIENT_SECRET" \
  --query 'properties.outputs' \
  --output json)

if [ $? -ne 0 ]; then
  echo "ERROR: Hub deployment failed"
  exit 1
fi

echo "$DEPLOYMENT_OUTPUT" > "$OUTPUTS_FILE"

FUNCTION_APP=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.functionAppName.value')
FUNCTION_PRINCIPAL_ID=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.functionAppPrincipalId.value')
EVENT_HUB_NAMESPACE=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.eventHubNamespace.value')

echo "Function App: $FUNCTION_APP"
echo ""

echo "[2/2] Deploying function code..."
cd function_app

if func azure functionapp publish "$FUNCTION_APP" --python --build remote 2>&1; then
  echo "Function code deployed successfully"
else
  EXIT_CODE=$?
  echo "WARNING: Function deployment returned exit code $EXIT_CODE"
  sleep 10
  STATE=$(az functionapp show --resource-group "$RG" --name "$FUNCTION_APP" --query "state" -o tsv)
  if [ "$STATE" != "Running" ]; then
    echo "ERROR: Function app state: $STATE"
    cd ..
    exit 1
  fi
fi

cd ..

echo ""
echo "Hub Deployment Complete"
echo "======================="
echo "Function App: $FUNCTION_APP"
echo "Outputs saved to: $OUTPUTS_FILE"
echo ""
echo "Add spoke subscriptions:"
echo "  export SPOKE_SUBSCRIPTION_ID='<subscription-id>'"
echo "  ./deploy-spoke.sh"
echo ""
