#!/bin/bash
# Check Event Grid delivery status and failures
set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"

echo "========================================="
echo "Event Grid Delivery Diagnostics"
echo "========================================="
echo ""

TOPIC_NAME=$(az eventgrid system-topic list --resource-group "$RG" --query "[?topicType=='Microsoft.Resources.Subscriptions'].name | [0]" -o tsv)

if [ -z "$TOPIC_NAME" ]; then
  echo "[ERROR] No Event Grid topic found"
  exit 1
fi

echo "Topic: $TOPIC_NAME"
echo ""

echo "[1/3] Checking ACI Event Grid subscription details..."
az eventgrid system-topic event-subscription show \
  --resource-group "$RG" \
  --system-topic-name "$TOPIC_NAME" \
  --name qualys-aci-container-deployments \
  --query "{Name:name, State:provisioningState, Endpoint:destination.resourceId, EventTypes:filter.includedEventTypes, Filters:filter.advancedFilters}" \
  -o json

echo ""
echo "[2/3] Checking for delivery failures..."
az eventgrid system-topic event-subscription show \
  --resource-group "$RG" \
  --system-topic-name "$TOPIC_NAME" \
  --name qualys-aci-container-deployments \
  --include-full-endpoint-url \
  --query "{EndpointUrl:destination.endpointUrl, ProvisioningState:provisioningState}"

echo ""
echo "[3/3] Testing Event Grid webhook validation..."
FUNCTION_APP=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv)
FUNCTION_KEY=$(az functionapp function keys list \
  --resource-group "$RG" \
  --name "$FUNCTION_APP" \
  --function-name EventProcessor \
  --query "default" -o tsv 2>/dev/null || echo "")

if [ -n "$FUNCTION_KEY" ]; then
  WEBHOOK_URL="https://${FUNCTION_APP}.azurewebsites.net/runtime/webhooks/eventgrid?functionName=EventProcessor&code=${FUNCTION_KEY}"
  echo "Function webhook URL: $WEBHOOK_URL"
  echo ""
  echo "Testing endpoint accessibility..."
  curl -I -s "$WEBHOOK_URL" | head -5 || echo "Endpoint not reachable"
else
  echo "[WARN] Could not retrieve function key"
  echo "Function app might not have Event Grid trigger properly configured"
fi

echo ""
echo "========================================="
echo "Manual Validation Steps"
echo "========================================="
echo ""
echo "1. Check Event Grid metrics in Azure Portal:"
echo "   Resource Groups > $RG > $TOPIC_NAME > Metrics"
echo "   Look for: Publish Success Count, Delivery Failed Count"
echo ""
echo "2. Check function configuration:"
echo "   az functionapp function show --resource-group $RG --name $FUNCTION_APP --function-name EventProcessor"
echo ""
echo "3. Manually trigger a test event:"
echo "   Deploy a new container and watch Event Grid metrics"
echo ""
