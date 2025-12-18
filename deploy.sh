#!/bin/bash
set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"
LOCATION="${LOCATION:-eastus}"
QUALYS_API_TOKEN="${QUALYS_API_TOKEN:-}"
QUALYS_GATEWAY_URL="${QUALYS_GATEWAY_URL:-https://gateway.qg2.apps.qualys.com}"
ACR_CONNECTOR_NAME="${ACR_CONNECTOR_NAME:-qualys-aci-connector}"
ACR_APPLICATION_ID="${ACR_APPLICATION_ID:-}"
ACR_CLIENT_SECRET="${ACR_CLIENT_SECRET:-}"

if [ -z "$QUALYS_API_TOKEN" ]; then
  echo "ERROR: QUALYS_API_TOKEN environment variable not set"
  echo ""
  echo "Usage:"
  echo "  export QUALYS_API_TOKEN='your-qualys-token'"
  echo "  export ACR_APPLICATION_ID='your-service-principal-app-id'"
  echo "  export ACR_CLIENT_SECRET='your-service-principal-secret'"
  echo "  ./deploy.sh"
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

echo "Qualys Container Scanner for ACI/ACA"
echo "====================================="
echo "Subscription: $(az account show --query name -o tsv)"
echo "Resource Group: $RG"
echo "Location: $LOCATION"
echo "Qualys Gateway: $QUALYS_GATEWAY_URL"
echo ""

echo "[0/2] Checking for existing resources..."
RG_STATE=$(az group show --name "$RG" --query 'properties.provisioningState' -o tsv 2>/dev/null || echo "NotFound")

if [ "$RG_STATE" == "Deleting" ]; then
  echo "Resource group is being deleted. Waiting..."
  while [ "$(az group show --name $RG --query 'properties.provisioningState' -o tsv 2>/dev/null || echo 'NotFound')" == "Deleting" ]; do
    sleep 10
  done
elif [ "$RG_STATE" != "NotFound" ]; then
  echo "WARNING: Resource group exists in state: $RG_STATE"
  read -p "Continue with update deployment? (yes/no): " -r
  if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Deployment cancelled"
    exit 0
  fi
fi

echo ""
echo "[1/2] Deploying infrastructure..."
az deployment sub create \
  --location "$LOCATION" \
  --template-file infrastructure/main.bicep \
  --parameters location="$LOCATION" \
  --parameters resourceGroupName="$RG" \
  --parameters qualysGatewayUrl="$QUALYS_GATEWAY_URL" \
  --parameters qualysApiToken="$QUALYS_API_TOKEN" \
  --parameters acrConnectorName="$ACR_CONNECTOR_NAME" \
  --parameters acrApplicationId="$ACR_APPLICATION_ID" \
  --parameters acrClientSecret="$ACR_CLIENT_SECRET" \
  --output none

if [ $? -ne 0 ]; then
  echo "ERROR: Infrastructure deployment failed"
  exit 1
fi

FUNCTION_APP=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv)
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
echo "Deployment Complete"
echo "==================="
echo "Function App: $FUNCTION_APP"
echo ""
echo "Test by deploying an ACR container:"
echo "  az container create \\"
echo "    --resource-group $RG \\"
echo "    --name test-scan \\"
echo "    --image <your-acr>.azurecr.io/<image>:<tag> \\"
echo "    --os-type Linux --cpu 1 --memory 1"
echo ""
