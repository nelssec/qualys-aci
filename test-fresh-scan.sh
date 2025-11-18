#!/bin/bash
# Test automated scanning with a fresh image that hasn't been scanned
# Uses dotnet sample image which likely hasn't been scanned yet

set -e

RG="qualys-scanner-rg"
TEST_CONTAINER_NAME="test-dotnet-$(date +%s)"
TEST_IMAGE="mcr.microsoft.com/dotnet/samples:aspnetapp"

echo "Testing Automated Container Scanning with Fresh Image"
echo "Container: $TEST_CONTAINER_NAME"
echo "Image: $TEST_IMAGE"
echo ""

# Clear cache for test image to force scan
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
  --restart-policy Never \
  --output none

echo "Container deployed"
echo ""
echo "Waiting 10 seconds for Event Grid to trigger..."
sleep 10

echo ""
echo "Check for qscanner containers (should appear soon):"
echo "  watch -n 5 'az container list --resource-group $RG --query \"[?contains(name, \\\"qscanner\\\")].{Name:name, State:instanceView.state}\" -o table'"
echo ""
echo "View logs:"
echo "  ./view-logs.sh"
echo ""
echo "View scan results:"
echo "  ./view-scan-results.sh"
echo ""
echo "Clean up when done:"
echo "  az container delete --resource-group $RG --name $TEST_CONTAINER_NAME --yes"
