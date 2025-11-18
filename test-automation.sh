#!/bin/bash
# Debug script: Test automated container scanning
# Deploys test container and monitors scan execution

set -e

RG="qualys-scanner-rg"
TEST_CONTAINER_NAME="test-automation-$(date +%s)"
TEST_IMAGE="mcr.microsoft.com/azuredocs/aci-helloworld:latest"

echo "Testing Automated Container Scanning"
echo "Container: $TEST_CONTAINER_NAME"
echo "Image: $TEST_IMAGE"
echo ""

# Clear cache for test image
echo "Clearing cache for test image..."
STORAGE=$(az storage account list --resource-group $RG --query "[0].name" -o tsv)
STORAGE_KEY=$(az storage account keys list --resource-group $RG --account-name $STORAGE --query "[0].value" -o tsv)

# Delete all cached entries for this image
ENTRIES=$(az storage entity query \
  --account-name $STORAGE \
  --account-key "$STORAGE_KEY" \
  --table-name "ScanMetadata" \
  --filter "image eq '$TEST_IMAGE'" \
  --query "items[].{pk:PartitionKey,rk:RowKey}" \
  --output tsv 2>/dev/null || echo "")

if [ -n "$ENTRIES" ]; then
  echo "$ENTRIES" | while IFS=$'\t' read -r pk rk; do
    if [ -n "$pk" ] && [ -n "$rk" ]; then
      echo "  Deleting cache entry: $pk / $rk"
      az storage entity delete \
        --account-name $STORAGE \
        --account-key "$STORAGE_KEY" \
        --table-name "ScanMetadata" \
        --partition-key "$pk" \
        --row-key "$rk" \
        --if-match "*" \
        --output none 2>/dev/null || true
    fi
  done
  echo "Cache cleared"
else
  echo "No cache entries found for this image"
fi
echo ""

az container create \
  --resource-group $RG \
  --name $TEST_CONTAINER_NAME \
  --image $TEST_IMAGE \
  --cpu 1 \
  --memory 1 \
  --os-type Linux \
  --restart-policy Always \
  --ports 80 \
  --output none

echo "Container deployed"
echo "Waiting for Event Grid to trigger scanner (30 seconds)"
sleep 30
echo ""

FUNCTION_APP=$(az functionapp list --resource-group $RG --query "[0].name" -o tsv)
APP_INSIGHTS_ID=$(az monitor app-insights component list --resource-group $RG --query "[0].appId" -o tsv)

echo "Recent EventProcessor logs:"
az monitor app-insights query \
  --app "$APP_INSIGHTS_ID" \
  --analytics-query "traces
    | where timestamp > ago(5m)
    | where operation_Name == 'EventProcessor'
    | project timestamp, message
    | order by timestamp desc
    | take 20" \
  --output table

echo ""
echo "QScanner containers:"
az container list \
  --resource-group $RG \
  --query "[?contains(name, 'qscanner')].{Name:name, State:instanceView.state, Started:containers[0].instanceView.currentState.startTime}" \
  --output table

echo ""
echo "Test container:"
az container show \
  --resource-group $RG \
  --name $TEST_CONTAINER_NAME \
  --query "{Name:name, State:instanceView.state, Image:containers[0].image}" \
  --output table

echo ""
echo "Clean up: az container delete --resource-group $RG --name $TEST_CONTAINER_NAME --yes"
