#!/bin/bash
# Test script to deploy multiple containers and verify scanning
# Uses MCR images to avoid Docker Hub rate limits

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"
FUNCTION_APP=""

echo "Qualys Scanner Test Deployment"
echo ""

# Get function app name
FUNCTION_APP=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv 2>/dev/null)

if [ -z "$FUNCTION_APP" ]; then
  echo "ERROR: No function app found in resource group $RG"
  echo "Please deploy the scanner first: ./deploy.sh"
  exit 1
fi

echo "Function App: $FUNCTION_APP"
echo "Resource Group: $RG"
echo ""

# Test container images from MCR (no rate limiting)
IMAGES=(
  "mcr.microsoft.com/dotnet/runtime:8.0"
  "mcr.microsoft.com/dotnet/aspnet:8.0"
  "mcr.microsoft.com/azure-functions/python:4-python3.11"
)

echo "Deploying ${#IMAGES[@]} test containers..."
echo ""

TIMESTAMP=$(date +%s)
CONTAINER_NAMES=()

for i in "${!IMAGES[@]}"; do
  IMAGE="${IMAGES[$i]}"
  CONTAINER_NAME="test-scan-$TIMESTAMP-$i"
  CONTAINER_NAMES+=("$CONTAINER_NAME")

  echo "[$((i+1))/${#IMAGES[@]}] Deploying: $IMAGE"
  echo "  Container name: $CONTAINER_NAME"

  az container create \
    --resource-group "$RG" \
    --name "$CONTAINER_NAME" \
    --image "$IMAGE" \
    --os-type Linux \
    --cpu 1 \
    --memory 1.5 \
    --restart-policy Never \
    --location eastus \
    --output none 2>&1 | grep -v "Running\.\.\." || true

  echo "  [OK] Deployed"
  echo ""
done

echo ""
echo "Deployment Complete"
echo ""
echo "Test containers deployed:"
for name in "${CONTAINER_NAMES[@]}"; do
  echo "  - $name"
done
echo ""

echo "Monitoring function logs for scan activity..."
echo "This will show real-time logs from the EventProcessor function."
echo "Press Ctrl+C to stop monitoring."
echo ""
echo "Expected behavior:"
echo "  - You should see ${#IMAGES[@]} Event Grid events (one per container)"
echo "  - Each event should trigger a container image scan"
echo "  - Scans will show 'EVENT GRID EVENT RECEIVED' messages"
echo "  - qscanner binary will auto-download on first scan (if not cached)"
echo ""

# Wait a moment for containers to be fully created
sleep 5

# Stream function logs
echo "Starting log stream (Ctrl+C to exit)..."
func azure functionapp logstream "$FUNCTION_APP" 2>&1 | grep -E "(EVENT GRID|EventProcessor|qscanner|Scanning|vulnerabilities)" --line-buffered || true

echo ""
echo "Test Complete"
echo ""
echo "View scan results:"
echo "  1. Qualys Dashboard: https://qualysguard.qg2.apps.qualys.com/"
echo "  2. Azure Storage:"
echo "     STORAGE=\$(az storage account list --resource-group $RG --query '[0].name' -o tsv)"
echo "     az storage blob list --account-name \$STORAGE --auth-mode login --container-name scan-results"
echo ""
echo "Clean up test containers:"
echo "  for name in ${CONTAINER_NAMES[@]}; do az container delete --resource-group $RG --name \$name --yes; done"
echo ""
