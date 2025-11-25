#!/bin/bash
# Automated 3-step deployment for Qualys Container Scanner
# Handles cleanup, waits for completion, and deploys fresh

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

echo "Qualys Container Scanner Deployment"
echo "Subscription: $(az account show --query name -o tsv)"
echo "Resource Group: $RG"
echo "Location: $LOCATION"
echo "Qualys POD: $QUALYS_POD"
echo ""

# Step 0: Check for resource group and wait if deleting
echo "[0/2] Checking for existing resources..."
RG_STATE=$(az group show --name "$RG" --query 'properties.provisioningState' -o tsv 2>/dev/null || echo "NotFound")

if [ "$RG_STATE" == "Deleting" ]; then
  echo "Resource group is currently being deleted. Waiting for completion..."
  while [ "$(az group show --name $RG --query 'properties.provisioningState' -o tsv 2>/dev/null || echo 'NotFound')" == "Deleting" ]; do
    echo "  Still deleting... (checking again in 10s)"
    sleep 10
  done
  echo "Resource group deletion complete!"
elif [ "$RG_STATE" != "NotFound" ]; then
  echo "WARNING: Resource group exists in state: $RG_STATE"
  echo "This may cause deployment conflicts. Run ./cleanup.sh first for a clean deployment."
  read -p "Continue anyway? (yes/no): " -r
  if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Deployment cancelled. Run ./cleanup.sh to remove old resources."
    exit 0
  fi
fi

# Check for orphaned role assignments (Reader and AcrPull - the roles we actually use)
echo "Checking for orphaned subscription-level role assignments..."
SUB_ID=$(az account show --query id -o tsv)

# Check for orphaned Reader role assignments (subscription-level)
ORPHANED_READER=$(az role assignment list \
  --role "Reader" \
  --scope "/subscriptions/$SUB_ID" \
  --query "[?principalType=='ServicePrincipal' && principalName==null].id" -o tsv 2>/dev/null || echo "")

# Check for orphaned AcrPull role assignments (subscription-level)
ORPHANED_ACRPULL=$(az role assignment list \
  --role "AcrPull" \
  --scope "/subscriptions/$SUB_ID" \
  --query "[?principalType=='ServicePrincipal' && principalName==null].id" -o tsv 2>/dev/null || echo "")

ORPHANED="$ORPHANED_READER $ORPHANED_ACRPULL"
ORPHANED=$(echo "$ORPHANED" | xargs)  # Trim whitespace

if [ ! -z "$ORPHANED" ]; then
  echo "Found orphaned role assignments, cleaning up..."
  for assignment in $ORPHANED; do
    if [ ! -z "$assignment" ]; then
      echo "  Deleting: $assignment"
      az role assignment delete --ids "$assignment" 2>/dev/null || true
    fi
  done
  echo "Cleanup complete!"
else
  echo "No orphaned role assignments found"
fi

echo ""

# Step 1: Deploy Infrastructure
echo "[1/2] Deploying infrastructure..."
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
echo "[2/2] Deploying function code..."
echo "This may take 3-5 minutes for remote build..."
cd function_app

if func azure functionapp publish "$FUNCTION_APP" --python --build remote 2>&1; then
  echo "Function code deployed successfully"
else
  EXIT_CODE=$?
  echo "WARNING: Function deployment returned exit code $EXIT_CODE"
  echo "Checking function app state..."
  sleep 10
  STATE=$(az functionapp show --resource-group "$RG" --name "$FUNCTION_APP" --query "state" -o tsv)
  if [ "$STATE" = "Running" ]; then
    echo "Function app is running - continuing deployment"
  else
    echo "ERROR: Function app state: $STATE"
    cd ..
    exit 1
  fi
fi

cd ..
echo ""
echo "Deployment Complete"
echo ""
echo "Function App: $FUNCTION_APP"
echo "Key Vault: $(az keyvault list --resource-group $RG --query "[0].name" -o tsv)"
echo "Storage: $(az storage account list --resource-group $RG --query "[0].name" -o tsv)"
echo ""
echo "Subscription-wide container scanning is now active"
echo ""
echo "Test by deploying a container:"
echo "  az container create --resource-group $RG --name test-scan --image mcr.microsoft.com/dotnet/runtime:8.0 --os-type Linux --cpu 1 --memory 1 --restart-policy Never"
echo ""
echo "Monitor logs:"
echo "  func azure functionapp logstream $FUNCTION_APP"
echo ""
