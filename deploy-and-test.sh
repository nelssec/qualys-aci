#!/bin/bash
# Deploy and test the updated qscanner functionality

set -e

echo "=== Deploying updated function code ==="
cd function_app
func azure functionapp publish qscan-func-alol3ziwapdfm --python

echo ""
echo "=== Waiting for deployment to complete ==="
sleep 10

echo ""
echo "=== Testing HTTP endpoint to verify function is running ==="
FUNCTION_URL=$(az functionapp function show \
  --resource-group qualys-scanner-rg \
  --name qscan-func-alol3ziwapdfm \
  --function-name HttpTest \
  --query "invokeUrlTemplate" -o tsv)
curl "$FUNCTION_URL"

echo ""
echo ""
echo "=== Deploying test container to trigger Event Grid ==="
az container create \
  --resource-group qualys-scanner-rg \
  --name test-nginx-$(date +%s) \
  --image mcr.microsoft.com/azuredocs/aci-helloworld:latest \
  --os-type Linux \
  --cpu 1 \
  --memory 1 \
  --restart-policy Never

echo ""
echo "=== Waiting 30 seconds for Event Grid to trigger function ==="
sleep 30

echo ""
echo "=== Checking for qscanner ACI containers ==="
az container list \
  --resource-group qualys-scanner-rg \
  --query "[?starts_with(name, 'qscanner-')].{Name:name, Status:instanceView.state, Image:containers[0].image}" \
  --output table

echo ""
echo "=== If qscanner container exists, check its logs ==="
QSCANNER_CONTAINER=$(az container list \
  --resource-group qualys-scanner-rg \
  --query "[?starts_with(name, 'qscanner-')].name | [0]" -o tsv)

if [ -n "$QSCANNER_CONTAINER" ]; then
  echo "Found qscanner container: $QSCANNER_CONTAINER"
  echo "Fetching logs..."
  az container logs \
    --resource-group qualys-scanner-rg \
    --name "$QSCANNER_CONTAINER"
else
  echo "No qscanner container found. Check function logs:"
  az functionapp logs tail \
    --resource-group qualys-scanner-rg \
    --name qscan-func-alol3ziwapdfm \
    --max-events 50
fi
