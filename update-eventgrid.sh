#!/bin/bash
# Quick script to update Event Grid subscriptions with proper filters
# Run this after initial deployment to enable/update Event Grid

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"
LOCATION="${LOCATION:-eastus}"
QUALYS_ACCESS_TOKEN="${QUALYS_ACCESS_TOKEN:-}"
QUALYS_POD="${QUALYS_POD:-US2}"

if [ -z "$QUALYS_ACCESS_TOKEN" ]; then
  echo "ERROR: QUALYS_ACCESS_TOKEN environment variable not set"
  echo "Usage: export QUALYS_ACCESS_TOKEN='...' && ./update-eventgrid.sh"
  exit 1
fi

echo "========================================="
echo "Updating Event Grid Subscriptions"
echo "========================================="
echo "Resource Group: $RG"
echo "Location: $LOCATION"
echo ""

echo "Deploying Event Grid configuration..."
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
echo "Event Grid Update Complete!"
echo "========================================="
echo ""
echo "The Event Grid subscriptions have been updated with subject filters:"
echo "  - ACI: Filters for /Microsoft.ContainerInstance/containerGroups/"
echo "  - ACA: Filters for /Microsoft.App/containerApps/"
echo ""
echo "Container deployments will now trigger the scanner function."
echo ""
echo "Test by deploying a container:"
echo "  ./test-scanner.sh"
echo ""
