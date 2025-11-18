#!/bin/bash
# Deploy Event Grid subscriptions after function code is deployed

set -e

RG="qualys-scanner-rg"

echo "=== Getting resource names ==="
# Try to get from deployment outputs first
LATEST_DEPLOYMENT=$(az deployment group list \
  --resource-group $RG \
  --query "sort_by([?properties.provisioningState=='Succeeded'], &properties.timestamp) | [-1].name" -o tsv)

if [ -n "$LATEST_DEPLOYMENT" ]; then
  FUNCTION_APP=$(az deployment group show \
    --resource-group $RG \
    --name "$LATEST_DEPLOYMENT" \
    --query "properties.outputs.functionAppName.value" -o tsv 2>/dev/null || echo "")

  EVENT_GRID_TOPIC=$(az deployment group show \
    --resource-group $RG \
    --name "$LATEST_DEPLOYMENT" \
    --query "properties.outputs.eventGridTopicName.value" -o tsv 2>/dev/null || echo "")
fi

# If deployment outputs are empty, query resources directly
if [ -z "$FUNCTION_APP" ]; then
  FUNCTION_APP=$(az functionapp list --resource-group $RG --query "[0].name" -o tsv)
fi

if [ -z "$EVENT_GRID_TOPIC" ]; then
  EVENT_GRID_TOPIC=$(az eventgrid system-topic list --resource-group $RG --query "[0].name" -o tsv)
fi

echo "Function App: $FUNCTION_APP"
echo "Event Grid Topic: $EVENT_GRID_TOPIC"

if [ -z "$FUNCTION_APP" ] || [ -z "$EVENT_GRID_TOPIC" ]; then
  echo "ERROR: Could not find function app or Event Grid topic"
  echo "Run ./check-resources.sh to see what resources exist"
  exit 1
fi

echo ""
echo "=== Verifying Event Grid system topic exists ==="
az eventgrid system-topic show \
  --resource-group $RG \
  --name "$EVENT_GRID_TOPIC" \
  --query "{Name:name, Source:source, TopicType:topicType, ProvisioningState:provisioningState}" \
  --output table

echo ""
echo "=== Deploying Event Grid subscriptions ==="
az deployment group create \
  --resource-group $RG \
  --name eventgrid-subscriptions \
  --template-file infrastructure/eventgrid.bicep \
  --parameters functionAppName="$FUNCTION_APP" \
  --parameters eventGridTopicName="$EVENT_GRID_TOPIC"

echo ""
echo "=== Verifying Event Grid subscriptions ==="
az eventgrid system-topic event-subscription list \
  --resource-group $RG \
  --system-topic-name "$EVENT_GRID_TOPIC" \
  --query "[].{Name:name, ProvisioningState:provisioningState, Endpoint:destination.endpointType}" \
  --output table

echo ""
echo "Event Grid subscriptions deployed successfully!"
echo "The EventProcessor function will now be triggered when containers are deployed."
