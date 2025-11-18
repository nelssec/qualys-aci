#!/bin/bash
# Check what resources exist in the resource group

set -e

RG="qualys-scanner-rg"

echo "=== Checking deployments ==="
az deployment group list \
  --resource-group $RG \
  --query "[].{Name:name, State:properties.provisioningState, Timestamp:properties.timestamp}" \
  --output table

echo ""
echo "=== Checking Event Grid system topics ==="
az eventgrid system-topic list \
  --resource-group $RG \
  --query "[].{Name:name, TopicType:topicType, Source:source, ProvisioningState:provisioningState}" \
  --output table

echo ""
echo "=== Checking function apps ==="
az functionapp list \
  --resource-group $RG \
  --query "[].{Name:name, State:state, RuntimeVersion:siteConfig.linuxFxVersion}" \
  --output table

echo ""
echo "=== Checking latest deployment outputs ==="
LATEST_DEPLOYMENT=$(az deployment group list \
  --resource-group $RG \
  --query "sort_by([?properties.provisioningState=='Succeeded'], &properties.timestamp) | [-1].name" -o tsv)

echo "Latest deployment: $LATEST_DEPLOYMENT"
echo ""

if [ -n "$LATEST_DEPLOYMENT" ]; then
  az deployment group show \
    --resource-group $RG \
    --name "$LATEST_DEPLOYMENT" \
    --query "properties.outputs" \
    --output json
fi
