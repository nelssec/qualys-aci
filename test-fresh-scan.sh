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
