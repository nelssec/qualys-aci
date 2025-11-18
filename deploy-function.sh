#!/bin/bash
# Deploy updated function code to Azure

set -e

RG="qualys-scanner-rg"
FUNCTION_APP=$(az functionapp list --resource-group $RG --query "[0].name" -o tsv)

echo "==========================================="
echo "  Deploying Function App Code"
echo "==========================================="
echo ""
echo "Function App: $FUNCTION_APP"
echo "Resource Group: $RG"
echo ""

cd function_app

echo "Deploying function code..."
func azure functionapp publish "$FUNCTION_APP" --python --build remote

echo ""
echo "✓ Function code deployed successfully"
echo ""
echo "Next steps:"
echo "1. Wait 2-3 minutes for deployment to complete"
echo "2. Run ./test-and-debug.sh to verify the fix"
echo "3. Deploy a test container to trigger scanning"
